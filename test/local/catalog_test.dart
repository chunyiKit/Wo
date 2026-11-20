import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/models.dart';
import 'package:wo/local/plugin_catalog.dart';

void main() {
  test('本机目录可由现有 Plugin 模型完整读取，且不发布未完成相册', () {
    final plugins = localPluginCatalog.map(Plugin.fromJson).toList();
    expect(plugins.map((p) => p.id).toSet(), {
      'accounting',
      'anniversary',
      'calendar',
      'chat',
      'chore',
      'expiry',
      'memory',
      'movie',
      'pet',
      'plant',
      'recipe',
      'retirement',
      'stock',
      'subscription',
      'travel',
    });
    expect(plugins, hasLength(15));
    for (final plugin in plugins) {
      expect(plugin.name, isNotEmpty);
      expect(plugin.descriptionShort, isNotEmpty);
      expect(plugin.descriptionLong, isNotEmpty);
      expect(plugin.emoji, isNotEmpty);
      expect(plugin.version, isNotEmpty);
      expect(plugin.publisher, isNotEmpty);
      expect(plugin.rating, 0);
      expect(plugin.installCount, 0);
    }
    expect(localUnpublishedPluginCatalog.single['id'], 'photo');
    expect(localUnpublishedPluginCatalog.single['published'], false);
  });

  test('目录可嵌入现有 InstalledPlugin，保留卡片布局、权限和多实例契约', () {
    for (final snapshot in localPluginCatalog) {
      final id = snapshot['id'] as String;
      final defaultLayout = snapshot['default_layout'] as Map<String, dynamic>;
      final installed = InstalledPlugin.fromJson({
        'id': 'installation-$id',
        'family_id': 'local-family',
        'plugin_id': id,
        'plugin': snapshot,
        'enabled': true,
        'layout': {'col': 0, 'row': 0, ...defaultLayout},
        'config': <String, dynamic>{},
        'preview': {
          'primary': snapshot['name'],
          'color_token': snapshot['color_token'],
        },
      });
      expect(installed.plugin.id, installed.pluginId);
      expect(installed.familyId, 'local-family');
      expect(installed.layout.cw, id == 'travel' ? 4 : 2);
      expect(installed.layout.ch, 2);
      expect(installed.plugin.multiInstance, id == 'anniversary');
      expect(installed.preview.primary, installed.plugin.name);
      expect(installed.preview.colorToken, installed.plugin.colorToken);
      expect(
        installed.plugin.permissions.map((p) => p.code).toSet().length,
        installed.plugin.permissions.length,
      );
    }
  });
}
