import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../transport/native_local.dart';
import 'archive_io.dart';
import 'backup_models.dart';
import 'backup_transport.dart';

class VaultContext {
  VaultContext(this.family,this.backup,this.entry){
    for(final value in [family,backup,entry]){if(value.isEmpty||utf8.encode(value).length>4096||value.contains('\u0000'))throw const BackupException('invalid_vault_context');}
  }
  final String family,backup,entry;
}
class VaultSummary {
  VaultSummary(this.bytes,this.chunks,List<int> digest):digest=Uint8List.fromList(digest);
  final int bytes,chunks;final Uint8List digest;
  bool same(VaultSummary other)=>bytes==other.bytes&&chunks==other.chunks&&backupConstantTimeEquals(digest,other.digest);
}
class VaultPlaintextStage {
  VaultPlaintextStage._(this.directory,this.file,this.summary);
  final Directory directory;final File file;final VaultSummary summary;
  Future<void> dispose()async{await directory.delete(recursive:true);}
}

/// 与 Go internal/vault v1 契约相同。未执行 Dart，Go fixture 不是实际 Dart 互通证明。
class VaultCodec {
  VaultCodec(this.crypto);
  final LocalCrypto crypto;
  static const chunkBytes=65536,headerBytes=52,maxChunks=1048576,maxPlaintext=64*1024*1024*1024;
  static final _magic=ascii.encode('WOVLT1\r\n');
  Future<Uint8List> _context(VaultContext context)async{
    final bytes=BytesBuilder()..add(utf8.encode('WoVault/context/v1\u0000'));
    for(final s in [context.family,context.backup,context.entry]){final v=utf8.encode(s);bytes.add(_u32(v.length));bytes.add(v);}
    return _hash(bytes.takeBytes());
  }
  Future<Uint8List> _hash(Uint8List bytes)async{final h=await crypto.hash(bytes);if(h.length!=32)throw const BackupException('invalid_hash');return h;}
  Future<Uint8List> _derive(Uint8List key,Uint8List header,Uint8List context)async{
    if(key.length!=32)throw const BackupException('invalid_recovery_key');
    final extracted=await crypto.hmac(key:Uint8List.sublistView(header,8,40),data:key);
    try{
      final derived=await crypto.hmac(key:extracted,data:archiveJoin([utf8.encode('WoVault/AES256GCM/v1\u0000'),context,[1]]));
      if(extracted.length!=32||derived.length!=32)throw const BackupException('invalid_hmac');return derived;
    }finally{extracted.fillRange(0,extracted.length,0);}
  }
  Uint8List _nonce(Uint8List header,int sequence)=>archiveJoin([Uint8List.sublistView(header,40,48),_u32(sequence)]);
  Uint8List _aad(Uint8List header,Uint8List context,Uint8List descriptor)=>archiveJoin([utf8.encode('WoVault/frame/v1\u0000'),header,context,descriptor]);
  Uint8List _frame(int kind,int sequence,int length)=>archiveJoin([[kind],_u32(sequence),_u32(length)]);
  Stream<List<int>> encrypt(Stream<List<int>> source,{required Uint8List key,required VaultContext context})async*{
    if(key.length!=32)throw const BackupException('invalid_recovery_key');
    final random=await crypto.random(40);if(random.length!=40)throw const BackupException('invalid_random');
    final header=archiveJoin([_magic,random,_u32(chunkBytes)]);final ctx=await _context(context),derived=await _derive(key,header,ctx);
    final reader=ArchiveReader(source),hash=ArchiveSha256();var bytes=0,chunks=0;
    try{
      yield header;
      while(true){
        final plain=await reader.upTo(chunkBytes);if(plain.isEmpty)break;
        if(chunks>=maxChunks||bytes+plain.length>maxPlaintext)throw const BackupException('vault_limit');
        final descriptor=_frame(1,chunks,plain.length);hash.add(plain);bytes+=plain.length;
        try{
          final cipher=await crypto.seal(key:derived,nonce:_nonce(header,chunks),plaintext:plain,aad:_aad(header,ctx,descriptor));
          if(cipher.length!=plain.length+16)throw const BackupException('invalid_gcm_result');
          yield descriptor;yield cipher;
        }finally{plain.fillRange(0,plain.length,0);}
        chunks++;
      }
      final footer=archiveJoin([_u64(bytes),_u32(chunks),hash.finish()]);final descriptor=_frame(2,chunks,44);
      try{
        final cipher=await crypto.seal(key:derived,nonce:_nonce(header,chunks),plaintext:footer,aad:_aad(header,ctx,descriptor));
        if(cipher.length!=60)throw const BackupException('invalid_gcm_result');yield descriptor;yield cipher;
      }finally{footer.fillRange(0,footer.length,0);}
    }finally{derived.fillRange(0,derived.length,0);await reader.close();}
  }
  Future<VaultSummary> verify(Stream<List<int>> source,{required Uint8List key,required VaultContext context})=>_decode(source,key,context,null);
  Future<VaultSummary> _decode(Stream<List<int>> source,Uint8List key,VaultContext context,Future<void> Function(Uint8List)? output)async{
    if(key.length!=32)throw const BackupException('invalid_recovery_key');
    final reader=ArchiveReader(source);Uint8List? derived;
    try{
      final header=await reader.exact(headerBytes);
      if(!backupConstantTimeEquals(Uint8List.sublistView(header,0,8),_magic)||_read32(header,48)!=chunkBytes)throw const BackupException('invalid_vault_header');
      final ctx=await _context(context);derived=await _derive(key,header,ctx);
      final hash=ArchiveSha256();var bytes=0,chunks=0;var partial=false;
      while(true){
        final descriptor=await reader.exact(9);final kind=descriptor[0],sequence=_read32(descriptor,1),length=_read32(descriptor,5);
        if(sequence!=chunks)throw const BackupException('vault_sequence');
        if(kind==1){if(partial||length<1||length>chunkBytes)throw const BackupException('vault_frame');if(chunks>=maxChunks||bytes+length>maxPlaintext)throw const BackupException('vault_limit');}
        else if(kind!=2||length!=44){throw const BackupException('vault_frame');}
        final cipher=await reader.exact(length+16);Uint8List plain;
        try{plain=await crypto.open(key:derived,nonce:_nonce(header,sequence),ciphertext:cipher,aad:_aad(header,ctx,descriptor));}
        catch(_){throw const BackupException('vault_authentication_failed');}
        try{
          if(plain.length!=length)throw const BackupException('invalid_gcm_result');
          if(kind==2){
            final digest=hash.finish();
            if(_read64(plain,0)!=bytes||_read32(plain,8)!=chunks||!backupConstantTimeEquals(Uint8List.sublistView(plain,12),digest))throw const BackupException('vault_footer');
            await reader.eof();return VaultSummary(bytes,chunks,digest);
          }
          hash.add(plain);if(output!=null)await output(plain);bytes+=length;chunks++;partial=length<chunkBytes;
        }finally{plain.fillRange(0,plain.length,0);}
      }
    }finally{if(derived!=null)derived.fillRange(0,derived.length,0);await reader.close();}
  }
  /// privateParent 必须由原生层确认在应用私有且排除系统备份的目录。
  /// 先只验证密文，第二遍明文仅进入新隔离目录；绝不接收已有目的文件路径。
  Future<VaultPlaintextStage> decryptToNewStaging(File ciphertext,Directory privateParent,
      {required Uint8List key,required VaultContext context})async{
    if(Platform.isWindows)throw const BackupException('private_acl_unavailable');
    if(await FileSystemEntity.type(ciphertext.path,followLinks:false)!=FileSystemEntityType.file||
       await FileSystemEntity.type(privateParent.path,followLinks:false)!=FileSystemEntityType.directory)throw const BackupException('untrusted_staging_path');
    final first=await verify(ciphertext.openRead(),key:key,context:context);
    final stage=await privateParent.createTemp('wo-vault-');final file=File('${stage.path}${Platform.pathSeparator}plaintext');
    try{
      final output=await file.open(mode:FileMode.write);VaultSummary second;
      try{second=await _decode(ciphertext.openRead(),key,context,(bytes)async{await output.writeFrom(bytes);});await output.flush();}
      finally{await output.close();}
      if(!first.same(second))throw const BackupException('vault_source_changed');
      return VaultPlaintextStage._(stage,file,second);
    }catch(_){await stage.delete(recursive:true);rethrow;}
  }
}
Uint8List _u32(int n){final b=Uint8List(4);ByteData.sublistView(b).setUint32(0,n,Endian.big);return b;}
Uint8List _u64(int n){final b=Uint8List(8);ByteData.sublistView(b).setUint64(0,n,Endian.big);return b;}
int _read32(Uint8List b,int n)=>ByteData.sublistView(b).getUint32(n,Endian.big);
int _read64(Uint8List b,int n)=>ByteData.sublistView(b).getUint64(n,Endian.big);
