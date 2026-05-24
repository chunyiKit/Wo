import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/async_view.dart';
import '../../widgets/wo_card.dart';

/// 插件详情：GET /plugins/{id}，底部粘性安装栏装到当前家庭。
class PluginDetailPage extends StatefulWidget {
  const PluginDetailPage({super.key, required this.pluginId});

  final String pluginId;

  @override
  State<PluginDetailPage> createState() => _PluginDetailPageState();
}

class _PluginDetailPageState extends State<PluginDetailPage> {
  late Future<Plugin> _future;
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    _future = WoScope.api(context).plugin(widget.pluginId);
  }

  bool get _installed {
    final session = WoScope.of(context);
    return (session.bootstrap?.installedPlugins ?? const <InstalledPlugin>[])
        .any((ip) => ip.pluginId == widget.pluginId);
  }

  Future<void> _install(Plugin p) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) {
      _toast('请先创建或加入一个家庭');
      return;
    }
    setState(() => _installing = true);
    try {
      await session.api.installPlugin(familyId, p.id);
      await session.refresh();
      if (mounted) _toast('已安装「${p.name}」');
    } catch (e) {
      if (mounted) _toast(_msg(e));
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final session = WoScope.of(context);
    final family = session.currentFamily;

    return Scaffold(
      appBar: AppBar(title: const Text('插件详情')),
      body: SafeArea(
        top: false,
        bottom: false,
        child: AsyncView<Plugin>(
          future: _future,
          onRetry: () => setState(
            () => _future = WoScope.api(context).plugin(widget.pluginId),
          ),
          builder: (context, p) {
            final size = p.sizeKb >= 1024
                ? '${(p.sizeKb / 1024).toStringAsFixed(1)} MB'
                : '${p.sizeKb} KB';
            return Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(WoTokens.space5),
                    children: [
                      WoCard(
                        color: wo.accentSoft,
                        padding: const EdgeInsets.all(WoTokens.space6),
                        child: Row(
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: wo.bgElev,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                p.emoji,
                                style: const TextStyle(fontSize: 32),
                              ),
                            ),
                            const SizedBox(width: WoTokens.space4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p.name, style: t.titleLarge),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${p.rating.toStringAsFixed(1)} ★ · '
                                    '${_compact(p.installCount)} 家在用 · $size',
                                    style:
                                        t.bodySmall?.copyWith(color: wo.fgMid),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: WoTokens.space5),
                      Text('简介', style: t.titleMedium),
                      const SizedBox(height: WoTokens.space2),
                      Text(
                        p.descriptionLong.isEmpty
                            ? p.descriptionShort
                            : p.descriptionLong,
                        style: t.bodyLarge,
                      ),
                      if (p.permissions.isNotEmpty) ...[
                        const SizedBox(height: WoTokens.space5),
                        Text('申请权限', style: t.titleMedium),
                        const SizedBox(height: WoTokens.space2),
                        for (final perm in p.permissions)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text('· ${perm.label}', style: t.bodyLarge),
                          ),
                      ],
                      const SizedBox(height: WoTokens.space5),
                      Text(
                        '版本 ${p.version} · ${p.publisher}',
                        style: t.bodySmall?.copyWith(color: wo.fgDim),
                      ),
                    ],
                  ),
                ),
                _installBar(context, p, family),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _installBar(BuildContext context, Plugin p, Family? family) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final installed = _installed;
    return Container(
      decoration: BoxDecoration(
        color: wo.bg,
        border: Border(top: BorderSide(color: wo.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(WoTokens.space4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '装到这个家',
                      style: t.bodySmall?.copyWith(color: wo.fgMid),
                    ),
                    Text(
                      family == null
                          ? '还没有家庭'
                          : '${family.emoji} ${family.name}',
                      style: t.titleMedium,
                    ),
                  ],
                ),
              ),
              FilledButton(
                onPressed:
                    (installed || _installing) ? null : () => _install(p),
                child: _installing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(installed ? '已安装' : '安装'),
              ),
            ],
          ),
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
