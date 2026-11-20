import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/api_client.dart';
import 'local_api.dart';
import 'local_privacy.dart';
import 'local_store.dart';
import 'local_media_repository.dart';
import 'plugins/memory_routes.dart';
import 'plugins/movie_chore_anniversary.dart';
import 'plugins/stock_accounting.dart';
import 'plugins/calendar_routes.dart';
import 'plugins/chat_routes.dart';
import 'plugins/plant_routes.dart';
import 'plugins/retirement_subscription.dart';
import 'plugins/pet_routes.dart';
import 'plugins/travel_routes.dart';
import 'local_service_settings.dart';
import 'sync/travel_sync_adapter.dart';
import 'sync/peer_registry.dart';
import 'sync/sync_policy.dart';
import 'sync/sync_coordinator.dart';
import 'transport/native_local.dart';
import 'backup/mobile_backup_controller.dart';
import 'backup/local_backup_snapshot.dart';
import 'backup/backup_models.dart';
import 'backup/recovery_workspace.dart';

class LocalRuntime {
  LocalRuntime._(this.store,this.api,this.crypto,this.registry,this.media,this.memories,this.services,this.plants,this.travels,this.travelSync);
  final LocalStore store;final LocalApi api;final NativeCrypto crypto;
  final PeerRegistry registry;final LocalMediaRepository media;final MemoryRoutes memories;
  final LocalServiceSettings services;final PlantRoutes plants;final TravelRoutes travels;final TravelSyncAdapter travelSync;
  final ValueNotifier<int> changes=ValueNotifier<int>(0);
  late final LocalSyncCoordinator sync;
  final _backupControllers=<String,Future<MobileBackupController>>{};
  Map<String,Set<String>> get syncSchemas{
    final result=<String,Set<String>>{};
    for(final schema in [LocalIncrementalStrategy.baseSchemas,MovieChoreAnniversaryRoutes.syncFields,
      StockAccountingRoutes.syncFields,CalendarRoutes.syncFields,ChatRoutes.syncFields,PlantRoutes.syncFields,RetirementSubscriptionRoutes.syncFields,PetRoutes.syncFields,TravelRoutes.syncFields]){
      for(final entry in schema.entries){result[entry.key]={...?result[entry.key],...entry.value};}
    }
    return Map.unmodifiable(result);
  }
  Future<MobileBackupController> get backupController {
    final fid=api.familyId;if(fid==null)throw const BackupException('family_authorization_required');
    return _backupControllers.putIfAbsent(fid,()async{
      final controller=MobileBackupController.native(familyId:fid,deviceId:store.deviceId,
        preferences:SqliteBackupPreferences(store,fid),snapshotProvider:()=>LocalBackupSnapshots(
          store:store,media:media,memories:memories,crypto:crypto,schemas:syncSchemas,travel:travelSync).create(fid));
      try{await controller.load();return controller;}catch(_){_backupControllers.remove(fid);rethrow;}
    });
  }
  Future<RecoveryWorkspaceStore>? _recoveryLibrary;
  Future<RecoveryWorkspaceStore> get recoveryLibrary=>_recoveryLibrary??=RecoveryWorkspaceStore.openNative(crypto:crypto,schemas:syncSchemas,commentFields:LocalIncrementalStrategy.commentFields,validateFields:LocalIncrementalStrategy.validatePortableFields);
  final _recoveryBackupControllers=<String,Future<MobileBackupController>>{};
  Future<MobileBackupController> recoveryBackupController(String workspaceId)=>_recoveryBackupControllers.putIfAbsent(workspaceId,()async{
    final library=await recoveryLibrary,workspace=await library.get(workspaceId);
    // Explicit fresh pairing is required; no old phone token/identity is imported.
    final controller=MobileBackupController.native(familyId:workspace.sourceFamilyId,deviceId:workspace.ownerDeviceId,
      preferences:library.preferences(workspaceId),snapshotProvider:()=>library.snapshot(workspaceId));
    try{await controller.load();return controller;}catch(_){_recoveryBackupControllers.remove(workspaceId);rethrow;}
  });
  static LocalRuntime? instance;
  static Future<LocalRuntime>? _opening;
  static Future<LocalRuntime> initialize() => _opening ??= _open();
  void changed(){changes.value++;}
  Future<void> _merged()async{await api.initialize();changed();}
  Future<void> foreground(bool active)async{
    try{
    if(active){
      await sync.start();
      var added=0;
      for(final fid in await api.families){
        try{added+=await MovieChoreAnniversaryRoutes(store).requestDueAnniversaryReminders(fid);added+=await CalendarRoutes(store).requestDueReminders(fid);added+=await PlantRoutes(store).requestDueReminders(fid);added+=await RetirementSubscriptionRoutes(store).processDue(fid);added+=await PetRoutes(store).requestDueReminders(fid);}catch(_){/*提醒失败不阻断本地记录*/}
      }
      if(added>0)changed();
    }else{await sync.stop();}
    }catch(_){/*辅助任务不能造成未处理异步异常；资料读取错误由页面本地读取展示。*/}
  }
  static Future<LocalRuntime> _open() async {
    await LocalPrivacy.prepare();
    final store=await LocalStore.open();
    try {
      final crypto=NativeCrypto();final registry=PeerRegistry(store,crypto);
      final media=await LocalMediaRepository.open(store);
      final memories=MemoryRoutes(store,media:media,access:LocalMemoryAccess(store));
      final services=LocalServiceSettings(store:store,crypto:crypto);
      final plants=PlantRoutes(store,currentWeather:()=>services.weatherClient().current());
      final travels=TravelRoutes(store,media:media,memories:memories,imageClient:services.imageClient());
      final travelSync=TravelSyncAdapter(travels);
      LocalRuntime? runtime;
      final api=LocalApi(store,memories:memories,catalogue:services.movieClient(),travels:travels,onMutated:()=>runtime?.changed());await api.initialize();
      for(final fid in await api.families){await travels.recoverInterrupted(fid);}
      final ready=LocalRuntime._(store,api,crypto,registry,media,memories,services,plants,travels,travelSync);
      runtime=ready;
      ready.sync=LocalSyncCoordinator(store:store,registry:registry,crypto:crypto,discovery:NativeDiscovery(),
        strategy:LocalIncrementalStrategy(store,registry,media,additionalSchemas:ready.syncSchemas,travel:travelSync),
        onChanged:ready._merged);
      ApiClient.localBackend=api;
      return instance=ready;
    } catch (_) {await store.close();_opening=null;rethrow;}
  }
}
