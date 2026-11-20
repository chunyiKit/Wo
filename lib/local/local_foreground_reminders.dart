import 'local_store.dart';
import 'plugins/movie_chore_anniversary.dart';
import 'plugins/calendar_routes.dart';
import 'plugins/plant_routes.dart';
import 'plugins/retirement_subscription.dart';
import 'plugins/pet_routes.dart';
import 'plugins/recipe_expiry.dart';

typedef DueReminderProcessor = Future<int> Function(String familyId);

/// 仅在前台补算已有插件规则；不投递系统通知，不改账期或完成规则。
class LocalForegroundReminders {
  LocalForegroundReminders(this.store, {DateTime Function()? now,
    Map<String, DueReminderProcessor>? processors}) : _processors = processors ?? {
      'anniversary': MovieChoreAnniversaryRoutes(store, now: now).requestDueAnniversaryReminders,
      'calendar': CalendarRoutes(store, now: now).requestDueReminders,
      'plant': PlantRoutes(store, now: now).requestDueReminders,
      'finance': RetirementSubscriptionRoutes(store, now: now).processDue,
      'pet': PetRoutes(store, now: now).requestDueReminders,
      'expiry': RecipeExpiryRoutes(store, now: now).requestDueExpiryReminders,
    };
  final LocalStore store;
  final Map<String, DueReminderProcessor> _processors;
  static const _plugins = <String, Set<String>>{
    'anniversary': {'anniversary'}, 'calendar': {'calendar'}, 'plant': {'plant'},
    'finance': {'retirement', 'subscription'}, 'pet': {'pet'}, 'expiry': {'expiry'},
  };
  Future<int> _revision() async => (await store.db.rawQuery(
    'SELECT COALESCE(MAX(revision),0) AS revision FROM changes')).single['revision'] as int;

  /// 返回实际提交的文档是否改变，包含处理器提交部分记录后才抛错的情况。
  Future<bool> run(Iterable<String> families, {bool Function()? isActive,bool includeFinance=true}) async {
    final before = await _revision();
    for (final fid in families) {
      for (final entry in _plugins.entries) {
        if(entry.key=='finance'&&!includeFinance)continue;
        if (isActive != null && !isActive()) return await _revision() != before;
        try {
          // 每个处理器前重新读取开关；删除/禁用卡片不能继续推进本地到期状态。
          final installed = await store.list(fid, '/families/$fid/installed');
          if (!installed.any((row) => row['enabled'] == true && entry.value.contains(row['plugin_id']))) continue;
          final process = _processors[entry.key];
          if (process != null) await process(fid);
        } catch (_) {
          // 一个插件的非法日期、冲突或存储错误不能阻断其它插件补算。
        }
      }
    }
    return await _revision() != before;
  }
}
