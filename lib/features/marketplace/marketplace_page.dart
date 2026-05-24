import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/async_view.dart';
import '../../widgets/wo_card.dart';

/// 插件市场首页：搜索 + 分类筛选 + 列表。数据来自 GET /plugins。
class MarketplacePage extends StatefulWidget {
  const MarketplacePage({super.key});

  @override
  State<MarketplacePage> createState() => _MarketplacePageState();
}

class _MarketplacePageState extends State<MarketplacePage> {
  // (展示名, 后端 category；null = 全部)
  static const _categories = <(String, String?)>[
    ('全部', null),
    ('生活', 'life'),
    ('财务', 'finance'),
    ('健康', 'health'),
    ('教育', 'education'),
    ('娱乐', 'entertainment'),
  ];

  int _selected = 0;
  String _query = '';
  String? _installingId;
  late Future<List<Plugin>> _future;

  @override
  void initState() {
    super.initState();
    _future = WoScope.api(context).plugins();
  }

  void _reload() => setState(() => _future = WoScope.api(context).plugins());

  Future<void> _install(Plugin p) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) {
      _toast('请先创建或加入一个家庭');
      return;
    }
    if (_installingId != null) return;
    setState(() => _installingId = p.id);
    try {
      await session.api.installPlugin(familyId, p.id);
      await session.refresh();
      if (mounted) _toast('已安装「${p.name}」');
    } catch (e) {
      if (mounted) _toast(_msg(e));
    } finally {
      if (mounted) setState(() => _installingId = null);
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final session = WoScope.of(context);
    final installedIds = {
      for (final ip
          in session.bootstrap?.installedPlugins ?? const <InstalledPlugin>[])
        ip.pluginId,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('插件市场')),
      body: SafeArea(
        top: false,
        child: AsyncView<List<Plugin>>(
          future: _future,
          onRetry: _reload,
          builder: (context, all) {
            final cat = _categories[_selected].$2;
            final q = _query.trim();
            final list = all.where((p) {
              final matchCat = cat == null || p.category == cat;
              final matchQ = q.isEmpty ||
                  p.name.contains(q) ||
                  p.descriptionShort.contains(q);
              return matchCat && matchQ;
            }).toList();

            return ListView(
              padding: const EdgeInsets.fromLTRB(
                WoTokens.space5,
                WoTokens.space2,
                WoTokens.space5,
                WoTokens.space8,
              ),
              children: [
                TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: '搜索插件',
                    prefixIcon: Icon(Icons.search, color: wo.fgDim),
                  ),
                ),
                const SizedBox(height: WoTokens.space4),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _categories.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(width: WoTokens.space2),
                    itemBuilder: (_, i) => ChoiceChip(
                      label: Text(_categories[i].$1),
                      selected: i == _selected,
                      onSelected: (_) => setState(() => _selected = i),
                    ),
                  ),
                ),
                const SizedBox(height: WoTokens.space5),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: WoTokens.space8),
                    child: Center(
                      child: Text(
                        '没有匹配的插件',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: wo.fgMid),
                      ),
                    ),
                  )
                else
                  for (final p in list)
                    _pluginRow(
                      context,
                      p,
                      installed: installedIds.contains(p.id),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _pluginRow(BuildContext context, Plugin p, {required bool installed}) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final installing = _installingId == p.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: WoTokens.space3),
      child: WoCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WoTokens.space4,
          vertical: WoTokens.space3,
        ),
        onTap: () =>
            context.push('${WoRoutes.home}/marketplace/plugin/${p.id}'),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: wo.bgTint,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(p.emoji, style: const TextStyle(fontSize: 22)),
            ),
            const SizedBox(width: WoTokens.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name, style: t.titleMedium),
                  Text(
                    '${_compact(p.installCount)} 家在用',
                    style: t.bodySmall?.copyWith(color: wo.fgMid),
                  ),
                ],
              ),
            ),
            if (installed)
              OutlinedButton(
                onPressed: null,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  foregroundColor: wo.fgDim,
                ),
                child: const Text('已安装'),
              )
            else
              FilledButton(
                onPressed: installing ? null : () => _install(p),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: installing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('安装'),
              ),
          ],
        ),
      ),
    );
  }
}

String _compact(int n) {
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}w';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

String _msg(Object e) => switch (e) {
      ApiException a => a.message,
      NetworkException a => a.message,
      _ => '操作失败',
    };
