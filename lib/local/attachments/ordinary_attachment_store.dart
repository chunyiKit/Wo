import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../backup/backup_models.dart';
import '../transport/native_local.dart';
import 'attachment_descriptor.dart';
export 'attachment_descriptor.dart';

class NativeAttachmentSelection implements AttachmentSelectionSource {
  NativeAttachmentSelection({MethodChannel? channel}):channel=channel??const MethodChannel('wo.local/attachments');
  final MethodChannel channel;
  static void _purpose(String purpose){if(!ordinaryAttachmentPurposes.contains(purpose))attachmentFail('invalid_attachment_purpose');}
  @override Future<AttachmentSelectionMetadata?> pick({required String purpose})async{
    _purpose(purpose);final value=await channel.invokeMapMethod<dynamic,dynamic>('pick',{'purpose':purpose});
    if(value==null)return null;final result=AttachmentSelectionMetadata.fromMap(value);
    if(result.purpose!=purpose)attachmentFail('attachment_purpose_mismatch');return result;
  }
  @override Future<AttachmentSelectionMetadata> claim({required String token,required String purpose})async{
    AttachmentSelectionMetadata.checkToken(token);_purpose(purpose);
    final value=await channel.invokeMapMethod<dynamic,dynamic>('claim',{'token':token,'purpose':purpose});
    if(value==null)attachmentFail('attachment_token_unavailable');final result=AttachmentSelectionMetadata.fromMap(value);
    if(result.token!=token||result.purpose!=purpose)attachmentFail('attachment_purpose_mismatch');return result;
  }
  @override Future<Uint8List> read({required String token,required int offset,required int maxBytes})async{
    AttachmentSelectionMetadata.checkToken(token);
    if(offset<0||offset>ordinaryAttachmentMaxBytes||maxBytes<1||maxBytes>ordinaryAttachmentChunkBytes)attachmentFail('invalid_attachment_range');
    final value=await channel.invokeMethod<Uint8List>('read',{'token':token,'offset':offset,'maxBytes':maxBytes});
    if(value==null||value.length>maxBytes)attachmentFail('invalid_attachment_chunk');return value;
  }
  @override Future<void> release(String token)async{AttachmentSelectionMetadata.checkToken(token);await channel.invokeMethod<void>('release',{'token':token});}
}

class OrdinaryAttachmentAsset {
  OrdinaryAttachmentAsset._(this.descriptor,this.status,this.offset,this.missingReason,this._objectKey);
  final AttachmentDescriptor descriptor;
  final String status,missingReason,_objectKey;
  final int offset;
  String get id=>descriptor.id;
  bool get available=>status=='ready';
}

/// 普通附件副本独立索引。成员/父记录/作者权限必须由route和adapter在每次操作时复核。
/// 唯一导入能力为本用途原生picker token；不接受任意File、URI或其它媒体仓库的引用。
class OrdinaryAttachmentStore {
  OrdinaryAttachmentStore._(this._root,this._db,this._crypto,this.native);
  final Directory _root;final Database _db;final NativeCrypto _crypto;
  final AttachmentSelectionSource native;
  bool _closed=false;
  static const privateDirectoryName='ordinary-attachments-v1';
  static const maxBytes=ordinaryAttachmentMaxBytes,chunkBytes=ordinaryAttachmentChunkBytes;
  static final _object=RegExp(r'^b_[a-f0-9]{32}$');
  static final _tails=<String,Future<void>>{};
  static Future<T> _serial<T>(String key,Future<T> Function() action){
    final done=Completer<T>();
    final next=(_tails[key]??Future<void>.value()).then((_)async{try{done.complete(await action());}catch(e,s){done.completeError(e,s);}});
    _tails[key]=next;unawaited(next.then((_){if(identical(_tails[key],next))_tails.remove(key);}));return done.future;
  }
  static Future<void> _regularOrAbsent(File file)async{
    final type=await FileSystemEntity.type(file.path,followLinks:false);
    if(type!=FileSystemEntityType.file&&type!=FileSystemEntityType.notFound)attachmentFail('unsafe_attachment_file');
  }
  static Future<RandomAccessFile> _lock(Directory root)async{
    final file=File(p.join(root.path,'attachments.lock'));await _regularOrAbsent(file);
    if(await FileSystemEntity.type(file.path,followLinks:false)==FileSystemEntityType.notFound){
      try{await file.create(exclusive:true);}on FileSystemException{await _regularOrAbsent(file);}
    }
    if(await file.resolveSymbolicLinks()!=file.path)attachmentFail('unsafe_attachment_file');
    final lock=await file.open(mode:FileMode.append);
    try{await lock.lock(FileLock.exclusive);return lock;}catch(_){await lock.close();rethrow;}
  }
  static Future<void> _unlock(RandomAccessFile lock)async{try{await lock.unlock();}finally{await lock.close();}}
  static Future<OrdinaryAttachmentStore> open({NativeCrypto? crypto,AttachmentSelectionSource? native,DatabaseFactory? factory})async{
    if(Platform.isWindows)attachmentFail('private_acl_unavailable');
    final trusted=crypto??NativeCrypto();
    final supplied=Directory(await trusted.privateDirectory(privateDirectoryName));
    if(!p.isAbsolute(supplied.path)||await FileSystemEntity.type(supplied.path,followLinks:false)!=FileSystemEntityType.directory)attachmentFail('untrusted_attachment_root');
    final root=Directory(await supplied.resolveSymbolicLinks());
    return _serial(root.path,()async{
      final lock=await _lock(root);Database? db;
      try{
        final objects=Directory(p.join(root.path,'objects'));
        if(await FileSystemEntity.type(objects.path,followLinks:false)==FileSystemEntityType.notFound)await objects.create();
        if(await FileSystemEntity.type(objects.path,followLinks:false)!=FileSystemEntityType.directory||await objects.resolveSymbolicLinks()!=objects.path)attachmentFail('unsafe_attachment_directory');
        final path=p.join(root.path,'attachments.sqlite');
        for(final suffix in ['', '-wal','-shm','-journal']){await _regularOrAbsent(File('$path$suffix'));}
        db=await (factory??databaseFactory).openDatabase(path,options:OpenDatabaseOptions(version:1,singleInstance:false,onCreate:(db,_)async{
          await db.execute('CREATE TABLE attachments (id TEXT PRIMARY KEY,family_id TEXT NOT NULL,plugin TEXT NOT NULL,parent_id TEXT NOT NULL,author_device_id TEXT NOT NULL,descriptor TEXT NOT NULL,object_key TEXT NOT NULL UNIQUE,status TEXT NOT NULL,received_size INTEGER NOT NULL,missing_reason TEXT NOT NULL)');
          await db.execute('CREATE TABLE attachment_orphans (object_key TEXT PRIMARY KEY,reason TEXT NOT NULL)');
          await db.execute('CREATE INDEX attachments_parent ON attachments(family_id,plugin,parent_id)');
        }));
        return OrdinaryAttachmentStore._(root,db,trusted,native??NativeAttachmentSelection());
      }catch(_){await db?.close();rethrow;}finally{await _unlock(lock);}
    });
  }
  Future<void> _safe()async{
    if(_closed)attachmentFail('attachment_store_closed');
    if(await FileSystemEntity.type(_root.path,followLinks:false)!=FileSystemEntityType.directory||await _root.resolveSymbolicLinks()!=_root.path)attachmentFail('unsafe_attachment_directory');
    final objects=Directory(p.join(_root.path,'objects'));
    if(await FileSystemEntity.type(objects.path,followLinks:false)!=FileSystemEntityType.directory||await objects.resolveSymbolicLinks()!=objects.path)attachmentFail('unsafe_attachment_directory');
    final path=p.join(_root.path,'attachments.sqlite');for(final suffix in ['', '-wal','-shm','-journal']){await _regularOrAbsent(File('$path$suffix'));}
  }
  Future<T> _write<T>(Future<T> Function() action)=>_serial(_root.path,()async{
    await _safe();final lock=await _lock(_root);try{return await action();}finally{await _unlock(lock);}
  });
  File _file(String objectKey){if(!attachmentFullMatch(_object,objectKey))attachmentFail('invalid_attachment_index');return File(p.join(_root.path,'objects','$objectKey.blob'));}
  Future<String> _random(String prefix)async{final b=await _crypto.random(16);if(b.length!=16)attachmentFail('attachment_random_failed');return '$prefix${b.map((v)=>v.toRadixString(16).padLeft(2,'0')).join()}';}
  Future<String> _freshObject()async{
    for(var n=0;n<16;n++){
      final key=await _random('b_');if((await _db.query('attachments',columns:['id'],where:'object_key=?',whereArgs:[key])).isNotEmpty)continue;
      if((await _db.query('attachment_orphans',where:'object_key=?',whereArgs:[key])).isNotEmpty)continue;
      if(await FileSystemEntity.type(_file(key).path,followLinks:false)==FileSystemEntityType.notFound)return key;
    }
    attachmentFail('attachment_id_collision');
  }
  Future<String> _freshId()async{for(var n=0;n<16;n++){final id=await _random('a_');if((await _db.query('attachments',columns:['id'],where:'id=?',whereArgs:[id])).isEmpty)return id;}attachmentFail('attachment_id_collision');}
  OrdinaryAttachmentAsset _asset(Map<String,Object?> row){
    final d=AttachmentDescriptor.fromJson(Map<String,dynamic>.from(jsonDecode(row['descriptor'] as String) as Map));
    final status=row['status'],offset=row['received_size'],key=row['object_key'],missing=row['missing_reason'];
    if(row['id']!=d.id||row['family_id']!=d.familyId||row['plugin']!=d.plugin||row['parent_id']!=d.parentId||row['author_device_id']!=d.authorDeviceId||
      key is! String||!attachmentFullMatch(_object,key)||status is! String||!{'receiving','ready','corrupt','missing'}.contains(status)||
      offset is! int||offset<0||offset>d.size||status=='ready'&&offset!=d.size||missing is! String)attachmentFail('invalid_attachment_index');
    return OrdinaryAttachmentAsset._(d,status,offset,missing,key);
  }
  Future<OrdinaryAttachmentAsset?> _byId(String id)async{
    if(!AttachmentDescriptor.validId(id))attachmentFail('invalid_attachment_id');await _safe();
    final rows=await _db.query('attachments',where:'id=?',whereArgs:[id]);return rows.isEmpty?null:_asset(rows.single);
  }
  static void _binding(AttachmentBinding binding,AttachmentDescriptor descriptor){if(!binding.matches(descriptor.binding))attachmentFail('attachment_binding_conflict');}
  Future<OrdinaryAttachmentAsset?> get(AttachmentBinding binding,String id)async{final value=await _byId(id);if(value!=null)_binding(binding,value.descriptor);return value;}
  Future<List<OrdinaryAttachmentAsset>> list(AttachmentBinding binding)async{
    await _safe();final rows=await _db.query('attachments',where:'family_id=? AND plugin=? AND parent_id=? AND author_device_id=?',whereArgs:[binding.familyId,binding.plugin,binding.parentId,binding.authorDeviceId],orderBy:'id');
    return List.unmodifiable(rows.map(_asset));
  }
  Future<OrdinaryAttachmentAsset> _required(AttachmentBinding binding,String id)async{final a=await get(binding,id);if(a==null)attachmentFail('attachment_not_found');return a;}
  Future<void> _insert(AttachmentDescriptor d,String key,String status,int offset)async{
    await _db.insert('attachments',{'id':d.id,'family_id':d.familyId,'plugin':d.plugin,'parent_id':d.parentId,'author_device_id':d.authorDeviceId,
      'descriptor':jsonEncode(d.toJson()),'object_key':key,'status':status,'received_size':offset,'missing_reason':''});
  }
  Future<AttachmentSelectionMetadata?> pick({required String purpose}){
    if(!ordinaryAttachmentPurposes.contains(purpose))attachmentFail('invalid_attachment_purpose');return native.pick(purpose:purpose);
  }
  Future<void> releaseSelection(String token){AttachmentSelectionMetadata.checkToken(token);return native.release(token);}
  /// 指定attachmentId是同父记录请求的幂等键；已就绪对象先完整复验，不消费旧token。
  Future<OrdinaryAttachmentAsset> importSelection({required String selectionToken,required String purpose,
    required AttachmentBinding binding,String? attachmentId})=>_write(()async{
    AttachmentSelectionMetadata.checkToken(selectionToken);
    try{
      if(!ordinaryAttachmentPurposes.contains(purpose)||!purpose.startsWith('${binding.plugin}_'))attachmentFail('attachment_purpose_mismatch');
      if(attachmentId!=null){final old=await get(binding,attachmentId);if(old!=null){
        if(old.descriptor.purpose!=purpose)attachmentFail('attachment_binding_conflict');
        if(!old.available)attachmentFail('attachment_local_id_unavailable');await _verify(old);return old;
      }}
      final m=await native.claim(token:selectionToken,purpose:purpose);
      if(m.token!=selectionToken||m.purpose!=purpose)attachmentFail('attachment_purpose_mismatch');
      final id=attachmentId??await _freshId(),name=safeAttachmentDisplayName(m.displayName),stamp=DateTime.now().toUtc().toIso8601String();
      // Validate all metadata before reserving disk space; this temporary descriptor is never persisted/exported.
      AttachmentDescriptor(id:id,binding:binding,purpose:purpose,kind:m.kind,displayName:name,contentType:m.contentType,size:m.size,sha256:List.filled(64,'0').join(),createdAt:stamp);
      final key=await _freshObject(),file=_file(key);await file.create(exclusive:true);
      await _db.insert('attachment_orphans',{'object_key':key,'reason':'selection_copy_pending'});
      final output=await file.open(mode:FileMode.writeOnlyAppend);
      try{
        var offset=0;
        while(offset<m.size){final count=(m.size-offset).clamp(1,chunkBytes).toInt();final bytes=await native.read(token:selectionToken,offset:offset,maxBytes:count);
          if(bytes.isEmpty||bytes.length>count)attachmentFail('attachment_source_changed');await output.writeFrom(bytes);offset+=bytes.length;
        }
        if((await native.read(token:selectionToken,offset:m.size,maxBytes:1)).isNotEmpty)attachmentFail('attachment_source_changed');
        await output.flush();
      }finally{await output.close();}
      final digest=(await hashes.sha256.bind(file.openRead()).first).toString();
      final descriptor=AttachmentDescriptor(id:id,binding:binding,purpose:purpose,kind:m.kind,displayName:name,contentType:m.contentType,size:m.size,sha256:digest,createdAt:stamp);
      final candidate=OrdinaryAttachmentAsset._(descriptor,'ready',m.size,'',key);await _verify(candidate);
      await _db.transaction((tx)async{
        await tx.insert('attachments',{'id':id,'family_id':binding.familyId,'plugin':binding.plugin,'parent_id':binding.parentId,'author_device_id':binding.authorDeviceId,
          'descriptor':jsonEncode(descriptor.toJson()),'object_key':key,'status':'ready','received_size':m.size,'missing_reason':''});
        await tx.delete('attachment_orphans',where:'object_key=?',whereArgs:[key]);
      });return candidate;
    }finally{try{await native.release(selectionToken);}catch(_){}}
  });
  /// 只由已核权的peer adapter调用；相同ID在全库只能有一个不可变绑定。
  Future<OrdinaryAttachmentAsset> beginReceive(AttachmentDescriptor descriptor)=>_write(()async{
    final old=await _byId(descriptor.id);
    if(old!=null){
      if(!old.descriptor.same(descriptor))attachmentFail('attachment_binding_conflict');
      if(old.available){
        try{await _verify(old);return old;}on AttachmentException catch(e){
          if(e.code!='attachment_integrity'&&e.code!='attachment_unavailable')rethrow;
          // 只修复已绑定的缺件或摘要损坏；路径/索引/权限错误不能降级为普通缺件。
        }
      }
      if(old.status=='receiving')return old;
      final key=await _freshObject();await _file(key).create(exclusive:true);
      await _db.transaction((tx)async{
        await tx.insert('attachment_orphans',{'object_key':old._objectKey,'reason':'previous_${old.status}'},conflictAlgorithm:ConflictAlgorithm.ignore);
        await tx.update('attachments',{'object_key':key,'status':'receiving','received_size':0,'missing_reason':''},where:'id=?',whereArgs:[descriptor.id]);
      });return (await _byId(descriptor.id))!;
    }
    final key=await _freshObject();await _file(key).create(exclusive:true);await _insert(descriptor,key,'receiving',0);return (await _byId(descriptor.id))!;
  });
  Future<OrdinaryAttachmentAsset> receiveChunk(AttachmentDescriptor descriptor,{required int offset,required Uint8List bytes})=>_write(()async{
    final asset=await _required(descriptor.binding,descriptor.id);
    if(!asset.descriptor.same(descriptor))attachmentFail('attachment_binding_conflict');
    if(offset<0||bytes.isEmpty||bytes.length>chunkBytes||offset+bytes.length>descriptor.size)attachmentFail('invalid_attachment_chunk');
    final file=_file(asset._objectKey);await _regularOrAbsent(file);
    if(await FileSystemEntity.type(file.path,followLinks:false)!=FileSystemEntityType.file||await file.resolveSymbolicLinks()!=file.path)attachmentFail('attachment_unavailable');
    final length=await file.length();
    if(length<asset.offset||length>descriptor.size)attachmentFail('attachment_integrity');
    if(offset<asset.offset){
      if(offset+bytes.length>asset.offset||!await _sameBytes(file,offset,bytes))attachmentFail('attachment_offset_conflict');
      if(asset.available)await _verify(asset);return asset;
    }
    if(offset!=asset.offset||asset.status!='receiving')attachmentFail('attachment_offset_conflict');
    // Crash after file flush and before SQLite offset: compare the unacknowledged tail, never overwrite it.
    final overlap=length-offset;
    if(overlap>bytes.length||overlap>0&&!await _sameBytes(file,offset,Uint8List.sublistView(bytes,0,overlap)))attachmentFail('attachment_offset_conflict');
    if(overlap<bytes.length){final output=await file.open(mode:FileMode.writeOnlyAppend);try{await output.writeFrom(bytes,overlap);await output.flush();}finally{await output.close();}}
    final next=offset+bytes.length;
    if(next==descriptor.size){
      try{await _verify(OrdinaryAttachmentAsset._(descriptor,'ready',next,'',asset._objectKey));}
      catch(_){await _db.update('attachments',{'status':'corrupt','received_size':next,'missing_reason':'integrity_failed'},where:'id=?',whereArgs:[descriptor.id]);rethrow;}
    }
    await _db.update('attachments',{'status':next==descriptor.size?'ready':'receiving','received_size':next,'missing_reason':''},where:'id=?',whereArgs:[descriptor.id]);
    return (await _byId(descriptor.id))!;
  });
  static Future<bool> _sameBytes(File file,int offset,Uint8List bytes)async{
    final input=await file.open();try{await input.setPosition(offset);final old=await input.read(bytes.length);if(old.length!=bytes.length)return false;
      for(var i=0;i<bytes.length;i++){if(old[i]!=bytes[i])return false;}return true;
    }finally{await input.close();}
  }
  static bool _sameStat(FileStat a,FileStat b)=>a.type==b.type&&a.size==b.size&&a.modified==b.modified&&a.changed==b.changed;
  Future<FileStat> _verify(OrdinaryAttachmentAsset asset)async{
    await _safe();if(!asset.available)attachmentFail('attachment_unavailable');final file=_file(asset._objectKey);
    final type=await FileSystemEntity.type(file.path,followLinks:false);
    if(type==FileSystemEntityType.notFound)attachmentFail('attachment_unavailable');
    if(type!=FileSystemEntityType.file||await file.resolveSymbolicLinks()!=file.path)attachmentFail('unsafe_attachment_file');
    final stat=await file.stat();if(stat.size!=asset.descriptor.size)attachmentFail('attachment_integrity');
    if((await hashes.sha256.bind(file.openRead()).first).toString()!=asset.descriptor.sha256)attachmentFail('attachment_integrity');
    if(asset.descriptor.kind=='image'){validateAttachmentImage(await file.readAsBytes());}
    else{final input=await file.open();try{validateOrdinaryFileHeader(await input.read(64));}finally{await input.close();}}
    if(!_sameStat(stat,await file.stat()))attachmentFail('attachment_source_changed');return stat;
  }
  Future<File> verifiedFile(AttachmentBinding binding,String id)async{final asset=await _required(binding,id);await _verify(asset);return _file(asset._objectKey);}
  Future<Uint8List> read(AttachmentBinding binding,String id,{required int offset,int maxBytes=chunkBytes})async{
    final asset=await _required(binding,id);if(offset<0||offset>asset.descriptor.size||maxBytes<1||maxBytes>chunkBytes)attachmentFail('invalid_attachment_range');
    final snapshot=await _verify(asset),out=BytesBuilder(copy:false),count=(asset.descriptor.size-offset).clamp(0,maxBytes).toInt();
    await for(final bytes in _range(asset,snapshot,offset,count)){out.add(bytes);}return out.takeBytes();
  }
  Stream<List<int>> _range(OrdinaryAttachmentAsset asset,FileStat snapshot,int offset,int length)async*{
    final current=await _required(asset.descriptor.binding,asset.id);
    if(!current.available||current._objectKey!=asset._objectKey||!current.descriptor.same(asset.descriptor))attachmentFail('attachment_source_changed');
    await _verify(current);final file=_file(asset._objectKey);
    if(!_sameStat(snapshot,await file.stat()))attachmentFail('attachment_source_changed');
    final input=await file.open();var left=length;
    try{await input.setPosition(offset);while(left>0){final b=await input.read(left>65536?65536:left);if(b.isEmpty)attachmentFail('attachment_source_changed');left-=b.length;yield b;}}
    finally{await input.close();}
    if(!_sameStat(snapshot,await file.stat()))attachmentFail('attachment_source_changed');
  }
  /// 本机清理不创造业务墓碑；撤回/删除必须先由routes原子提交并使adapter拒绝继续传输。
  Future<void> deleteLocal(AttachmentBinding binding,String id)=>_write(()async{
    final asset=await get(binding,id);if(asset==null)return;final file=_file(asset._objectKey);await _regularOrAbsent(file);
    await _db.update('attachments',{'status':'missing','received_size':0,'missing_reason':'local_copy_removed'},where:'id=?',whereArgs:[id]);
    if(await FileSystemEntity.type(file.path,followLinks:false)==FileSystemEntityType.file)await file.delete();
  });
  /// 输出能力只有固定普通文件file种类；不接受BackupSource反向导入，不伪称回忆原件。
  Future<BackupSource> frozenBackupSource(AttachmentBinding binding,String id,{String? entryId})async{
    final asset=await _required(binding,id),backupId=entryId??id;
    if(!validBackupId(backupId))attachmentFail('invalid_attachment_backup_id');
    if(!asset.available)return _MissingAttachmentSource(backupId);
    try{final snapshot=await _verify(asset);return _FrozenAttachmentSource(this,asset,snapshot,backupId);}
    on AttachmentException catch(e){if(e.code=='attachment_integrity'||e.code=='attachment_unavailable')return _MissingAttachmentSource(backupId);rethrow;}
  }
  Future<void> close()=>_serial(_root.path,()async{if(_closed)return;await _safe();final lock=await _lock(_root);try{_closed=true;await _db.close();}finally{await _unlock(lock);}});
}
class _FrozenAttachmentSource extends BackupSource {
  _FrozenAttachmentSource(this.store,this.asset,this.snapshot,String id):entry=BackupEntry(id:id,kind:'file',size:asset.descriptor.size,sha256:asset.descriptor.sha256,sourceExact:false);
  final OrdinaryAttachmentStore store;final OrdinaryAttachmentAsset asset;final FileStat snapshot;
  @override final BackupEntry entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async{
    if(offset<0||length<0||offset+length>entry.size)attachmentFail('invalid_attachment_range');return store._range(asset,snapshot,offset,length);
  }
}
class _MissingAttachmentSource extends BackupSource {
  _MissingAttachmentSource(String id):entry=BackupEntry(id:id,kind:'file',size:0,sha256:'',sourceExact:false,missing:'source_unavailable');
  @override final BackupEntry entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>attachmentFail('attachment_unavailable');
}
