import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wo/data/api_client.dart';
import 'package:wo/data/wo_api.dart';
import 'package:wo/data/wo_session.dart';
import 'package:wo/local/local_api.dart';
import 'package:wo/local/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  late Directory directory;late LocalStore store;late LocalApi local;late WoApi api;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'wo.token':'obsolete-remote-token'});
    directory=await Directory.systemTemp.createTemp('wo-rebuild-bootstrap-');
    store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/db.sqlite');
    local=LocalApi(store);await local.initialize();ApiClient.localBackend=local;api=WoApi(ApiClient());
  });
  tearDown(() async {ApiClient.localBackend=null;await store.close();await directory.delete(recursive:true);});
  test('无旧API和旧账号启动新家庭，所有首屏读写不创建HTTP客户端',() async {
    await HttpOverrides.runZoned(() async {
      final boot=await api.bootstrap();expect(boot.user.id,store.deviceId);
      expect(boot.currentFamily!.memberCount,1);expect(boot.currentFamily!.myRole,'owner');
      expect(boot.installedPlugins,isEmpty);expect(await api.plugins(),hasLength(15));
      final session=WoSession(api:api);await session.restore();await session.load();
      expect(session.isLoggedIn,true);expect(session.user!.id,store.deviceId);
      expect(api.authToken,isEmpty);expect(api.userId,isEmpty);session.dispose();
      await api.updateMe(displayName:'新的本机名字');expect((await api.me()).user.displayName,'新的本机名字');
    },createHttpClient:(_)=>throw StateError('启动不应联网'));
  });
  test('创建家庭/切换/修改与成员身份重启保留',() async {
    final first=local.familyId!;
    final created=await api.createFamily(name:'第二个家',emoji:'🏠');
    expect((await api.bootstrap()).families,hasLength(2));
    await api.updateFamily(created.id,name:'新名字',slogan:'一起');await api.switchFamily(first);
    await store.close();store=await LocalStore.open(factory:databaseFactoryFfi,path:'${directory.path}/db.sqlite');
    local=LocalApi(store);await local.initialize();ApiClient.localBackend=local;api=WoApi(ApiClient());
    expect(local.familyId,first);expect((await api.getFamily(created.id)).name,'新名字');
    expect((await api.members(created.id)).single.userId,store.deviceId);
  });
  test('目录安装去重、合法多实例与卸载只影响卡片，不冒称业务模块完成',() async {
    final fid=local.familyId!;
    final one=await api.installPlugin(fid,'recipe'),again=await api.installPlugin(fid,'recipe');
    expect(one.id,again.id);
    final dates=await api.installPlugin(fid,'anniversary'),dates2=await api.installPlugin(fid,'anniversary');
    expect(dates.id,isNot(dates2.id));expect(await api.installedPlugins(fid),hasLength(3));
    await api.updatePluginConfig(fid,one.id,{'test':'local'});
    await api.uninstallPlugin(fid,one.id);expect(await api.installedPlugins(fid),hasLength(2));
    await expectLater(api.installPlugin(fid,'photo'),throwsA(isA<ApiException>()));
  });
  test('布局验证重叠/漏项失败时不改已有卡片，合法替换原子完成',() async {
    final fid=local.familyId!;final one=await api.installPlugin(fid,'recipe');final two=await api.installPlugin(fid,'expiry');
    final before=await store.exportSince(fid,{});
    await expectLater(api.updateLayout(fid,[{'install_id':one.id,'col':0,'row':0,'cw':2,'ch':2},
      {'install_id':two.id,'col':0,'row':0,'cw':2,'ch':2}]),throwsA(isA<ApiException>()));
    expect(await store.exportSince(fid,{}),before);
    await api.updateLayout(fid,[{'install_id':one.id,'col':0,'row':0,'cw':2,'ch':2},
      {'install_id':two.id,'col':2,'row':0,'cw':2,'ch':2}]);
    expect((await api.installedPlugins(fid)).last.layout.col,2);
  });
  test('未接入的业务、旧云认证和跨家庭调用明确拒绝，不会自动回退云端',() async {
    await expectLater(local.request('POST','/auth/login',body:{'phone':'synthetic'}),throwsA(isA<ApiException>()));
    await expectLater(local.request('POST','/families/not-joined/plugins/movie/movies',body:{}),throwsA(isA<ApiException>()));
    await expectLater(local.request('GET','/families/${local.familyId}/plugins/stock/items'),throwsA(isA<ApiException>().having((e)=>e.code,'code','LOCAL_MODULE_PENDING')));
    await expectLater(local.request('POST','/families/${local.familyId}/background',files:[([1,2],'a.jpg')]),throwsA(isA<ApiException>()));
  });
}
