import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../transport/native_local.dart';
import 'backup_models.dart';
import 'backup_transport.dart';
import 'mobile_backup_client.dart';
import 'portable_archive.dart';
import 'quarantine_store.dart';
import 'restricted_backup.dart';

abstract interface class BackupPreferencesStore {
  Future<Map<String,dynamic>?> read();
  Future<void> write(Map<String,dynamic> value);
}

/// 运行时负责授权白名单、移除本机句柄/凭据，并冻结所有来源直到 release。
/// records 是惰性导出，不是数据库文件。不可包含其它成员未授权的私密资料。
class BackupSnapshot {
  BackupSnapshot({required Iterable<BackupSource> sources,Iterable<String> coverageNotes=const [],
      Iterable<String> omittedScopes=const [],this.release})
    :sources=List.unmodifiable(sources),coverageNotes=List.unmodifiable(coverageNotes),omittedScopes=List.unmodifiable(omittedScopes);
  final List<BackupSource> sources;
  final List<String> coverageNotes,omittedScopes;
  final Future<void> Function()? release;
}
typedef BackupTransportFactory=Future<BackupTransport> Function(Uri origin,String pin);
typedef BackupPrivateDirectory=Future<Directory> Function(String name);
enum MobileBackupPhase { idle,loading,pairing,preparing,uploading,downloading,verifying,completed,failed }

class _FrozenUpload {
  _FrozenUpload(this.manifest,this.sources,this.snapshot,this.sealed);
  final BackupManifest manifest;final List<BackupSource> sources;final BackupSnapshot snapshot;
  final SealedBackupSource? sealed;
}
class _Download {
  _Download(this.manifest,this.receiver);final BackupManifest manifest;final QuarantineStore receiver;bool verified=false;final materialized=<String,File>{};
}

/// 运行时长期持有，页面离开不dispose/重建；失败上传保留同一密文和原件快照。
/// 全局 reservation 延续到成功或显式放弃，禁止另一个job重新prepare覆盖快照。
class MobileBackupController extends ChangeNotifier {
  MobileBackupController({required this.familyId,required this.deviceId,required this.crypto,
      required this.preferences,required this.snapshotProvider,required this.privateDirectory,
      required this.transportFactory}) {
    if(!validBackupId(familyId)||!validBackupId(deviceId))throw const BackupException('invalid_local_backup_identity');
  }
  factory MobileBackupController.native({required String familyId,required String deviceId,
      required BackupPreferencesStore preferences,required Future<BackupSnapshot> Function() snapshotProvider}) {
    final crypto=NativeCrypto();
    return MobileBackupController(familyId:familyId,deviceId:deviceId,crypto:crypto,preferences:preferences,
      snapshotProvider:snapshotProvider,privateDirectory:(name)async=>Directory(await crypto.privateDirectory(name)),
      transportFactory:(origin,pin)=>PinnedBackupTransport.connect(origin:origin,pin:pin,crypto:crypto));
  }
  final String familyId,deviceId;
  final LocalCrypto crypto;final BackupPreferencesStore preferences;
  final Future<BackupSnapshot> Function() snapshotProvider;
  final BackupPrivateDirectory privateDirectory;final BackupTransportFactory transportFactory;
  static Future<void> _globalQueue=Future<void>.value();
  static MobileBackupController? _snapshotOwner;
  bool _busy=false,_loaded=false,_disposed=false;
  MobileBackupPhase _phase=MobileBackupPhase.idle;
  BackupException? _error;
  PairedComputer? _computer;
  String? _recoveryKeyRef,_revealedKeyRef;
  bool _keyAcknowledged=false,_cleanupWarning=false;
  _FrozenUpload? _upload;_Download? _download;String? _requestedDownload;
  List<BackupStatus> _backups=const [];
  BackupStatus? _lastUpload;PortableRestore? _lastRestore;
  List<String> _coverage=const [],_omissions=const [];
  Map<String,int> _sourceIssues=const {};
  bool get busy=>_busy;
  bool get loaded=>_loaded;
  MobileBackupPhase get phase=>_phase;
  BackupException? get error=>_error;
  PairedComputer? get computer=>_computer;
  bool get hasRecoveryKey=>_recoveryKeyRef!=null;
  bool get recoveryKeySavedAcknowledged=>_keyAcknowledged;
  bool get cleanupWarning=>_cleanupWarning;
  bool get hasPendingUpload=>_upload!=null;
  String? get pendingBackupId=>_upload?.manifest.backupId;
  bool get hasDownload=>_download!=null;
  bool get canRetryDownload=>_requestedDownload!=null;
  bool get downloadVerified=>_download?.verified??false;
  List<BackupStatus> get backups=>_backups;
  BackupStatus? get lastUpload=>_lastUpload;
  PortableRestore? get lastRestore=>_lastRestore;
  List<String> get coverageNotes=>_coverage;
  List<String> get omittedScopes=>_omissions;
  Map<String,int> get sourceIssuesByReason=>_sourceIssues;
  List<BackupEntry> get downloadedEntries=>_download?.manifest.entries??const [];
  List<BackupEntry> get downloadedSealedEntries=>List.unmodifiable(downloadedEntries.where((e)=>e.kind=='sealed'));
  bool get recordsApplied=>false;
  bool get fullDeviceComplete=>false;
  void _emit(){if(!_disposed)notifyListeners();}
  Future<T> _run<T>(MobileBackupPhase phase,Future<T> Function() action) {
    if(_busy||_disposed)return Future<T>.error(const BackupException('backup_job_busy'));
    _busy=true;_phase=phase;_error=null;_emit();
    final task=_globalQueue.then<T>((_)async{
      try{final value=await action();_phase=MobileBackupPhase.completed;return value;}
      catch(e){final safe=e is BackupException?e:const BackupException('backup_job_failed',retryable:true);_error=safe;_phase=MobileBackupPhase.failed;throw safe;}
      finally{_busy=false;_emit();}
    });
    _globalQueue=task.then<void>((_) {},onError:(Object _,StackTrace __){});return task;
  }
  Future<void> load()=>_run(MobileBackupPhase.loading,()async{
    if(_loaded)return;final raw=await preferences.read();
    if(raw!=null){
      if(raw['v']!=1||raw.keys.any((k)=>!{'v','computer','recovery_key_ref','key_saved_acknowledged'}.contains(k)))throw const BackupException('invalid_backup_preferences');
      final p=raw['computer'];PairedComputer? computer;
      if(p!=null){final j=backupObject(p);if(j.length!=6||j['origin'] is! String||j['pin'] is! String||j['family'] is! String||j['device']!=deviceId||j['token_ref'] is! String||j['v']!=1)throw const BackupException('stored_pair_identity_changed');
        computer=PairedComputer(origin:Uri.parse(j['origin'] as String),pin:j['pin'] as String,familyId:j['family'] as String,deviceId:deviceId,tokenRef:j['token_ref'] as String);}
      final key=raw['recovery_key_ref'];if(key!=null&&(key is! String||!RegExp(r'^wo\.backup\.recovery\.[a-f0-9]{32}$').hasMatch(key)))throw const BackupException('invalid_recovery_reference');
      if(raw['key_saved_acknowledged'] is! bool)throw const BackupException('invalid_backup_preferences');
      _computer=computer;_recoveryKeyRef=key as String?;_keyAcknowledged=key!=null&&raw['key_saved_acknowledged']==true;
    }
    _loaded=true;
  });
  Map<String,dynamic> _settings(PairedComputer? computer,String? key,bool ack)=>{'v':1,
    'computer':computer==null?null:{'v':1,'origin':computer.origin.toString(),'pin':computer.pin,'family':computer.familyId,'device':computer.deviceId,'token_ref':computer.tokenRef},
    'recovery_key_ref':key,'key_saved_acknowledged':ack};
  void _noFrozenUpload(){if(_upload!=null)throw const BackupException('finish_or_discard_pending_job');}
  void _noPending(){if(_upload!=null||_download!=null)throw const BackupException('finish_or_discard_pending_job');}
  PairedComputer _paired(){final p=_computer;if(p==null)throw const BackupException('computer_not_paired');return p;}
  Future<T> _withClient<T>(Future<T> Function(MobileBackupClient) action)async{
    final p=_paired(),transport=await transportFactory(_paired().origin,_paired().pin);
    try{return await action(MobileBackupClient(transport:transport,crypto:crypto,computer:p));}finally{transport.close();}
  }
  Future<void> pair({required Uri origin,required String pin,required String oneTimeCode,required String targetFamilyId})=>_run(MobileBackupPhase.pairing,()async{
    _noPending();validateComputerOrigin(origin,pin);if(!validBackupId(targetFamilyId)||!RegExp(r'^[a-f0-9]{64}$').hasMatch(oneTimeCode))throw const BackupException('invalid_pair_request');final transport=await transportFactory(origin,pin);
    try{
      final paired=await MobileBackupClient.pair(transport:transport,crypto:crypto,oneTimeCode:oneTimeCode,familyId:targetFamilyId,deviceId:deviceId);
      try{await preferences.write(_settings(paired,_recoveryKeyRef,_keyAcknowledged));}
      catch(_){await crypto.deleteSecret(paired.tokenRef);throw const BackupException('pair_saved_on_computer_but_local_save_failed');}
      _computer=paired;_backups=const [];
    }finally{transport.close();}
  });
  Future<void> forgetComputer()=>_run(MobileBackupPhase.loading,()async{
    _noPending();final old=_computer;if(old==null)return;await crypto.deleteSecret(old.tokenRef);_computer=null;_backups=const [];
    await preferences.write(_settings(null,_recoveryKeyRef,_keyAcknowledged));
  });
  Future<void> refreshBackups()=>_run(MobileBackupPhase.loading,()async{_backups=List.unmodifiable(await _withClient((c)=>c.list()));});
  Future<void> createRecoveryKey()=>_run(MobileBackupPhase.preparing,()async{
    _noFrozenUpload();final ref=await createBackupRecoveryKey(crypto);await _setKey(ref);
  });
  Future<void> importRecoveryKey(String hex)=>_run(MobileBackupPhase.preparing,()async{
    _noFrozenUpload();if(!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hex))throw const BackupException('invalid_recovery_key');
    final bytes=Uint8List.fromList(List.generate(32,(i)=>int.parse(hex.substring(i*2,i*2+2),radix:16)));
    try{await _setKey(await importBackupRecoveryKey(crypto,bytes));_revealedKeyRef=_recoveryKeyRef;}
    finally{bytes.fillRange(0,bytes.length,0);}
  });
  Future<void> _setKey(String ref)async{
    try{await preferences.write(_settings(_computer,ref,false));}
    catch(_){await crypto.deleteSecret(ref);rethrow;}
    _recoveryKeyRef=ref;_keyAcknowledged=false;_revealedKeyRef=null;
  }
  /// 显式用户操作才返回短时明文，不自动剪贴板/上传；UI关闭立即丢弃引用。
  Future<String> revealRecoveryKey()=>_run(MobileBackupPhase.verifying,()async{
    final ref=_recoveryKeyRef;if(ref==null)throw const BackupException('recovery_key_unavailable');final bytes=await crypto.getSecret(ref);
    if(bytes==null||bytes.length!=32)throw const BackupException('recovery_key_unavailable');
    try{_revealedKeyRef=ref;return backupHex(bytes);}finally{bytes.fillRange(0,bytes.length,0);}
  });
  Future<void> acknowledgeRecoveryKeySaved()=>_run(MobileBackupPhase.loading,()async{
    if(_recoveryKeyRef==null||_revealedKeyRef!=_recoveryKeyRef)throw const BackupException('recovery_key_must_be_revealed_or_imported');
    await preferences.write(_settings(_computer,_recoveryKeyRef,true));_keyAcknowledged=true;
  });
  Future<String> _id()async{final b=await crypto.random(16);if(b.length!=16)throw const BackupException('invalid_random');return backupHex(b);}
  Future<BackupStatus> startBackup({bool allowPublicMediaOnComputer=false})=>_run(MobileBackupPhase.preparing,()async{
    if(_upload!=null||_snapshotOwner!=null)throw const BackupException('frozen_backup_already_pending');
    if(_paired().familyId!=familyId)throw const BackupException('paired_family_is_restore_only');
    if(_recoveryKeyRef==null||!_keyAcknowledged)throw const BackupException('recovery_key_not_saved');
    _snapshotOwner=this;BackupSnapshot? snapshot;SealedBackupSource? sealed;
    try{
      snapshot=await snapshotProvider();_coverage=snapshot.coverageNotes;_omissions=snapshot.omittedScopes;
      final issues=<String,int>{};for(final s in snapshot.sources){final e=s.entry;final reason=e.missing.isNotEmpty?e.missing:((e.kind=='photo'||e.kind=='video')&&!e.sourceExact?'not_exact_original':'');if(reason.isNotEmpty)issues[reason]=(issues[reason]??0)+1;}_sourceIssues=Map.unmodifiable(issues);
      if(snapshot.sources.isEmpty)throw const BackupException('empty_backup_snapshot');
      final public=<BackupSource>[],restricted=<BackupSource>[];final seen=<String>{};
      for(final source in snapshot.sources){final e=source.entry;
        if(!seen.add(e.id.toLowerCase())||e.kind=='sealed')throw const BackupException('invalid_snapshot_source');
        if(allowPublicMediaOnComputer&&source.privacy==BackupPrivacy.public&&e.kind!='records')public.add(source);
        else restricted.add(_RestrictedSource(source));
      }
      final backupId=await _id();
      if(restricted.isNotEmpty){
        final entries=restricted.map((s){final e=s.entry;return PortableEntry(id:e.id,kind:e.kind,size:e.size,sha256:e.sha256,
          sourceExact:e.sourceExact,missingReason:_portableMissing(e.missing));}).toList(growable:false);
        final parent=await privateDirectory('backup-staging');
        sealed=await SealedBackupSource.create(id:await _id(),backupId:backupId,manifest:PortableManifest(familyId:familyId,entries:entries),
          sources:{for(final s in restricted)s.entry.id:s},recoveryKeyRef:_recoveryKeyRef!,privateParent:parent,crypto:crypto);
      }
      final sources=List<BackupSource>.unmodifiable([...public,if(sealed!=null)sealed]);
      final manifest=BackupManifest(familyId:familyId,backupId:backupId,entries:sources.map((s)=>s.entry));
      _upload=_FrozenUpload(manifest,sources,snapshot,sealed);
    }catch(_){if(sealed!=null){try{await sealed.dispose();}catch(_){_cleanupWarning=true;}}if(snapshot?.release!=null){try{await snapshot!.release!();}catch(_){_cleanupWarning=true;}}_snapshotOwner=null;rethrow;}
    return _uploadFrozen();
  });
  Future<BackupStatus> retryUpload()=>_run(MobileBackupPhase.uploading,()async{
    if(_upload==null||_snapshotOwner!=this)throw const BackupException('no_frozen_upload');return _uploadFrozen();
  });
  Future<BackupStatus> _uploadFrozen()async{
    final job=_upload!;_phase=MobileBackupPhase.uploading;_emit();
    final result=await _withClient((c)=>c.upload(job.manifest,job.sources));_lastUpload=result;
    await _releaseUpload();return result;
  }
  Future<void> _releaseUpload()async{
    final job=_upload;_upload=null;
    try{if(job?.sealed!=null)await job!.sealed!.dispose();}catch(_){_cleanupWarning=true;}
    try{if(job?.snapshot.release!=null)await job!.snapshot.release!();}catch(_){_cleanupWarning=true;}
    if(_snapshotOwner==this)_snapshotOwner=null;
  }
  Future<void> discardPendingUpload()=>_run(MobileBackupPhase.loading,_releaseUpload);
  Future<void> downloadBackup(String backupId)=>_run(MobileBackupPhase.downloading,()async{
    if(!validBackupId(backupId))throw const BackupException('invalid_backup_id');
    if(_download!=null&&_download!.manifest.backupId!=backupId)throw const BackupException('discard_previous_download_first');
    _requestedDownload=backupId;await _downloadIntoCache(backupId);
  });
  Future<void> retryDownload()=>_run(MobileBackupPhase.downloading,()async{
    final id=_requestedDownload;if(id==null)throw const BackupException('no_download_to_retry');await _downloadIntoCache(id);
  });
  Future<void> _downloadIntoCache(String id)async{
    await _withClient((client)async{
      if(_download==null){final manifest=await client.manifest(id);final receiver=await QuarantineStore.create(await privateDirectory('backup-staging'));
        _download=_Download(manifest,receiver);_lastRestore=null;}
      await client.fetch(_download!.manifest,_download!.receiver);_download!.verified=true;
    });
  }
  Future<PortableRestore> verifyRestrictedRestore(String entryId)=>_run(MobileBackupPhase.verifying,()async{
    final job=_download;if(job==null||!job.verified)throw const BackupException('download_not_verified');
    if(_lastRestore!=null)throw const BackupException('restore_already_verified_no_import');
    final matches=job.manifest.entries.where((e)=>e.id==entryId&&e.kind=='sealed');if(matches.length!=1)throw const BackupException('invalid_sealed_entry');
    final key=_recoveryKeyRef;if(key==null)throw const BackupException('recovery_key_unavailable');
    final entry=matches.single;final file=job.materialized[entry.id]??await job.receiver.materializeVerifiedFile(entry);job.materialized[entry.id]=file;
    final result=await restoreRestrictedBackup(entry:entry,ciphertext:file,expectedFamily:job.manifest.familyId,backupId:job.manifest.backupId,
      recoveryKeyRef:key,privateParent:await privateDirectory('backup-staging'),crypto:crypto);
    _lastRestore=result;return result;
  });
  Future<void> discardDownloadCache()=>_run(MobileBackupPhase.loading,()async{
    final job=_download;if(job!=null)await job.receiver.directory.delete(recursive:true);_download=null;_requestedDownload=null;
  });
  @override void dispose(){_disposed=true;super.dispose();}
}
class _RestrictedSource implements BackupSource {
  _RestrictedSource(this.source);final BackupSource source;
  @override BackupEntry get entry=>source.entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)=>source.openRange(offset,length);
}
String _portableMissing(String reason)=>switch(reason){''=>'', 'permission_denied'=>'permission_denied','cloud_only'=>'not_on_device','not_exact_original'=>'source_not_exact',_=>'source_unavailable'};
