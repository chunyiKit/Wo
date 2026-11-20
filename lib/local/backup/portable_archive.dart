import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../transport/native_local.dart';
import 'archive_io.dart';
import 'backup_models.dart';
import 'backup_transport.dart';
import 'vault_codec.dart';
import 'package_binding.dart';
import 'quarantine_store.dart';

const _portableKinds={'records','photo','video','thumbnail','file'};
const _portableMissing={'not_on_device','permission_denied','source_missing','source_unavailable','unsupported','not_authorized','source_not_exact'};
final _portableId=RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$');
class PortableEntry {
  PortableEntry({required this.id,required this.kind,required this.size,required this.sha256,
      required this.sourceExact,this.missingReason=''}) {
    if(!_portableId.hasMatch(id)||!_portableKinds.contains(kind))throw const BackupException('invalid_portable_entry');
    if(kind=='file'&&size>backupMaxAttachmentBytes)throw const BackupException('portable_file_limit');
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
  PortableManifest({required this.familyId,required Iterable<PortableEntry> entries,int? version}):entries=List.unmodifiable(entries){
    this.version=version??(this.entries.any((e)=>e.kind=='file')?2:1);
    if(![1,2].contains(this.version)||this.version==1&&this.entries.any((e)=>e.kind=='file'))throw const BackupException('unsupported_portable_version');
    if(!_portableId.hasMatch(familyId)||this.entries.length>20000)throw const BackupException('portable_limit');
    final seen=<String>{};var total=0;
    for(final e in this.entries){if(!seen.add(e.id))throw const BackupException('duplicate_portable_id');total+=e.size;}
    if(total>100*1024*1024*1024||utf8.encode(jsonEncode(toJson())).length>8*1024*1024)throw const BackupException('portable_limit');
  }
  late final int version;final String familyId;final List<PortableEntry> entries;
  Map<String,dynamic> toJson()=>{'version':version,'family_id':familyId,'entries':entries.map((e)=>e.toJson()).toList()};
  factory PortableManifest.fromJson(Map<String,dynamic> j){
    if(j.length!=3||j['version'] is! int||![1,2].contains(j['version'])||j['family_id'] is! String||j['entries'] is! List)throw const BackupException('invalid_portable_json');
    return PortableManifest(version:j['version'] as int,familyId:j['family_id'] as String,entries:(j['entries'] as List).map((e)=>PortableEntry.fromJson(backupObject(e))));
  }
}
class PortableRecoveredFile {
  PortableRecoveredFile(this.newId,this.file,this.entry);
  final String newId;final File file;final PortableEntry entry;
}
class PortableRestore {
  PortableRestore._(this.directory,this.manifest,this.newFamilyId,this.newDeviceId,this.files,this.missing,this.unverifiedOriginals,{this.packageOrigin,this.excludedPublicEntries=0,this.coverageIssues=const []});
  final Directory directory;final PortableManifest manifest;final String newFamilyId,newDeviceId;
  String get sourceFamilyId=>manifest.familyId;
  final Map<String,dynamic>? packageOrigin;final int excludedPublicEntries;final List<String> coverageIssues;
  bool get packageBound=>packageOrigin!=null;
  final Map<String,PortableRecoveredFile> files;final Map<String,String> missing,unverifiedOriginals;
  bool get declaredBytesComplete=>missing.isEmpty&&unverifiedOriginals.isEmpty&&excludedPublicEntries==0&&coverageIssues.isEmpty;
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
      var coverageIssues=const <String>[];
      final coverageEntry=manifest.entries.where((e)=>e.id==BackupPackageBinding.coverageEntryId).toList();
      if(coverageEntry.isNotEmpty){final e=coverageEntry.single,f=files[e.id];
        if(e.kind!='records'||e.missingReason.isNotEmpty||e.size>65536||f==null||await f.file.length()!=e.size)throw const BackupException('invalid_recovery_coverage');
        coverageIssues=BackupPackageBinding.readCoverage(await f.file.readAsBytes(),manifest.familyId);
      }
      var family=await _newId();while(family==manifest.familyId){family=await _newId();}
      final device=await _newId();
      await File('${stage.path}${Platform.pathSeparator}verified.json').writeAsString(jsonEncode({
        'source_family_id':manifest.familyId,'new_family_id':family,'new_device_id':device,'records_applied':false,
        'restricted':true,'full_device_complete':false,'coverage_issues':coverageIssues,'missing':missing,'unverified_originals':unverified,
        'files':{for(final e in files.entries)e.key:{'new_id':e.value.newId,'kind':e.value.entry.kind,'size':e.value.entry.size,'sha256':e.value.entry.sha256,'source_exact':e.value.entry.sourceExact}}
      }),flush:true);
      return PortableRestore._(stage,manifest,family,device,Map.unmodifiable(files),Map.unmodifiable(missing),Map.unmodifiable(unverified),coverageIssues:coverageIssues);
    }catch(_){if(stage!=null)await stage.delete(recursive:true);rethrow;}
    finally{await reader.close();}
  }
  /// 生产入口仅由restoreRestrictedBackup在VaultContext认证之后调用。
  /// 不靠ID推断关联：先验证加密索引完整inventory，再从同一已验证receiver流式取公开字节。
  Future<PortableRestore> bindOuterPackage(PortableRestore inner,BackupManifest outer,String sealedId,QuarantineStore receiver)async{
    if(inner.sourceFamilyId!=outer.familyId||!receiver.verifiedFor(outer))throw const BackupException('package_receiver_mismatch');
    final public=outer.entries.where((e)=>e.kind!='sealed').toList();
    final indexes=inner.manifest.entries.where((e)=>e.id==BackupPackageBinding.entryId).toList();
    if(indexes.isEmpty)return PortableRestore._(inner.directory,inner.manifest,inner.newFamilyId,inner.newDeviceId,
      inner.files,inner.missing,inner.unverifiedOriginals,excludedPublicEntries:public.length,coverageIssues:inner.coverageIssues);
    if(indexes.length!=1||indexes.single.kind!='records'||indexes.single.missingReason.isNotEmpty)throw const BackupException('package_binding_invalid');
    final index=indexes.single,source=inner.files[BackupPackageBinding.entryId];
    if(source==null||index.size>BackupPackageBinding.maxBytes||await FileSystemEntity.type(source.file.path,followLinks:false)!=FileSystemEntityType.file||
      source.file.parent.absolute.path!=inner.directory.absolute.path||await source.file.length()!=index.size)throw const BackupException('package_binding_invalid');
    final raw=BytesBuilder(copy:false);var length=0;
    await for(final chunk in source.file.openRead()){length+=chunk.length;if(length>index.size)throw const BackupException('package_binding_invalid');raw.add(chunk);}
    final bytes=raw.takeBytes();if(length!=index.size||BackupPackageBinding.digest(bytes)!=index.sha256)throw const BackupException('package_binding_invalid');
    BackupPackageBinding.validate(bytes,outer:outer,sealedId:sealedId,innerEntries:inner.manifest.entries.map((e)=>e.toJson()));
    final entries=<PortableEntry>[...inner.manifest.entries,for(final e in public)PortableEntry(id:e.id,kind:e.kind,size:e.size,sha256:e.sha256,sourceExact:e.sourceExact,
      missingReason:switch(e.missing){'permission_denied'=>'permission_denied','cloud_only'=>'not_on_device','not_exact_original'=>'source_not_exact','source_unavailable'=>'source_unavailable',_=>''})];
    final manifest=PortableManifest(familyId:outer.familyId,entries:entries);
    final files=<String,PortableRecoveredFile>{...inner.files},missing=<String,String>{...inner.missing},unverified=<String,String>{...inner.unverifiedOriginals};
    final created=<File>[];
    try{
      for(final entry in entries.skip(inner.manifest.entries.length)){
        if(entry.missingReason.isNotEmpty){missing[entry.id]=entry.missingReason;continue;}
        final original=public.singleWhere((e)=>e.id==entry.id),newId=await _newId();
        final target=File('${inner.directory.path}/$newId.blob');await target.create(exclusive:true);created.add(target);
        final output=await target.open(mode:FileMode.writeOnly),hash=ArchiveSha256();var count=0;
        try{await for(final chunk in receiver.verifiedRead(original)){count+=chunk.length;if(count>entry.size)throw const BackupException('package_public_integrity');hash.add(chunk);await output.writeFrom(chunk);}await output.flush();}
        finally{await output.close();}
        if(count!=entry.size||backupHex(hash.finish())!=entry.sha256)throw const BackupException('package_public_integrity');
        files[entry.id]=PortableRecoveredFile(newId,target,entry);
        if((entry.kind=='photo'||entry.kind=='video')&&!entry.sourceExact)unverified[entry.id]='source_not_exact';
      }
      final origin=Map<String,dynamic>.unmodifiable({'family_id':outer.familyId,'backup_id':outer.backupId,'sealed_id':sealedId,
        'index_sha256':index.sha256,'outer_manifest_sha256':BackupPackageBinding.digest(Uint8List.fromList(utf8.encode(outer.canonicalJson))),
        'public_entries':public.length});
      final marker=File('${inner.directory.path}/verified.json');
      if(await FileSystemEntity.type(marker.path,followLinks:false)!=FileSystemEntityType.file)throw const BackupException('package_marker_invalid');
      await marker.writeAsString(jsonEncode({'source_family_id':outer.familyId,'new_family_id':inner.newFamilyId,'new_device_id':inner.newDeviceId,
        'records_applied':false,'full_device_complete':false,'restricted':true,'coverage_issues':inner.coverageIssues,'package_origin':origin,'missing':missing,'unverified_originals':unverified,
        'files':{for(final e in files.entries)e.key:{'new_id':e.value.newId,...e.value.entry.toJson()}}}),flush:true);
      return PortableRestore._(inner.directory,manifest,inner.newFamilyId,inner.newDeviceId,Map.unmodifiable(files),Map.unmodifiable(missing),Map.unmodifiable(unverified),packageOrigin:origin,coverageIssues:inner.coverageIssues);
    }catch(_){for(final file in created){try{await file.delete();}catch(_){}}rethrow;}
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
