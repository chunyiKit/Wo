import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../transport/native_local.dart';
import 'archive_io.dart';
import 'backup_models.dart';
import 'backup_transport.dart';
import 'vault_codec.dart';

const _portableKinds={'records','photo','video','thumbnail'};
const _portableMissing={'not_on_device','permission_denied','source_missing','source_unavailable','unsupported','not_authorized','source_not_exact'};
final _portableId=RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$');
class PortableEntry {
  PortableEntry({required this.id,required this.kind,required this.size,required this.sha256,
      required this.sourceExact,this.missingReason=''}) {
    if(!_portableId.hasMatch(id)||!_portableKinds.contains(kind))throw const BackupException('invalid_portable_entry');
    if(missingReason.isNotEmpty){
      if(!_portableMissing.contains(missingReason)||size!=0||sha256.isNotEmpty||sourceExact)throw const BackupException('invalid_portable_missing');
    }else if(size<1||size>20*1024*1024*1024||!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)||
      (sourceExact&&kind!='photo'&&kind!='video'))throw const BackupException('invalid_portable_entry');
  }
  final String id,kind,sha256,missingReason;final int size;final bool sourceExact;
  Map<String,dynamic> toJson()=>{'id':id,'kind':kind,'size':size,'sha256':sha256,'missing_reason':missingReason,'source_exact':sourceExact};
  factory PortableEntry.fromJson(Map<String,dynamic> j){
    if(j.length!=6||!j.keys.toSet().containsAll({'id','kind','size','sha256','missing_reason','source_exact'})||
      j['id'] is! String||j['kind'] is! String||j['size'] is! int||j['sha256'] is! String||j['missing_reason'] is! String||j['source_exact'] is! bool)throw const BackupException('invalid_portable_json');
    return PortableEntry(id:j['id'] as String,kind:j['kind'] as String,size:j['size'] as int,sha256:j['sha256'] as String,
      sourceExact:j['source_exact'] as bool,missingReason:j['missing_reason'] as String);
  }
}
class PortableManifest {
  PortableManifest({required this.familyId,required Iterable<PortableEntry> entries}):entries=List.unmodifiable(entries){
    if(!_portableId.hasMatch(familyId)||this.entries.length>20000)throw const BackupException('portable_limit');
    final seen=<String>{};var total=0;
    for(final e in this.entries){if(!seen.add(e.id))throw const BackupException('duplicate_portable_id');total+=e.size;}
    if(total>100*1024*1024*1024||utf8.encode(jsonEncode(toJson())).length>8*1024*1024)throw const BackupException('portable_limit');
  }
  final String familyId;final List<PortableEntry> entries;
  Map<String,dynamic> toJson()=>{'version':1,'family_id':familyId,'entries':entries.map((e)=>e.toJson()).toList()};
  factory PortableManifest.fromJson(Map<String,dynamic> j){
    if(j.length!=3||j['version']!=1||j['family_id'] is! String||j['entries'] is! List)throw const BackupException('invalid_portable_json');
    return PortableManifest(familyId:j['family_id'] as String,entries:(j['entries'] as List).map((e)=>PortableEntry.fromJson(backupObject(e))));
  }
}
class PortableRecoveredFile {
  PortableRecoveredFile(this.newId,this.file,this.entry);
  final String newId;final File file;final PortableEntry entry;
}
class PortableRestore {
  PortableRestore._(this.directory,this.newFamilyId,this.newDeviceId,this.files,this.missing,this.unverifiedOriginals);
  final Directory directory;final String newFamilyId,newDeviceId;
  final Map<String,PortableRecoveredFile> files;final Map<String,String> missing,unverifiedOriginals;
  bool get declaredBytesComplete=>missing.isEmpty&&unverifiedOriginals.isEmpty;
  bool get recordsApplied=>false;
  bool get fullDeviceComplete=>false;
  // 受限内容始终保持受限，伴侣绑定及权限未由导入流程安全重建前不可回落家庭共享。
  bool get restricted=>true;
}

class PortableArchive {
  PortableArchive(this.crypto);final LocalCrypto crypto;
  Stream<List<int>> pack(PortableManifest manifest,Map<String,BackupSource> sources)async*{
    final raw=Uint8List.fromList(utf8.encode(jsonEncode(manifest.toJson())));
    yield _tarHeader('manifest.json',raw.length);yield raw;yield _padding(raw.length);
    for(final e in manifest.entries){
      if(e.missingReason.isNotEmpty)continue;
      final source=sources[e.id];
      if(source==null||source.privacy!=BackupPrivacy.restricted||source.entry.kind!=e.kind||source.entry.size!=e.size||
        source.entry.sha256!=e.sha256||source.entry.sourceExact!=e.sourceExact||source.entry.missing.isNotEmpty)throw const BackupException('portable_source_mismatch');
      yield _tarHeader('entries/${e.id}',e.size);
      final hash=ArchiveSha256();var size=0;
      await for(final bytes in await source.openRange(0,e.size)){
        size+=bytes.length;if(size>e.size||bytes.length>backupChunkBytes)throw const BackupException('portable_source_changed');hash.add(bytes);yield bytes;
      }
      if(size!=e.size||backupHex(hash.finish())!=e.sha256)throw const BackupException('portable_source_changed');
      yield _padding(e.size);
    }
    yield Uint8List(1024);
  }
  /// 只恢复为新隔离目录与新随机文件ID；记录字节保持惰性，不导库、不使用旧URI/设备身份。
  Future<PortableRestore> restoreToNewDirectory(Stream<List<int>> source,Directory privateParent,{required String expectedFamily})async{
    if(Platform.isWindows)throw const BackupException('private_acl_unavailable');
    if(await FileSystemEntity.type(privateParent.path,followLinks:false)!=FileSystemEntityType.directory)throw const BackupException('untrusted_staging_path');
    final reader=ArchiveReader(source);Directory? stage;
    try{
      final header=await reader.exact(512);final size=_tarSize(header);
      _checkTar(header,'manifest.json',size);if(size<1||size>8*1024*1024)throw const BackupException('portable_manifest_limit');
      final raw=await reader.exact(size);await _zeroPadding(reader,size);
      // 发送端契约仅固定 JSON schema，未知字段与 null 拒绝；不能导入业务权限。
      final manifest=PortableManifest.fromJson(backupObject(decodeBackupJson(utf8.decode(raw,allowMalformed:false))));
      if(manifest.familyId!=expectedFamily)throw const BackupException('portable_cross_family');
      stage=await privateParent.createTemp('wo-restored-');
      final files=<String,PortableRecoveredFile>{},missing=<String,String>{},unverified=<String,String>{};
      for(final e in manifest.entries){
        if(e.missingReason.isNotEmpty){missing[e.id]=e.missingReason;continue;}
        _checkTar(await reader.exact(512),'entries/${e.id}',e.size);
        final newId=await _newId();final file=File('${stage.path}${Platform.pathSeparator}$newId.blob');
        final output=await file.open(mode:FileMode.write);final hash=ArchiveSha256();var remaining=e.size;
        try{
          while(remaining>0){final bytes=await reader.exact(remaining.clamp(0,65536).toInt());hash.add(bytes);await output.writeFrom(bytes);remaining-=bytes.length;}
          await output.flush();
        }finally{await output.close();}
        if(backupHex(hash.finish())!=e.sha256)throw const BackupException('portable_entry_integrity');
        await _zeroPadding(reader,e.size);files[e.id]=PortableRecoveredFile(newId,file,e);
        if((e.kind=='photo'||e.kind=='video')&&!e.sourceExact)unverified[e.id]='source_not_exact';
      }
      final end=await reader.exact(1024);if(end.any((b)=>b!=0))throw const BackupException('portable_terminator');await reader.eof();
      var family=await _newId();while(family==manifest.familyId){family=await _newId();}
      final device=await _newId();
      await File('${stage.path}${Platform.pathSeparator}verified.json').writeAsString(jsonEncode({
        'source_family_id':manifest.familyId,'new_family_id':family,'new_device_id':device,'records_applied':false,
        'restricted':true,'full_device_complete':false,'missing':missing,'unverified_originals':unverified,
        'files':{for(final e in files.entries)e.key:{'new_id':e.value.newId,'kind':e.value.entry.kind,'size':e.value.entry.size,'sha256':e.value.entry.sha256,'source_exact':e.value.entry.sourceExact}}
      }),flush:true);
      return PortableRestore._(stage,family,device,Map.unmodifiable(files),Map.unmodifiable(missing),Map.unmodifiable(unverified));
    }catch(_){if(stage!=null)await stage.delete(recursive:true);rethrow;}
    finally{await reader.close();}
  }
  Future<String> _newId()async{final bytes=await crypto.random(16);if(bytes.length!=16)throw const BackupException('invalid_random');return backupHex(bytes);}
}

/// 一次生成并冻结 cipher 文件后重试上传同一 source，不能重新随机加密同一 backup ID。
class SealedBackupSource implements BackupSource {
  SealedBackupSource._(this.directory,this.file,this.entry);
  final Directory directory;final File file;
  @override final BackupEntry entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async{
    if(offset<0||length<0||offset+length>entry.size)throw const BackupException('invalid_source_range');
    if(await FileSystemEntity.type(file.path,followLinks:false)!=FileSystemEntityType.file)throw const BackupException('sealed_source_unavailable');
    return file.openRead(offset,offset+length);
  }
  Future<void> dispose()async{await directory.delete(recursive:true);}
  static Future<SealedBackupSource> create({required String id,required String backupId,required PortableManifest manifest,
      required Map<String,BackupSource> sources,required String recoveryKeyRef,required Directory privateParent,required LocalCrypto crypto})async{
    if(Platform.isWindows)throw const BackupException('private_acl_unavailable');
    if(!validBackupId(id)||!validBackupId(backupId)||await FileSystemEntity.type(privateParent.path,followLinks:false)!=FileSystemEntityType.directory)throw const BackupException('untrusted_staging_path');
    final key=await crypto.getSecret(recoveryKeyRef);if(key==null||key.length!=32)throw const BackupException('recovery_key_unavailable');
    Directory? stage;
    try{
      stage=await privateParent.createTemp('wo-sealed-');final file=File('${stage.path}${Platform.pathSeparator}ciphertext');
      final output=await file.open(mode:FileMode.write),hash=ArchiveSha256();var size=0;
      try{
        final packed=PortableArchive(crypto).pack(manifest,sources);
        await for(final bytes in VaultCodec(crypto).encrypt(packed,key:key,context:VaultContext(manifest.familyId,backupId,id))){
          size+=bytes.length;if(size>backupMaxFileBytes)throw const BackupException('sealed_file_limit');hash.add(bytes);await output.writeFrom(bytes);
        }
        await output.flush();
      }finally{await output.close();}
      final entry=BackupEntry(id:id,kind:'sealed',size:size,sha256:backupHex(hash.finish()),sourceExact:false);
      return SealedBackupSource._(stage,file,entry);
    }catch(_){if(stage!=null)await stage.delete(recursive:true);rethrow;}
    finally{key.fillRange(0,key.length,0);}
  }
}

Uint8List _padding(int size)=>Uint8List((512-size%512)%512);
Future<void> _zeroPadding(ArchiveReader reader,int size)async{if((await reader.exact((512-size%512)%512)).any((b)=>b!=0))throw const BackupException('portable_nonzero_padding');}
void _putString(Uint8List b,int offset,int length,String text){final v=ascii.encode(text);if(v.length>length)throw const BackupException('tar_field_limit');b.setRange(offset,offset+v.length,v);}
void _putOctal(Uint8List b,int offset,int length,int value){_putString(b,offset,length,value.toRadixString(8).padLeft(length-1,'0')+'\u0000');}
Uint8List _tarHeader(String name,int size){
  final b=Uint8List(512);_putString(b,0,100,name);_putOctal(b,100,8,384);_putOctal(b,108,8,0);_putOctal(b,116,8,0);
  if(size<=8589934591){_putOctal(b,124,12,size);}else{var n=size;for(var i=135;i>124;i--){b[i]=n&255;n>>=8;}if(n!=0)throw const BackupException('tar_size_limit');b[124]=128;}
  _putOctal(b,136,12,0);b.fillRange(148,156,32);b[156]=48;_putString(b,257,8,'ustar  \u0000');
  final sum=b.fold<int>(0,(a,v)=>a+v);_putString(b,148,8,sum.toRadixString(8).padLeft(6,'0')+'\u0000 ');return b;
}
int _octal(List<int> b){final s=ascii.decode(b).replaceAll('\u0000','').trim();if(!RegExp(r'^[0-7]+$').hasMatch(s))throw const BackupException('invalid_tar_number');return int.parse(s,radix:8);}
int _tarSize(Uint8List b){
  var n=0;if((b[124]&128)!=0){if(b[124]!=128)throw const BackupException('tar_size_limit');for(var i=125;i<136;i++){n=n*256+b[i];if(n>backupMaxFileBytes)throw const BackupException('tar_size_limit');}return n;}
  n=_octal(Uint8List.sublistView(b,124,136));if(n>backupMaxFileBytes)throw const BackupException('tar_size_limit');return n;
}
void _checkTar(Uint8List b,String name,int size){
  final end=b.indexOf(0);final actual=ascii.decode(Uint8List.sublistView(b,0,end<0?100:end));
  final checksum=_octal(Uint8List.sublistView(b,148,156));var sum=0;for(var i=0;i<512;i++){sum+=(i>=148&&i<156)?32:b[i];}
  if(actual!=name||b[156]!=48||b.sublist(157,257).any((v)=>v!=0)||ascii.decode(b.sublist(257,265))!='ustar  \u0000'||
    _tarSize(b)!=size||checksum!=sum)throw const BackupException('invalid_portable_tar');
}
