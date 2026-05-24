import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/color_token.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';
import '../../widgets/wo_widget_grid.dart';

/// 家庭首页（Direction A · 温润日常 + 异形 Widget 网格）。
///
/// 卡片来自后端 `/me/bootstrap` 的 installed_plugins（含布局 + 实时 preview）。
/// 长按任意卡片进入编辑态，可移除（调用卸载接口）。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _editing = false;

  /// 拖拽重排时的本地顺序。为空表示直接用后端顺序；非空且与后端 id 集合一致时
  /// 优先使用它（落点后立刻反映，不等服务端往返）。持久化成功 / 失败后清空，
  /// 重新以后端为准。
  List<InstalledPlugin>? _ordered;

  /// 计算「当前应展示的顺序」：本地重排优先，但一旦后端插件集合发生变化
  /// （装/卸插件、切家庭）就回退到后端，避免本地顺序失真。
  List<InstalledPlugin> _effectiveOrder(List<InstalledPlugin> fromSession) {
    final local = _ordered;
    if (local == null) return fromSession;
    final a = fromSession.map((e) => e.id).toSet();
    final b = local.map((e) => e.id).toSet();
    if (a.length != b.length || !a.containsAll(b)) return fromSession;
    return local;
  }

  /// 把第 [from] 张卡片移动到第 [to] 个位置，立即本地生效并持久化。
  Future<void> _reorder(int from, int to) async {
    final session = WoScope.of(context);
    final current = [
      ..._effectiveOrder(
        session.bootstrap?.installedPlugins ?? const <InstalledPlugin>[],
      ),
    ];
    if (from < 0 || from >= current.length || to < 0 || to >= current.length) {
      return;
    }
    final moved = current.removeAt(from);
    current.insert(to, moved);
    setState(() => _ordered = current);
    await _persistLayout(current);
  }

  /// 按新顺序跑 first-fit 算出 col/row，整体提交给后端。失败则回退到后端布局。
  Future<void> _persistLayout(List<InstalledPlugin> ordered) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final positions = computeWoGridPlacements(
      [
        for (final p in ordered)
          (cw: p.layout.cw.clamp(1, 4), ch: p.layout.ch.clamp(1, 4)),
      ],
      4,
    );
    final items = [
      for (var i = 0; i < ordered.length; i++)
        <String, dynamic>{
          'install_id': ordered[i].id,
          'col': positions[i].col,
          'row': positions[i].row,
          'cw': ordered[i].layout.cw.clamp(1, 4),
          'ch': ordered[i].layout.ch.clamp(1, 4),
        },
    ];
    try {
      await session.api.updateLayout(familyId, items);
      await session.refresh();
    } catch (e) {
      if (mounted) _toast(context, e);
    } finally {
      // 无论成败都以后端为准重新同步本地顺序。
      if (mounted) setState(() => _ordered = null);
    }
  }

  void _openFamilySwitcher() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _FamilySwitcherSheet(),
    );
  }

  void _openAddPluginSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddPluginSheet(),
    );
  }

  /// 点击卡片进入对应插件页（仅非编辑态）。目前仅纪念日有专属页面。
  void _openPlugin(InstalledPlugin ip) {
    switch (ip.pluginId) {
      case 'anniversary':
        context.push(WoRoutes.anniversary);
      default:
        break;
    }
  }

  Future<void> _remove(InstalledPlugin ip) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.uninstallPlugin(familyId, ip.id);
      await session.refresh();
    } catch (e) {
      if (mounted) _toast(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final session = WoScope.of(context);
    final family = session.currentFamily;

    // 没有当前家庭：引导去创建 / 加入。
    if (family == null) {
      return Scaffold(
        backgroundColor: wo.bg,
        appBar: AppBar(title: const Text('窝')),
        body: _NoFamily(onStart: () => context.push(WoRoutes.joinLanding)),
      );
    }

    final plugins = _effectiveOrder(
      session.bootstrap?.installedPlugins ?? const <InstalledPlugin>[],
    );

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(
        title: GestureDetector(
          onTap: _openFamilySwitcher,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  family.name,
                  style: t.titleLarge,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, color: wo.fgMid, size: 20),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: '通知',
            icon: Badge(
              isLabelVisible: session.unreadCount > 0,
              label: Text('${session.unreadCount}'),
              child: const Icon(Icons.notifications_outlined),
            ),
            onPressed: () => context.go(WoRoutes.messages),
          ),
          if (plugins.isNotEmpty)
            IconButton(
              tooltip: _editing ? '完成编辑' : '编辑布局',
              icon: Icon(_editing ? Icons.check : Icons.edit_outlined),
              onPressed: () => setState(() => _editing = !_editing),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: session.refresh,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              WoTokens.space4,
              WoTokens.space2,
              WoTokens.space4,
              100,
            ),
            child: plugins.isEmpty
                ? _EmptyGrid(onAdd: _openAddPluginSheet)
                : WoWidgetGrid(
                    crossAxisCount: 4,
                    gap: WoTokens.space3,
                    children: [
                      for (var i = 0; i < plugins.length; i++)
                        WoWidgetGridTile(
                          cw: plugins[i].layout.cw.clamp(1, 4),
                          ch: plugins[i].layout.ch.clamp(1, 4),
                          child: _editing
                              ? _DraggableTile(
                                  index: i,
                                  installed: plugins[i],
                                  onRemove: () => _remove(plugins[i]),
                                  onReorder: _reorder,
                                )
                              : _WidgetCard(
                                  installed: plugins[i],
                                  editing: false,
                                  onTap: () => _openPlugin(plugins[i]),
                                  onLongPress: () =>
                                      setState(() => _editing = true),
                                  onRemove: () => _remove(plugins[i]),
                                ),
                        ),
                      WoWidgetGridTile(
                        cw: 4,
                        ch: 1,
                        child: _AddPluginEntry(onTap: _openAddPluginSheet),
                      ),
                    ],
                  ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAddPluginSheet,
        child: const Icon(Icons.add),
      ),
    );
  }
}

void _toast(BuildContext context, Object error) {
  final msg = switch (error) {
    ApiException e => e.message,
    NetworkException e => e.message,
    _ => '操作失败',
  };
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// 通用 Widget 卡片，由已安装插件 + preview 驱动。
class _WidgetCard extends StatelessWidget {
  const _WidgetCard({
    required this.installed,
    required this.editing,
    this.onTap,
    this.onLongPress,
    required this.onRemove,
    this.showRemove = true,
  });

  final InstalledPlugin installed;
  final bool editing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onRemove;

  /// 拖拽预览（feedback）里不需要再画删除按钮。
  final bool showRemove;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final preview = installed.preview;
    final emphasized = wo.isEmphasizedToken(preview.colorToken);
    final color = wo.colorForToken(preview.colorToken);
    final fg = emphasized ? Colors.white : wo.fg;
    final fgMid = emphasized ? Colors.white.withValues(alpha: 0.85) : wo.fgMid;
    final isCompact = installed.layout.ch <= 1;

    return Stack(
      children: [
        Positioned.fill(
          child: WoCard(
            color: color,
            onTap: editing ? null : onTap,
            onLongPress: onLongPress,
            padding:
                EdgeInsets.all(isCompact ? WoTokens.space3 : WoTokens.space4),
            child: isCompact
                ? Row(
                    children: [
                      Text(
                        installed.plugin.emoji,
                        style: const TextStyle(fontSize: 22),
                      ),
                      const SizedBox(width: WoTokens.space3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              installed.plugin.name,
                              style: t.labelMedium?.copyWith(color: fgMid),
                            ),
                            Text(
                              preview.primary,
                              style: t.titleMedium?.copyWith(
                                color: fg,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        installed.plugin.emoji,
                        style: const TextStyle(fontSize: 26),
                      ),
                      const Spacer(),
                      Text(
                        installed.plugin.name,
                        style: t.labelMedium?.copyWith(color: fgMid),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        preview.primary,
                        style: (emphasized ? t.headlineMedium : t.titleMedium)
                            ?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (preview.secondary != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          preview.secondary!,
                          style: t.bodySmall?.copyWith(color: fgMid),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
          ),
        ),
        if (editing && showRemove)
          Positioned(
            top: 6,
            left: 6,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.remove, color: Colors.white, size: 14),
              ),
            ),
          ),
      ],
    );
  }
}

/// 编辑态下可长按拖拽重排的卡片。
///
/// 自身既是 [DragTarget]（接收别的卡片落到这里）也是 [LongPressDraggable]
/// （长按把自己拖走）。落点后回调 [onReorder]，由首页更新顺序并持久化。
class _DraggableTile extends StatelessWidget {
  const _DraggableTile({
    required this.index,
    required this.installed,
    required this.onRemove,
    required this.onReorder,
  });

  final int index;
  final InstalledPlugin installed;
  final VoidCallback onRemove;
  final void Function(int from, int to) onReorder;

  @override
  Widget build(BuildContext context) {
    // 用 LayoutBuilder 拿到当前格子的像素尺寸，喂给拖拽预览，保证 feedback
    // 大小与原卡片一致。
    return LayoutBuilder(
      builder: (context, c) {
        final card = _WidgetCard(
          installed: installed,
          editing: true,
          onRemove: onRemove,
        );
        final feedback = SizedBox(
          width: c.maxWidth,
          height: c.maxHeight,
          child: Material(
            type: MaterialType.transparency,
            child: Opacity(
              opacity: 0.92,
              child: _WidgetCard(
                installed: installed,
                editing: true,
                onRemove: onRemove,
                showRemove: false,
              ),
            ),
          ),
        );

        return DragTarget<int>(
          onWillAcceptWithDetails: (d) => d.data != index,
          onAcceptWithDetails: (d) => onReorder(d.data, index),
          builder: (context, candidate, rejected) {
            final hovering = candidate.isNotEmpty;
            return AnimatedScale(
              scale: hovering ? 1.06 : 1.0,
              duration: const Duration(milliseconds: 120),
              child: LongPressDraggable<int>(
                data: index,
                feedback: feedback,
                childWhenDragging: Opacity(opacity: 0.25, child: card),
                child: card,
              ),
            );
          },
        );
      },
    );
  }
}

/// 「+ 添加插件」入口（4×1 矮条）。
class _AddPluginEntry extends StatelessWidget {
  const _AddPluginEntry({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return DottedBorder(
      color: wo.hairline,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(WoTokens.cardRadius),
          onTap: onTap,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, color: wo.fgMid, size: 18),
                const SizedBox(width: 6),
                Text('添加插件', style: t.labelMedium?.copyWith(color: wo.fgMid)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 空网格：还没装任何插件。
class _EmptyGrid extends StatelessWidget {
  const _EmptyGrid({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        children: [
          const Text('🧩', style: TextStyle(fontSize: 48)),
          const SizedBox(height: WoTokens.space4),
          Text('还没有插件', style: t.titleMedium),
          const SizedBox(height: WoTokens.space2),
          Text(
            '从插件市场装一个，开始打理你们的窝。',
            style: t.bodyMedium?.copyWith(color: wo.fgMid),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: WoTokens.space5),
          FilledButton(onPressed: onAdd, child: const Text('去添加插件')),
        ],
      ),
    );
  }
}

/// 没有当前家庭时的引导。
class _NoFamily extends StatelessWidget {
  const _NoFamily({required this.onStart});
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🏡', style: TextStyle(fontSize: 56)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有窝', style: t.titleLarge),
            const SizedBox(height: WoTokens.space2),
            Text(
              '创建一个新家，或用邀请码加入已有的家庭。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onStart, child: const Text('创建或加入')),
          ],
        ),
      ),
    );
  }
}

/// 简单的虚线边框（避免额外依赖 dotted_border 包）
class DottedBorder extends StatelessWidget {
  const DottedBorder({super.key, required this.child, required this.color});

  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedBorderPainter(color: color, radius: WoTokens.cardRadius),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WoTokens.cardRadius),
        child: child,
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rect);

    const dash = 6.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + dash;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

// ── 家庭切换 Sheet ───────────────────────────────────────────────────
class _FamilySwitcherSheet extends StatefulWidget {
  const _FamilySwitcherSheet();

  @override
  State<_FamilySwitcherSheet> createState() => _FamilySwitcherSheetState();
}

class _FamilySwitcherSheetState extends State<_FamilySwitcherSheet> {
  bool _busy = false;

  Future<void> _switch(String familyId) async {
    if (_busy) return;
    setState(() => _busy = true);
    final session = WoScope.of(context);
    final nav = Navigator.of(context);
    try {
      await session.switchFamily(familyId);
      if (mounted) nav.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final session = WoScope.of(context);
    final families = session.families;
    final currentId = session.currentFamilyId;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: WoTokens.space5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: wo.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: WoTokens.space4),
            for (final f in families)
              Material(
                color: f.id == currentId ? wo.accentSoft : Colors.transparent,
                child: ListTile(
                  leading: Text(f.emoji, style: const TextStyle(fontSize: 22)),
                  title: Text(
                    f.name,
                    style: t.titleMedium?.copyWith(
                      color: f.id == currentId ? wo.accentDeep : wo.fg,
                      fontWeight:
                          f.id == currentId ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  trailing: f.id == currentId
                      ? Icon(Icons.check_circle, color: wo.accent)
                      : (f.myUnreadCount > 0
                          ? Container(
                              width: 8,
                              height: 8,
                              decoration: const BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                              ),
                            )
                          : null),
                  onTap: f.id == currentId ? null : () => _switch(f.id),
                ),
              ),
            const Divider(height: WoTokens.space5),
            ListTile(
              leading: Icon(Icons.add, color: wo.accentDeep),
              title: Text(
                '加入或创建新家',
                style: t.titleMedium?.copyWith(color: wo.accentDeep),
              ),
              onTap: () {
                Navigator.of(context).pop();
                context.push(WoRoutes.joinLanding);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── 添加插件半屏 Sheet ───────────────────────────────────────────────
class _AddPluginSheet extends StatefulWidget {
  const _AddPluginSheet();

  @override
  State<_AddPluginSheet> createState() => _AddPluginSheetState();
}

class _AddPluginSheetState extends State<_AddPluginSheet> {
  late Future<List<Plugin>> _future;
  String? _installingId;

  @override
  void initState() {
    super.initState();
    _future = WoScope.api(context).plugins();
  }

  Future<void> _install(Plugin p) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null || _installingId != null) return;
    setState(() => _installingId = p.id);
    final nav = Navigator.of(context);
    try {
      await session.api.installPlugin(familyId, p.id);
      await session.refresh();
      if (mounted) nav.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _installingId = null);
        _toast(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final session = WoScope.of(context);
    final installedIds = {
      for (final ip
          in session.bootstrap?.installedPlugins ?? const <InstalledPlugin>[])
        ip.pluginId,
    };

    return FractionallySizedBox(
      heightFactor: 0.72,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: WoTokens.space3),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: wo.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: WoTokens.space4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WoTokens.space5),
              child: Row(
                children: [
                  Text('添加插件', style: t.titleLarge),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      context.push('${WoRoutes.home}/marketplace');
                    },
                    child: const Text('查看全部 →'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: WoTokens.space3),
            Expanded(
              child: FutureBuilder<List<Plugin>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(
                      child: Text(
                        snap.error is ApiException
                            ? (snap.error as ApiException).message
                            : '加载失败',
                        style: t.bodyMedium?.copyWith(color: wo.fgMid),
                      ),
                    );
                  }
                  final all = snap.data ?? const <Plugin>[];
                  if (all.isEmpty) {
                    return Center(
                      child: Text(
                        '暂无可用插件',
                        style: t.bodyMedium?.copyWith(color: wo.fgMid),
                      ),
                    );
                  }
                  return GridView.count(
                    crossAxisCount: 2,
                    padding: const EdgeInsets.all(WoTokens.space5),
                    crossAxisSpacing: WoTokens.space4,
                    mainAxisSpacing: WoTokens.space4,
                    childAspectRatio: 1.1,
                    children: [
                      for (final p in all)
                        _miniCard(
                          context,
                          p,
                          installed: installedIds.contains(p.id),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniCard(BuildContext context, Plugin p, {required bool installed}) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final installing = _installingId == p.id;
    return WoCard(
      color: wo.colorForToken(p.colorToken),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p.emoji, style: const TextStyle(fontSize: 28)),
          const Spacer(),
          Text(
            p.name,
            style: t.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          OutlinedButton(
            onPressed: (installed || installing) ? null : () => _install(p),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            child: installing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(installed ? '已安装' : '安装'),
          ),
        ],
      ),
    );
  }
}
