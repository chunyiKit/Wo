import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashing;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../media/owned_media_store.dart';
import '../transport/native_local.dart';
import 'backup_models.dart';
import 'mobile_backup_controller.dart';
import 'portable_archive.dart';
import 'record_evidence.dart';

typedef RecoveryFieldValidator=void Function({required String familyId,required String suffix,required String id,required Map<String,dynamic> fields});

/// 独立只读资料库。它不是 LocalStore，不参与家庭、Routes、提醒或同步。
class RecoveryWorkspace {
  RecoveryWorkspace(Map<String,Object?> row):id=row['id'] as String,
    sourceFamilyId=row['source_family'] as String,ownerDeviceId=row['owner'] as String,
    documentCount=row['document_count'] as int,missingCount=row['missing_count'] as int,
    unverifiedCount=row['unverified_count'] as int,evidenceVersion=row['evidence_version'] as int;
  final String id,sourceFamilyId,ownerDeviceId;
  final int documentCount,missingCount,unverifiedCount,evidenceVersion;
  bool get normalImportAllowed=>false;
  bool get peerExportable=>false;
  bool get fullDeviceComplete=>false;
  bool get recordsApplied=>false;
}
class RecoveryDocument {
  RecoveryDocument({required this.space,required this.collection,required this.id,required Map<String,dynamic> fields,this.deleted=false})
    :fields=Map.unmodifiable(fields);
  final String space,collection,id;final Map<String,dynamic> fields;final bool deleted;
}
class RecoveryPreview {
  RecoveryPreview(this.fingerprint,this.sourceFamilyId,this.documents,this.missingCount,this.unverifiedCount,this.evidenceVersion);
  final String fingerprint,sourceFamilyId;final List<RecoveryDocument> documents;
  final int missingCount,unverifiedCount,evidenceVersion;
  int get documentCount=>documents.length;
}

class RecoveryWorkspaceStore {
  RecoveryWorkspaceStore._(this._db,this.media,this.schemas,this.commentFields,this.validateFields);
  final Database _db;final OwnedMediaStore media;final Map<String,Set<String>> schemas;
  final Set<String> commentFields;final RecoveryFieldValidator validateFields;
  Future<void> _queue=Future<void>.value();
  static Future<RecoveryWorkspaceStore> openNative({required NativeCrypto crypto,required Map<String,Set<String>> schemas,required Set<String> commentFields,required RecoveryFieldValidator validateFields,DatabaseFactory? factory})async{
    final root=Directory(await crypto.privateDirectory('recovery-library-v1'));
    if(await FileSystemEntity.type(root.path,followLinks:false)!=FileSystemEntityType.directory)throw const BackupException('untrusted_recovery_path');
    final path='${root.path}/library.sqlite';
    final type=await FileSystemEntity.type(path,followLinks:false);
    if(type!=FileSystemEntityType.notFound&&type!=FileSystemEntityType.file)throw const BackupException('untrusted_recovery_path');
    for(final suffix in ['-wal','-shm','-journal']){final t=await FileSystemEntity.type('$path$suffix',followLinks:false);if(t!=FileSystemEntityType.notFound&&t!=FileSystemEntityType.file)throw const BackupException('untrusted_recovery_path');}
    final db=await (factory??databaseFactory).openDatabase(path,options:OpenDatabaseOptions(version:1,singleInstance:false,onCreate:(db,_)async{
      await db.execute('CREATE TABLE workspaces(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, source_family TEXT NOT NULL, owner TEXT NOT NULL, state TEXT NOT NULL, document_count INTEGER NOT NULL, missing_count INTEGER NOT NULL, unverified_count INTEGER NOT NULL, evidence_version INTEGER NOT NULL)');
      await db.execute('CREATE TABLE history(workspace TEXT NOT NULL, ordinal INTEGER NOT NULL, space TEXT NOT NULL, collection TEXT NOT NULL, record_id TEXT NOT NULL, fields TEXT NOT NULL, deleted INTEGER NOT NULL, PRIMARY KEY(workspace,ordinal), UNIQUE(workspace,space,collection,record_id))');
      await db.execute('CREATE TABLE backup_settings(workspace TEXT PRIMARY KEY, value TEXT NOT NULL)');
    }));
    try{return RecoveryWorkspaceStore._(db,await OwnedMediaStore.open(crypto:crypto,factory:factory),schemas,commentFields,validateFields);}catch(_){await db.close();rethrow;}
  }
  Future<void> close()async{await _queue;await media.close();await _db.close();}
  String _fingerprint(PortableRestore restore)=>hashing.sha256.convert(utf8.encode(jsonEncode(restore.manifest.toJson()))).toString();
  Future<RecoveryPreview> preview(PortableRestore restore)async{
    // Only objects produced by authenticated archive verification reach this API.
    // Rehash records at use time; media import independently rehashes every original.
    final entries=restore.manifest.entries.where((e)=>e.kind=='records').toList();
    if(entries.length>1)throw const BackupException('ambiguous_recovery_records');
    final docs=<RecoveryDocument>[];var version=0;
    if(entries.isNotEmpty&&entries.single.missingReason.isEmpty){
      final entry=entries.single,source=restore.files[entries.single.id];
      if(source==null||entry.size>32*1024*1024||source.entry.toJson().toString()!=entry.toJson().toString())throw const BackupException('recovery_records_mismatch');
      if(await FileSystemEntity.type(source.file.path,followLinks:false)!=FileSystemEntityType.file||source.file.parent.absolute.path!=restore.directory.absolute.path)throw const BackupException('recovery_records_path');
      final actualSize=await source.file.length();
      if(actualSize!=entry.size||actualSize>32*1024*1024)throw const BackupException('recovery_records_integrity');
      final collected=BytesBuilder(copy:false);var count=0;
      await for(final bytes in source.file.openRead()){
        count+=bytes.length;if(count>entry.size||count>32*1024*1024)throw const BackupException('recovery_record_limit');collected.add(bytes);
      }
      final raw=collected.takeBytes();
      if(raw.length!=entry.size||hashing.sha256.convert(raw).toString()!=entry.sha256)throw const BackupException('recovery_records_integrity');
      final object=backupObject(decodeBackupJson(utf8.decode(raw,allowMalformed:false)));
      version=object['version'] is int?object['version'] as int:0;
      if(version==2){
        final expanded=<String,Set<String>>{...schemas};
        for(final item in object['documents'] is List?object['documents'] as List:const []){
          if(item is Map&&item['collection'] is String){final path=item['collection'] as String;
            final match=RegExp(r'^/families/[^/]+/(plugins/memory/memories/[A-Za-z0-9_-]{1,100}/comments)$').firstMatch(path);
            if(match!=null)expanded[match.group(1)!]=commentFields;
          }
        }
        final evidence=RecordEvidence.decode(raw,expectedFamily:restore.sourceFamilyId,schema:RecordEvidenceSchema(fields:expanded,
          validateContent:(space,suffix,id,fields,kind){
            if(kind!=EvidenceContentKind.deletion)validateFields(familyId:restore.sourceFamilyId,suffix:suffix,id:id,fields:fields);
          }));
        docs.addAll(evidence.documents.map((d)=>RecoveryDocument(space:d.space,collection:d.collection,id:d.id,fields:d.data,deleted:d.deleted)));
        return RecoveryPreview(_fingerprint(restore),restore.sourceFamilyId,List.unmodifiable(docs),restore.missing.length,restore.unverifiedOriginals.length,version);
      }
      if(version!=1)throw const BackupException('unsupported_recovery_evidence');
      if(object.length!=4||object['family_id']!=restore.sourceFamilyId||object['records_applied']!=false||object['documents'] is! List)throw const BackupException('recovery_records_schema');
      final rows=object['documents'] as List;if(rows.length>20000)throw const BackupException('recovery_record_limit');
      final seen=<String>{};
      for(final row in rows){
        final r=backupObject(row);
        if(r.length!=4||r['space'] is! String||r['collection'] is! String||r['id'] is! String||r['fields'] is! Map)throw const BackupException('recovery_records_schema');
        final space=r['space'] as String,collection=r['collection'] as String,id=r['id'] as String;
        if(!validBackupId(space)||!validBackupId(id)||!collection.startsWith('/families/$space/'))throw const BackupException('recovery_records_schema');
        final suffix=collection.substring('/families/$space/'.length);
        final allowed=RegExp(r'^plugins/memory/memories/[A-Za-z0-9_-]{1,100}/comments$').hasMatch(suffix)?commentFields:schemas[suffix];
        final fields=backupObject(r['fields']);
        if(allowed==null||fields.keys.any((key)=>!allowed.contains(key)))throw const BackupException('recovery_unknown_schema');
        validateFields(familyId:restore.sourceFamilyId,suffix:suffix,id:id,fields:fields);
        if(!seen.add('$space\n$collection\n$id'))throw const BackupException('recovery_duplicate_document');
        docs.add(RecoveryDocument(space:space,collection:collection,id:id,fields:fields));
      }
    }
    return RecoveryPreview(_fingerprint(restore),restore.sourceFamilyId,List.unmodifiable(docs),restore.missing.length,restore.unverifiedOriginals.length,version);
  }
  Future<RecoveryWorkspace> importVerified(PortableRestore restore,{required bool confirmed,required String expectedFingerprint}){
    if(!confirmed)return Future.error(const BackupException('recovery_confirmation_required'));
    final task=_queue.then((_)async{
      final plan=await preview(restore);
      if(plan.fingerprint!=expectedFingerprint)throw const BackupException('recovery_confirmation_changed');
      final rows=await _db.query('workspaces',where:'fingerprint=?',whereArgs:[plan.fingerprint]);
      if(rows.isNotEmpty&&rows.single['state']=='ready'){
        final workspace=RecoveryWorkspace(rows.single);
        for(final asset in await media.list(workspace.id)){if(asset.available)await media.verifiedFile(workspace.id,asset.id);}
        return workspace;
      }
      final id=rows.isEmpty?const Uuid().v4():rows.single['id'] as String;
      if(rows.isEmpty)await _db.insert('workspaces',{'id':id,'fingerprint':plan.fingerprint,'source_family':plan.sourceFamilyId,
        'owner':const Uuid().v4(),'state':'importing','document_count':plan.documentCount,'missing_count':plan.missingCount,
        'unverified_count':plan.unverifiedCount,'evidence_version':plan.evidenceVersion});
      // A failed/terminated import is invisible. The same fingerprint resumes owned objects;
      // existing user data and previously published libraries are never replaced.
      final thumbs=<String,String>{};
      for(final entry in restore.manifest.entries.where((e)=>e.kind=='thumbnail')){
        final asset=await media.importPortable(workspaceId:id,importKey:entry.id,restore:restore,entryId:entry.id);
        if(asset.available)thumbs[entry.id]=asset.id;
      }
      for(final entry in restore.manifest.entries.where((e)=>e.kind!='thumbnail')){
        await media.importPortable(workspaceId:id,importKey:entry.id,restore:restore,entryId:entry.id,
          thumbnailId:thumbs['thumb_${entry.id}']);
      }
      await _db.transaction((tx)async{
        await tx.delete('history',where:'workspace=?',whereArgs:[id]);
        for(var i=0;i<plan.documents.length;i++){
          final d=plan.documents[i];await tx.insert('history',{'workspace':id,'ordinal':i,'space':d.space,'collection':d.collection,'record_id':d.id,'fields':jsonEncode(d.fields),'deleted':d.deleted?1:0});
        }
        await tx.update('workspaces',{'state':'ready'},where:'id=? AND state=?',whereArgs:[id,'importing']);
      });
      return get(id);
    });
    _queue=task.then<void>((_) {},onError:(Object _,StackTrace __){});return task;
  }
  Future<List<RecoveryWorkspace>> list()async=>[for(final row in await _db.query('workspaces',where:'state=?',whereArgs:['ready'],orderBy:'rowid DESC'))RecoveryWorkspace(row)];
  Future<RecoveryWorkspace> get(String id)async{
    final rows=await _db.query('workspaces',where:'id=? AND state=?',whereArgs:[id,'ready']);
    if(rows.length!=1)throw const BackupException('recovery_workspace_unavailable');return RecoveryWorkspace(rows.single);
  }
  Future<List<RecoveryDocument>> documents(String id)async{
    await get(id);return [for(final r in await _db.query('history',where:'workspace=?',whereArgs:[id],orderBy:'ordinal'))
      RecoveryDocument(space:r['space'] as String,collection:r['collection'] as String,id:r['record_id'] as String,
        fields:backupObject(jsonDecode(r['fields'] as String)),deleted:r['deleted']==1)];
  }
  Future<List<OwnedMediaAsset>> assets(String id)async{await get(id);return media.list(id);}
  BackupPreferencesStore preferences(String id)=>_RecoveryPreferences(this,id);
  Future<BackupSnapshot> snapshot(String id)async{
    await get(id);final sources=<BackupSource>[];
    for(final asset in await assets(id)){sources.add(await media.prepareBackupSource(id,asset.id));}
    return BackupSnapshot(sources:sources,coverageNotes:const ['私有恢复资料库原字节再备份；不代表正常业务恢复。'],
      omittedScopes:const ['成员授权与撤权证明未重建','记录未应用到业务数据库','本机设置、密钥与原身份不在归档内','此入口不包含外层公开归档文件；只含持钥验证的内部条目']);
  }
}
class _RecoveryPreferences implements BackupPreferencesStore {
  _RecoveryPreferences(this.store,this.id);final RecoveryWorkspaceStore store;final String id;
  @override Future<Map<String,dynamic>?> read()async{await store.get(id);final rows=await store._db.query('backup_settings',where:'workspace=?',whereArgs:[id]);return rows.isEmpty?null:backupObject(jsonDecode(rows.single['value'] as String));}
  @override Future<void> write(Map<String,dynamic> value)async{await store.get(id);await store._db.insert('backup_settings',{'workspace':id,'value':jsonEncode(value)},conflictAlgorithm:ConflictAlgorithm.replace);}
}
