import '../data/api_client.dart';
import 'local_api.dart';
import 'local_privacy.dart';
import 'local_store.dart';

class LocalRuntime {
  LocalRuntime._(this.store,this.api);
  final LocalStore store;
  final LocalApi api;
  static LocalRuntime? instance;
  static Future<LocalRuntime>? _opening;
  static Future<LocalRuntime> initialize() => _opening ??= _open();
  static Future<LocalRuntime> _open() async {
    await LocalPrivacy.prepare();
    final store=await LocalStore.open();
    try {
      final api=LocalApi(store);await api.initialize();
      final runtime=LocalRuntime._(store,api);
      ApiClient.localBackend=api;
      return instance=runtime;
    } catch (_) {await store.close();_opening=null;rethrow;}
  }
}
