import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'archive_io.dart';
import 'backup_models.dart';
import 'backup_transport.dart';
import 'mobile_backup_client.dart';

class _SavedRange {
  _SavedRange(this.directory,this.entryId,this.offset,this.size,this.sha256);
  final Directory directory;final String entryId,sha256;final int offset,size;
  File get file=>File('${directory.path}${Platform.pathSeparator}bytes');
}

/// 调用者只可提供原生层确认的、已排除系统备份的应用私有目录。
/// createTemp 新建隔离 session，永不写业务库/旧媒体路径；同session仅单写者。
class QuarantineStore implements BackupReceiveStore {
  QuarantineStore._(this.directory);
  final Directory directory;
  BackupManifest? _manifest;bool _finished=false;
  final _ranges=<String,List<_SavedRange>>{};
  Directory get _chunks=>Directory('${directory.path}${Platform.pathSeparator}ranges');
  static Future<QuarantineStore> create(Directory privateParent)async{
    await _parent(privateParent);
    final directory=await privateParent.createTemp('wo-download-');
    try{await Directory('${directory.path}${Platform.pathSeparator}ranges').create();return QuarantineStore._(directory);}
    catch(_){await directory.delete(recursive:true);rethrow;}
  }
  /// 只显式恢复本应用同一私有parent中的session，不能传入Downloads/相册或任意已有目录。
  static Future<QuarantineStore> resume(Directory session,Directory privateParent,BackupManifest manifest)async{
    await _parent(privateParent);
    if(await FileSystemEntity.type(session.path,followLinks:false)!=FileSystemEntityType.directory||
      await session.parent.resolveSymbolicLinks()!=await privateParent.resolveSymbolicLinks()||
      !session.uri.pathSegments.where((s)=>s.isNotEmpty).last.startsWith('wo-download-'))throw const BackupException('invalid_quarantine_session');
    final store=QuarantineStore._(session);await store.bind(manifest);return store;
  }
  static Future<void> _parent(Directory parent)async{
    if(Platform.isWindows)throw const BackupException('private_acl_unavailable');
    if(await FileSystemEntity.type(parent.path,followLinks:false)!=FileSystemEntityType.directory)throw const BackupException('untrusted_staging_path');
  }
  @override Future<void> bind(BackupManifest manifest)async{
    final path='${directory.path}${Platform.pathSeparator}manifest.json';
    if(_manifest!=null){if(_manifest!.canonicalJson!=manifest.canonicalJson)throw const BackupException('immutable_manifest_mismatch');return;}
    final kind=await FileSystemEntity.type(path,followLinks:false);
    if(kind==FileSystemEntityType.notFound){await File(path).writeAsString(manifest.canonicalJson,flush:true);}
    else if(kind==FileSystemEntityType.file){
      final file=File(path);if(await file.length()>2*1024*1024)throw const BackupException('manifest_limit');
      final old=BackupManifest.fromJson(backupObject(decodeBackupJson(await file.readAsString())));
      if(old.canonicalJson!=manifest.canonicalJson)throw const BackupException('immutable_manifest_mismatch');
    }else{throw const BackupException('unsafe_quarantine_manifest');}
    if(await FileSystemEntity.type(_chunks.path,followLinks:false)!=FileSystemEntityType.directory)throw const BackupException('unsafe_quarantine_ranges');
    _ranges.clear();for(final e in manifest.entries){_ranges[e.id]=[];}
    var count=0;
    await for(final entity in _chunks.list(followLinks:false)){
      if(++count>135168)throw const BackupException('range_journal_limit');
      if(entity is! Directory||await FileSystemEntity.type(entity.path,followLinks:false)!=FileSystemEntityType.directory)throw const BackupException('unsafe_range_journal');
      final marker=File('${entity.path}${Platform.pathSeparator}commit.json');
      final markerType=await FileSystemEntity.type(marker.path,followLinks:false);
      if(markerType==FileSystemEntityType.notFound){await entity.delete(recursive:true);continue;}
      if(markerType!=FileSystemEntityType.file||await marker.length()>1024)throw const BackupException('invalid_range_journal');
      final j=backupObject(decodeBackupJson(await marker.readAsString()));
      if(j.length!=4||j['entry'] is! String||j['offset'] is! int||j['size'] is! int||j['sha256'] is! String)throw const BackupException('invalid_range_journal');
      final id=j['entry'] as String,offset=j['offset'] as int,size=j['size'] as int,sha=j['sha256'] as String;
      if(!_ranges.containsKey(id)||offset<0||size<1||size>backupChunkBytes||!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha))throw const BackupException('invalid_range_journal');
      _ranges[id]!.add(_SavedRange(entity,id,offset,size,sha));
    }
    for(final e in manifest.entries){final ranges=_ranges[e.id]!;ranges.sort((a,b)=>a.offset.compareTo(b.offset));var offset=0;
      for(final r in ranges){if(r.offset!=offset||offset+r.size>e.size||e.missing.isNotEmpty)throw const BackupException('range_journal_gap');await _verifyRange(r);offset+=r.size;}}
    _manifest=manifest;
  }
  @override Future<int> verifiedOffset(BackupEntry entry)async{
    _entry(entry);var offset=0;for(final r in _ranges[entry.id]!){await _verifyRange(r);if(r.offset!=offset)throw const BackupException('range_journal_gap');offset+=r.size;}return offset;
  }
  @override Future<void> append(BackupEntry entry,int offset,Uint8List bytes,String chunkSha256)async{
    _entry(entry);if(_finished)throw const BackupException('quarantine_already_verified');
    final ranges=_ranges[entry.id]!;final current=ranges.fold<int>(0,(n,r)=>n+r.size);
    final hash=ArchiveSha256()..add(bytes);
    if(offset!=current||entry.missing.isNotEmpty||bytes.isEmpty||bytes.length>backupChunkBytes||offset+bytes.length>entry.size||backupHex(hash.finish())!=chunkSha256)throw const BackupException('invalid_received_chunk');
    final dir=await _chunks.createTemp('range-');
    try{
      await File('${dir.path}${Platform.pathSeparator}bytes').writeAsBytes(bytes,flush:true);
      await File('${dir.path}${Platform.pathSeparator}commit.json').writeAsString(jsonEncode({'entry':entry.id,'offset':offset,'size':bytes.length,'sha256':chunkSha256}),flush:true);
      ranges.add(_SavedRange(dir,entry.id,offset,bytes.length,chunkSha256));
    }catch(_){await dir.delete(recursive:true);rethrow;}
  }
  @override Future<void> finish(BackupManifest manifest)async{
    if(_manifest?.canonicalJson!=manifest.canonicalJson)throw const BackupException('immutable_manifest_mismatch');
    for(final e in manifest.entries){if(e.missing.isNotEmpty)continue;final hash=ArchiveSha256();var length=0;
      for(final r in _ranges[e.id]!){await _verifyRange(r);await for(final bytes in r.file.openRead()){hash.add(bytes);length+=bytes.length;}}
      if(length!=e.size||backupHex(hash.finish())!=e.sha256)throw const BackupException('full_digest_mismatch');
    }
    await File('${directory.path}${Platform.pathSeparator}verified.json').writeAsString(jsonEncode({
      'backup_id':manifest.backupId,'family_id':manifest.familyId,'full_device_complete':false,'records_applied':false,
      'restricted_requires_key':manifest.entries.any((e)=>e.kind=='sealed'),
      'missing':{for(final e in manifest.entries)if(e.missing.isNotEmpty)e.id:e.missing}
    }),flush:true);_finished=true;
  }
  /// 文件仍是惰性缓存，sealed 仍为密文；不会重用源URI、书签、照片ID或设备身份。
  Future<File> materializeVerifiedFile(BackupEntry entry)async{
    _entry(entry);if(!_finished||entry.missing.isNotEmpty)throw const BackupException('quarantine_not_verified');
    final dir=await directory.createTemp('materialized-');final file=File('${dir.path}${Platform.pathSeparator}bytes');
    try{final output=await file.open(mode:FileMode.write),hash=ArchiveSha256();var size=0;
      try{for(final r in _ranges[entry.id]!){await _verifyRange(r);await for(final b in r.file.openRead()){size+=b.length;hash.add(b);await output.writeFrom(b);}}await output.flush();}finally{await output.close();}
      if(size!=entry.size||backupHex(hash.finish())!=entry.sha256)throw const BackupException('full_digest_mismatch');return file;
    }catch(_){await dir.delete(recursive:true);rethrow;}
  }
  void _entry(BackupEntry entry){if(_manifest==null||!_manifest!.entries.any((e)=>jsonEncode(e.toJson())==jsonEncode(entry.toJson())))throw const BackupException('undeclared_entry');}
  Future<void> _verifyRange(_SavedRange r)async{
    if(await FileSystemEntity.type(r.file.path,followLinks:false)!=FileSystemEntityType.file)throw const BackupException('unsafe_range_file');
    final hash=ArchiveSha256();var size=0;
    await for(final b in r.file.openRead()){size+=b.length;if(size>r.size)throw const BackupException('range_digest_mismatch');hash.add(b);}
    if(size!=r.size||backupHex(hash.finish())!=r.sha256)throw const BackupException('range_digest_mismatch');
  }
}
