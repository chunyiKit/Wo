import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../backup/archive_io.dart';
import '../backup/backup_models.dart';
import '../backup/backup_transport.dart';
import '../backup/portable_archive.dart';
import '../local_media_repository.dart';
import '../transport/native_local.dart';

class OwnedMediaException implements Exception {
  const OwnedMediaException(this.code);
  final String code;
  @override String toString()=>'OwnedMediaException($code)';
}

/// 只属于新私有恢复workspace；不是正常家庭/成员身份，也不是原生相册句柄。
class OwnedMediaAsset {
  OwnedMediaAsset._(this.id,this.workspaceId,this.importKey,this.originalEntryId,this.kind,
    this.size,this.sha256,this.sourceExact,this.status,this.missingReason,this.thumbnailId);
  final String id,workspaceId,importKey,originalEntryId,kind,sha256,status,missingReason;
  final int size;
  final bool sourceExact;
  final String? thumbnailId;
  bool get available=>status=='ready';
  bool get declaredBytesComplete=>available&&(!{'photo','video'}.contains(kind)||sourceExact);
  bool get fullDeviceComplete=>false;
  bool get restricted=>true;
  Map<String,dynamic> toLocalRecord()=>{'id':id,'workspace_id':workspaceId,'kind':kind,'expected_size':size,
    'expected_sha256':sha256,'source_exact':sourceExact,'status':status,'missing_reason':missingReason,
    'thumbnail_id':thumbnailId,'full_device_complete':false,'restricted':true};
}

/// 独立SQLite ownership索引和固定原生私有目录；不写LocalStore，不导入旧角色或设备身份。
/// 生产目标只来自NativeCrypto.privateDirectory，调用者不能把任意Directory标成私有。
class OwnedMediaStore {
  OwnedMediaStore._(this._root,this._db,this._crypto,this.storeId);
  final Directory _root;
  final Database _db;
  final NativeCrypto _crypto;
  final String storeId;
  bool _closed=false;
  static const privateDirectoryName='owned-media-v1';
  static const maxReadBytes=8*1024*1024;
  static const _kinds={'records','photo','video','thumbnail','file'};
  static const _missing={'not_on_device','permission_denied','source_missing','source_unavailable','unsupported','not_authorized','source_not_exact','cloud_only','not_exact_original'};
  static final _logical=RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static final _owned=RegExp(r'^o_[a-f0-9]{32}$');
  static final _sha=RegExp(r'^[a-f0-9]{64}$');
  static final _tails=<String,Future<void>>{};
  static bool _full(RegExp pattern,String value){final m=pattern.firstMatch(value);return m!=null&&m.start==0&&m.end==value.length;}
  static Never _fail(String code)=>throw OwnedMediaException(code);
  static Future<T> _serial<T>(String key,Future<T> Function() action){
    final done=Completer<T>();
    final next=(_tails[key]??Future<void>.value()).then((_)async{
      try{done.complete(await action());}catch(e,s){done.completeError(e,s);}
    });
    _tails[key]=next;
    unawaited(next.then((_){if(identical(_tails[key],next))_tails.remove(key);}));return done.future;
  }
  static Future<void> _directory(Directory directory,String expectedParent)async{
    final type=await FileSystemEntity.type(directory.path,followLinks:false);
    if(type==FileSystemEntityType.notFound)await directory.create();
    if(await FileSystemEntity.type(directory.path,followLinks:false)!=FileSystemEntityType.directory||
      p.dirname(await directory.resolveSymbolicLinks())!=expectedParent)_fail('unsafe_owned_directory');
  }
  static Future<void> _regularOrAbsent(File file)async{
    final type=await FileSystemEntity.type(file.path,followLinks:false);
    if(type!=FileSystemEntityType.file&&type!=FileSystemEntityType.notFound)_fail('unsafe_owned_file');
  }
  static Future<RandomAccessFile> _lock(Directory root)async{
    final file=File(p.join(root.path,'owned.lock'));await _regularOrAbsent(file);
    if(await FileSystemEntity.type(file.path,followLinks:false)==FileSystemEntityType.notFound){
      try{await file.create(exclusive:true);}on FileSystemException{await _regularOrAbsent(file);}
    }
    await _regularOrAbsent(file);
    if(await file.resolveSymbolicLinks()!=file.path)_fail('unsafe_owned_file');
    final handle=await file.open(mode:FileMode.append);
    try{await handle.lock(FileLock.exclusive);return handle;}catch(_){await handle.close();rethrow;}
  }
  static Future<void> _unlock(RandomAccessFile file)async{try{await file.unlock();}finally{await file.close();}}
  static Future<OwnedMediaStore> open({NativeCrypto? crypto,DatabaseFactory? factory})async{
    if(Platform.isWindows)_fail('private_acl_unavailable');
    final native=crypto??NativeCrypto();
    final supplied=Directory(await native.privateDirectory(privateDirectoryName));
    if(!p.isAbsolute(supplied.path)||await FileSystemEntity.type(supplied.path,followLinks:false)!=FileSystemEntityType.directory)_fail('untrusted_owned_root');
    final root=Directory(await supplied.resolveSymbolicLinks());
    return _serial(root.path,()async{
      if(await FileSystemEntity.type(root.path,followLinks:false)!=FileSystemEntityType.directory)_fail('untrusted_owned_root');
      final lock=await _lock(root);Database? db;
      try{
        await _directory(Directory(p.join(root.path,'objects')),root.path);
        final path=p.join(root.path,'owned.sqlite');
        for(final suffix in ['', '-wal','-shm','-journal']){await _regularOrAbsent(File('$path$suffix'));}
        db=await (factory??databaseFactory).openDatabase(path,options:OpenDatabaseOptions(version:1,singleInstance:false,onCreate:(db,_)async{
          await db.execute('CREATE TABLE owned_meta (key TEXT PRIMARY KEY,value TEXT NOT NULL)');
          await db.execute('CREATE TABLE owned_assets (id TEXT PRIMARY KEY,workspace_id TEXT NOT NULL,import_key TEXT NOT NULL,original_entry_id TEXT NOT NULL,kind TEXT NOT NULL,expected_size INTEGER NOT NULL,sha256 TEXT NOT NULL,source_exact INTEGER NOT NULL,status TEXT NOT NULL,missing_reason TEXT NOT NULL,thumbnail_id TEXT,created_at TEXT NOT NULL,UNIQUE(workspace_id,import_key))');
          await db.execute('CREATE TABLE owned_orphans (id TEXT PRIMARY KEY,reason TEXT NOT NULL,created_at TEXT NOT NULL)');
        }));
        final rows=await db.query('owned_meta',where:'key=?',whereArgs:['store_id']);
        String identity;
        if(rows.isEmpty){identity=await _randomId(native);await db.insert('owned_meta',{'key':'store_id','value':identity});}
        else{identity=rows.single['value'] as String;if(!_full(_owned,identity))_fail('invalid_owned_index');}
        return OwnedMediaStore._(root,db,native,identity);
      }catch(_){await db?.close();rethrow;}finally{await _unlock(lock);}
    });
  }
  static Future<String> _randomId(NativeCrypto crypto)async{
    final bytes=await crypto.random(16);if(bytes.length!=16)_fail('invalid_random');return 'o_${backupHex(bytes)}';
  }
  void _scope(String workspaceId){if(_closed)_fail('owned_store_closed');if(!_full(_logical,workspaceId))_fail('invalid_workspace');}
  Future<void> _rootSafe()async{
    if(await FileSystemEntity.type(_root.path,followLinks:false)!=FileSystemEntityType.directory||await _root.resolveSymbolicLinks()!=_root.path)_fail('unsafe_owned_root');
    final objects=Directory(p.join(_root.path,'objects'));
    if(await FileSystemEntity.type(objects.path,followLinks:false)!=FileSystemEntityType.directory||await objects.resolveSymbolicLinks()!=objects.path)_fail('unsafe_owned_directory');
  }
  File _file(String id){if(!_full(_owned,id))_fail('invalid_owned_id');return File(p.join(_root.path,'objects','$id.blob'));}
  Future<T> _write<T>(Future<T> Function() action)=>_serial(_root.path,()async{
    if(_closed)_fail('owned_store_closed');await _rootSafe();final lock=await _lock(_root);
    try{return await action();}finally{await _unlock(lock);}
  });
  OwnedMediaAsset _asset(Map<String,Object?> row){
    final id=row['id'],workspace=row['workspace_id'],key=row['import_key'],original=row['original_entry_id'],kind=row['kind'],size=row['expected_size'],sha=row['sha256'],exact=row['source_exact'],status=row['status'],missing=row['missing_reason'],thumbnail=row['thumbnail_id'];
    if(id is! String||!_full(_owned,id)||workspace is! String||!_full(_logical,workspace)||key is! String||!_full(_logical,key)||
      original is! String||!_full(_logical,original)||kind is! String||!_kinds.contains(kind)||size is! int||size<0||size>20*1024*1024*1024||kind=='file'&&size>backupMaxAttachmentBytes||sha is! String||
      exact is! int||exact<0||exact>1||status is! String||!{'copying','ready','failed','missing'}.contains(status)||missing is! String||
      thumbnail!=null&&(thumbnail is! String||!_full(_owned,thumbnail))||
      size>0&&!_full(_sha,sha)||size==0&&sha.isNotEmpty||exact==1&&!{'photo','video'}.contains(kind))_fail('invalid_owned_index');
    return OwnedMediaAsset._(id,workspace,key,original,kind,size,sha,exact==1,status,missing,thumbnail as String?);
  }
  Future<OwnedMediaAsset?> get(String workspaceId,String id)async{
    _scope(workspaceId);if(!_full(_owned,id))_fail('invalid_owned_id');
    final rows=await _db.query('owned_assets',where:'workspace_id=? AND id=?',whereArgs:[workspaceId,id]);return rows.isEmpty?null:_asset(rows.single);
  }
  Future<List<OwnedMediaAsset>> list(String workspaceId)async{
    _scope(workspaceId);final rows=await _db.query('owned_assets',where:'workspace_id=?',whereArgs:[workspaceId],orderBy:'created_at,id');
    return List.unmodifiable(rows.map(_asset));
  }
  Future<OwnedMediaAsset?> byImportKey(String workspaceId,String importKey)async{
    _scope(workspaceId);if(!_full(_logical,importKey))_fail('invalid_import_key');
    final rows=await _db.query('owned_assets',where:'workspace_id=? AND import_key=?',whereArgs:[workspaceId,importKey]);return rows.isEmpty?null:_asset(rows.single);
  }
  Future<OwnedMediaAsset> _required(String workspaceId,String id)async{final value=await get(workspaceId,id);if(value==null)_fail('owned_not_found');return value;}
  Future<void> _thumbnail(String workspaceId,String? id)async{
    if(id==null)return;final asset=await _required(workspaceId,id);
    if(asset.kind!='thumbnail'||!asset.available)_fail('invalid_thumbnail_reference');await _verify(asset);
  }
  static void _entry(PortableEntry entry){
    if(!_kinds.contains(entry.kind)||!_full(_logical,entry.id)||entry.size<0||entry.size>20*1024*1024*1024||entry.kind=='file'&&entry.size>backupMaxAttachmentBytes||
      entry.missingReason.isEmpty&&(entry.size<1||!_full(_sha,entry.sha256))||
      entry.missingReason.isNotEmpty&&(!_missing.contains(entry.missingReason)||entry.size!=0||entry.sha256.isNotEmpty||entry.sourceExact)||
      entry.sourceExact&&!{'photo','video'}.contains(entry.kind))_fail('invalid_recovered_entry');
    if(entry.kind=='thumbnail'&&entry.size>LocalMediaRepository.maxThumbnailBytes)_fail('invalid_recovered_thumbnail');
  }
  static bool _same(OwnedMediaAsset old,PortableEntry entry,String? thumbnail)=>old.originalEntryId==entry.id&&old.kind==entry.kind&&old.size==entry.size&&old.sha256==entry.sha256&&old.sourceExact==entry.sourceExact&&old.thumbnailId==thumbnail;
  Future<String> _freshId()async{
    for(var attempt=0;attempt<16;attempt++){
      final id=await _randomId(_crypto);if(id==storeId)continue;
      if((await _db.query('owned_assets',columns:['id'],where:'id=?',whereArgs:[id],limit:1)).isEmpty&&
        (await _db.query('owned_orphans',columns:['id'],where:'id=?',whereArgs:[id],limit:1)).isEmpty&&
        await FileSystemEntity.type(_file(id).path,followLinks:false)==FileSystemEntityType.notFound)return id;
    }
    _fail('owned_id_collision');
  }
  Future<OwnedMediaAsset> _reserve(String workspace,String key,PortableEntry entry,String? thumbnail,String status,String missing)async{
    _scope(workspace);if(!_full(_logical,key))_fail('invalid_import_key');_entry(entry);await _thumbnail(workspace,thumbnail);
    final old=await byImportKey(workspace,key);if(old!=null){if(!_same(old,entry,thumbnail))_fail('owned_import_conflict');return old;}
    final id=await _freshId();await _db.insert('owned_assets',{'id':id,'workspace_id':workspace,'import_key':key,'original_entry_id':entry.id,
      'kind':entry.kind,'expected_size':entry.size,'sha256':entry.sha256,'source_exact':entry.sourceExact?1:0,
      'status':status,'missing_reason':missing,'thumbnail_id':thumbnail,'created_at':DateTime.now().toUtc().toIso8601String()});
    return (await get(workspace,id))!;
  }
  /// 只接收PortableRestore私有构造器产生的声明/映射，不接收调用方File或旧URI。
  Future<OwnedMediaAsset> importPortable({required String workspaceId,required String importKey,
    required PortableRestore restore,required String entryId,String? thumbnailId})=>_write(()async{
    _scope(workspaceId);final entries=restore.manifest.entries.where((e)=>e.id==entryId).toList();
    if(entries.length!=1)_fail('undeclared_recovered_entry');final entry=entries.single;_entry(entry);
    final recovered=restore.files[entryId];
    if(entry.missingReason.isNotEmpty){
      if(recovered!=null||restore.missing[entryId]!=entry.missingReason)_fail('invalid_recovered_mapping');
      return _reserve(workspaceId,importKey,entry,thumbnailId,'missing',entry.missingReason);
    }
    if(recovered==null||jsonEncode(recovered.entry.toJson())!=jsonEncode(entry.toJson()))_fail('invalid_recovered_mapping');
    await _source(restore.directory,recovered.file);
    var asset=await _reserve(workspaceId,importKey,entry,thumbnailId,'copying','');
    if(asset.available){await _verify(asset);return asset;}
    final file=_file(asset.id),type=await FileSystemEntity.type(file.path,followLinks:false);
    if(type!=FileSystemEntityType.notFound){
      if(type!=FileSystemEntityType.file)_fail('unsafe_owned_file');
      try{await _verify(asset);await _db.update('owned_assets',{'status':'ready','missing_reason':''},where:'id=? AND workspace_id=?',whereArgs:[asset.id,workspaceId]);return (await get(workspaceId,asset.id))!;}
      on OwnedMediaException catch(e){
        if(e.code!='owned_integrity')rethrow;
        final fresh=await _freshId();
        // 未发布的失败对象留在私有目录，不覆盖、不截断、也不复用它的媒体ID。
        await _db.transaction((tx)async{
          await tx.insert('owned_orphans',{'id':asset.id,'reason':'incomplete_copy','created_at':DateTime.now().toUtc().toIso8601String()});
          await tx.update('owned_assets',{'id':fresh,'status':'copying','missing_reason':''},where:'workspace_id=? AND id=?',whereArgs:[workspaceId,asset.id]);
        });asset=(await get(workspaceId,fresh))!;
      }
    }
    final target=_file(asset.id);
    try{
      await _rootSafe();await _source(restore.directory,recovered.file);
      // exclusive create在任何写open之前；现有目标绝不通过write/rename覆盖。
      await target.create(exclusive:true);
      final output=await target.open(mode:FileMode.writeOnly),hash=ArchiveSha256();var count=0;
      try{
        await for(final chunk in recovered.file.openRead()){
          count+=chunk.length;if(count>entry.size)_fail('recovered_integrity');hash.add(chunk);await output.writeFrom(chunk);
        }
        await output.flush();
      }finally{await output.close();}
      await _source(restore.directory,recovered.file);
      if(count!=entry.size||backupHex(hash.finish())!=entry.sha256)_fail('recovered_integrity');
      await _verify(asset); // 对实际落盘目标再次流式核验，不能只相信源流摘要。
      await _db.update('owned_assets',{'status':'ready','missing_reason':''},where:'id=? AND workspace_id=?',whereArgs:[asset.id,workspaceId]);
      return (await get(workspaceId,asset.id))!;
    }catch(e){
      await _db.update('owned_assets',{'status':'failed','missing_reason':'source_unavailable'},where:'id=? AND workspace_id=?',whereArgs:[asset.id,workspaceId]);
      if(e is OwnedMediaException)rethrow;_fail('owned_copy_failed');
    }
  });
  static Future<void> _source(Directory root,File file)async{
    if(await FileSystemEntity.type(root.path,followLinks:false)!=FileSystemEntityType.directory||
      await FileSystemEntity.type(file.path,followLinks:false)!=FileSystemEntityType.file)_fail('unsafe_recovered_source');
    final parent=await root.resolveSymbolicLinks(),resolved=await file.resolveSymbolicLinks();
    if(await file.parent.resolveSymbolicLinks()!=parent||p.dirname(resolved)!=parent||p.basename(resolved)!=p.basename(file.path))_fail('unsafe_recovered_source');
  }
  Future<FileStat> _verify(OwnedMediaAsset asset)async{
    await _rootSafe();final file=_file(asset.id);
    if(await FileSystemEntity.type(file.path,followLinks:false)!=FileSystemEntityType.file)_fail('owned_unavailable');
    if(await file.resolveSymbolicLinks()!=file.path)_fail('unsafe_owned_file');final before=await file.stat();
    if(before.size!=asset.size)_fail('owned_integrity');
    final hash=ArchiveSha256();var count=0;
    await for(final bytes in file.openRead()){count+=bytes.length;if(count>asset.size)_fail('owned_integrity');hash.add(bytes);}
    final after=await file.stat();
    if(count!=asset.size||backupHex(hash.finish())!=asset.sha256||!_sameStat(before,after))_fail('owned_integrity');
    if(asset.kind=='thumbnail'){
      if(asset.size>LocalMediaRepository.maxThumbnailBytes)_fail('invalid_owned_thumbnail');
      final thumbnail=await file.readAsBytes(),thumbnailHash=ArchiveSha256();thumbnailHash.add(thumbnail);
      if(thumbnail.length!=asset.size||backupHex(thumbnailHash.finish())!=asset.sha256||!_sameStat(after,await file.stat()))_fail('owned_integrity');
      try{LocalMediaRepository.validateThumbnail(thumbnail);}on FormatException{_fail('invalid_owned_thumbnail');}
    }
    return after;
  }
  static bool _sameStat(FileStat a,FileStat b)=>a.type==b.type&&a.size==b.size&&a.modified==b.modified&&a.changed==b.changed;
  Future<File?> verifiedFile(String workspaceId,String id)async{
    final asset=await _required(workspaceId,id);if(!asset.available)return null;await _verify(asset);return _file(asset.id);
  }
  Future<Uint8List> read(String workspaceId,String id,{required int offset,int maxBytes=maxReadBytes})async{
    if(maxBytes<1||maxBytes>maxReadBytes)_fail('owned_read_limit');
    final asset=await _required(workspaceId,id);if(!asset.available)_fail('owned_unavailable');
    if(offset<0||offset>asset.size)_fail('invalid_owned_range');final count=(asset.size-offset).clamp(0,maxBytes).toInt();
    final stat=await _verify(asset),out=BytesBuilder(copy:false);
    await for(final bytes in _range(asset,stat,offset,count)){out.add(bytes);}return out.takeBytes();
  }
  Future<Stream<List<int>>> openRange(String workspaceId,String id,int offset,int length)async{
    final asset=await _required(workspaceId,id);if(!asset.available)_fail('owned_unavailable');
    if(offset<0||length<0||offset+length>asset.size)_fail('invalid_owned_range');return _range(asset,await _verify(asset),offset,length);
  }
  Stream<List<int>> _range(OwnedMediaAsset asset,FileStat snapshot,int offset,int length)async*{
    await _rootSafe();final file=_file(asset.id);
    if(await FileSystemEntity.type(file.path,followLinks:false)!=FileSystemEntityType.file||await file.resolveSymbolicLinks()!=file.path||!_sameStat(await file.stat(),snapshot))_fail('owned_source_changed');
    final input=await file.open(mode:FileMode.read);var left=length;
    try{
      await input.setPosition(offset);
      while(left>0){final bytes=await input.read(left>65536?65536:left);if(bytes.isEmpty)_fail('owned_source_changed');left-=bytes.length;yield bytes;}
    }finally{await input.close();}
    if(! _sameStat(await file.stat(),snapshot))_fail('owned_source_changed');
  }
  /// 所有恢复资料再次备份仍为restricted；entryId可重映射，默认保留原归档条目关系。
  Future<BackupSource> prepareBackupSource(String workspaceId,String id,{String? entryId})async{
    final asset=await _required(workspaceId,id);final backupId=entryId??asset.originalEntryId;
    if(!validBackupId(backupId)||!_full(_logical,backupId))_fail('invalid_backup_entry_id');
    if(!asset.available)return _OwnedMissingSource(backupId,asset.kind,_backupMissing(asset.missingReason));
    FileStat stat;
    try{stat=await _verify(asset);}on OwnedMediaException catch(e){
      if(e.code=='owned_integrity'||e.code=='owned_unavailable')return _OwnedMissingSource(backupId,asset.kind,'source_unavailable');rethrow;
    }
    return _OwnedSource(this,asset,stat,BackupEntry(id:backupId,kind:asset.kind,size:asset.size,sha256:asset.sha256,sourceExact:asset.sourceExact));
  }
  static String _backupMissing(String reason)=>switch(reason){'permission_denied'||'not_authorized'=>'permission_denied','cloud_only'=>'cloud_only','source_not_exact'||'not_exact_original'=>'not_exact_original',_=>'source_unavailable'};
  Future<void> close()=>_serial(_root.path,()async{
    if(_closed)return;await _rootSafe();final lock=await _lock(_root);
    try{_closed=true;await _db.close();}finally{await _unlock(lock);}
  });
}
class _OwnedSource extends BackupSource {
  _OwnedSource(this.store,this.asset,this.snapshot,this.entry);
  final OwnedMediaStore store;final OwnedMediaAsset asset;final FileStat snapshot;
  @override final BackupEntry entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async{
    if(offset<0||length<0||offset+length>entry.size)throw const OwnedMediaException('invalid_owned_range');
    return store._range(asset,snapshot,offset,length);
  }
}
class _OwnedMissingSource extends BackupSource {
  _OwnedMissingSource(String id,String kind,String reason):entry=BackupEntry(id:id,kind:kind,size:0,sha256:'',sourceExact:false,missing:reason);
  @override final BackupEntry entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>throw const OwnedMediaException('owned_unavailable');
}
