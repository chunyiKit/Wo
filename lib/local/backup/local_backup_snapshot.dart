import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashing;
import 'package:uuid/uuid.dart';
import '../local_store.dart';
import '../local_media_repository.dart';
import '../plugins/memory_routes.dart';
import '../sync/sync_policy.dart';
import '../sync/travel_sync_adapter.dart';
import '../sync/ordinary_attachment_sync.dart';
import '../transport/native_local.dart';
import 'backup_models.dart';
import 'mobile_backup_controller.dart';

class SqliteBackupPreferences implements BackupPreferencesStore {
  SqliteBackupPreferences(this.store,this.familyId);
  final LocalStore store;final String familyId;
  @override Future<Map<String,dynamic>?> read()async{
    final value=await store.privateValue('desktop-backup:$familyId');
    return value==null?null:Map<String,dynamic>.from(value as Map);
  }
  @override Future<void> write(Map<String,dynamic> value)=>store.setPrivate('desktop-backup:$familyId',value);
}

/// 只从当前有效成员可见的文档生成惰性备份；从不打包meta/device_refs/操作日志。
/// 记录全部受限加密，恢复后也不会据此自动授予旧成员或伴侣身份。
class LocalBackupSnapshots {
  LocalBackupSnapshots({required this.store,required this.media,required this.memories,
    required this.crypto,required this.schemas,this.travel,this.ordinary});
  final LocalStore store;final LocalMediaRepository media;final MemoryRoutes memories;
  final NativeCrypto crypto;final Map<String,Set<String>> schemas;final TravelSyncAdapter? travel;final OrdinaryAttachmentSyncAdapter? ordinary;
  Future<BackupSnapshot> create(String familyId)async{
    final member=await store.get(familyId,'/families/$familyId/members',store.deviceId);
    if(member==null||member['status']!='active'||member['family_id']!=familyId||member['user_id']!=store.deviceId)throw const BackupException('family_authorization_required');
    final visible=await memories.visibleSnapshot(familyId);
    final memoryIds=visible.map((row)=>row['id'] as String).toSet();
    final spaces=await memories.access.visibleSpaces(familyId);
    final docs=await store.db.query('documents',where:'deleted=0 AND space IN (${List.filled(spaces.length,'?').join(',')})',whereArgs:spaces,limit:20001);
    if(docs.length>20000)throw const BackupException('snapshot_document_limit');
    final selected=<Json>[],mediaRows=<({String space,Json row})>[],omitted=<String>{};
    for(final raw in docs){
      final scope=raw['space'] as String,collection=raw['collection'] as String,id=raw['id'] as String;
      final prefix='/families/$scope/';if(!collection.startsWith(prefix))throw const BackupException('snapshot_invalid_collection');
      final suffix=collection.substring(prefix.length),fields=Json.from(jsonDecode(raw['data'] as String) as Map);
      final isComment=RegExp(r'^plugins/memory/memories/[A-Za-z0-9_-]{1,100}/comments$').hasMatch(suffix);
      final allowed=isComment?LocalIncrementalStrategy.commentFields:schemas[suffix];
      if(allowed==null){omitted.add(suffix);continue;}
      final memory=suffix=='plugins/memory/memories';
      final descriptor=suffix=='plugins/memory/media';
      if(scope!=familyId&&!memory&&!descriptor&&!isComment)continue;
      if(memory&&!memoryIds.contains(id))continue;
      if((descriptor||isComment)&&!memoryIds.contains(fields['memory_id']))continue;
      // A visible ID in another scope cannot authorize an unbound duplicate document.
      if(memory||descriptor||isComment){
        final parentId=memory?id:fields['memory_id'] as String;
        final parent=await store.get(scope,'/families/$scope/plugins/memory/memories',parentId);
        if(parent==null||parent['family_id']!=familyId)continue;
        final expected=await memories.access.spaceFor(familyId,parent['visibility'] as String);
        if(expected!=scope||parent['visibility']=='private'&&parent['created_by']!=store.deviceId)continue;
      }
      if(fields.keys.any((key)=>!allowed.contains(key)))throw const BackupException('snapshot_unknown_fields');
      LocalIncrementalStrategy.validatePortableFields(familyId:familyId,suffix:suffix,id:id,fields:fields);
      selected.add({'space':scope,'collection':collection,'id':id,'fields':fields});
      if(descriptor)mediaRows.add((space:scope,row:{...fields,'id':id}));
    }
    selected.sort((a,b)=>'${a['space']}/${a['collection']}/${a['id']}'.compareTo('${b['space']}/${b['collection']}/${b['id']}'));
    final parent=Directory(await crypto.privateDirectory('backup-records'));
    final stage=await parent.createTemp('snapshot-');
    try{
      final records=File('${stage.path}/records.json');final sink=records.openWrite();
      var count=0;
      void write(String value){count+=utf8.encode(value).length;if(count>32*1024*1024)throw const BackupException('snapshot_record_limit');sink.write(value);}
      try{write('{"version":1,"family_id":${jsonEncode(familyId)},"records_applied":false,"documents":[');
        for(var i=0;i<selected.length;i++){if(i>0)write(',');write(jsonEncode(selected[i]));}write(']}');await sink.flush();
      }finally{await sink.close();}
      final sources=<BackupSource>[await _SnapshotFile.create('records_${const Uuid().v4()}','records',records,BackupPrivacy.restricted)];
      final used=<String>{};
      for(final bound in mediaRows){
        final row=bound.row,id=row['id'] as String;if(!used.add(id))throw const BackupException('snapshot_media_id_collision');
        final privacy=bound.space==familyId?BackupPrivacy.public:BackupPrivacy.restricted;
        final thumb=await media.thumbnailFile(id);
        if(thumb!=null&&await thumb.length()<=LocalMediaRepository.maxThumbnailBytes){
          final bytes=await thumb.readAsBytes();LocalMediaRepository.validateThumbnail(bytes);
          if(LocalMediaRepository.hash(bytes)==row['thumbnail_sha256']&&bytes.length==row['thumbnail_bytes']){
            // Freeze derived bytes independently of later thumbnail repair.
            final frozen=File('${stage.path}/thumb_$id.jpg');await frozen.writeAsBytes(bytes,flush:true);
            sources.add(await _SnapshotFile.create('thumb_$id','thumbnail',frozen,privacy));
          }else{sources.add(_MissingSource('thumb_$id','thumbnail',privacy));}
        }else{sources.add(_MissingSource('thumb_$id','thumbnail',privacy));}
        final ref=await store.deviceReference(id);
        if(ref!=null){final meta=Json.from(jsonDecode(ref['metadata'] as String) as Map);
          if(meta['scope']!=bound.space||meta['memory_id']!=row['memory_id'])throw const BackupException('snapshot_media_binding_conflict');}
        sources.add(await media.prepareBackupSource(id,privacy:privacy,kindIfMissing:row['kind'] as String));
      }
      if(travel!=null){sources.addAll(await travel!.backupSources(familyId));}
      if(ordinary!=null){sources.addAll(await ordinary!.backupSources(familyId));}
      return BackupSnapshot(sources:sources,omittedScopes:omitted,coverageNotes:[
        '仅备份当前本机身份可见的记录；记录始终加密，未导入旧身份与伴侣权限。',
        '原件仅在本机可读且原生确认保真时包含；其它设备原件、失效授权或离线云端文件会明确缺件。',
        '恢复当前仅生成校验后的新隔离目录与新媒体ID，尚未安全导入业务库。',
        '系统后台提醒与外部服务配置/密钥不包含在此备份。',
      ],release:()async{if(await stage.exists())await stage.delete(recursive:true);});
    }catch(_){if(await stage.exists())await stage.delete(recursive:true);rethrow;}
  }
}
class _SnapshotFile extends BackupSource {
  _SnapshotFile(this.entry,this.file,this.privacy);
  @override final BackupEntry entry;final File file;@override final BackupPrivacy privacy;
  static Future<_SnapshotFile> create(String id,String kind,File file,BackupPrivacy privacy)async=>_SnapshotFile(
    BackupEntry(id:id,kind:kind,size:await file.length(),sha256:(await hashing.sha256.bind(file.openRead()).first).toString(),sourceExact:false),file,privacy);
  @override Future<Stream<List<int>>> openRange(int offset,int length)async{
    if(offset<0||length<0||offset+length>entry.size)throw const BackupException('snapshot_invalid_range');return file.openRead(offset,offset+length);
  }
}
class _MissingSource extends BackupSource {
  _MissingSource(String id,String kind,this.privacy):entry=BackupEntry(id:id,kind:kind,size:0,sha256:'',sourceExact:false,missing:'source_unavailable');
  @override final BackupEntry entry;@override final BackupPrivacy privacy;
  @override Future<Stream<List<int>>> openRange(int offset,int length)=>throw const BackupException('source_unavailable');
}
