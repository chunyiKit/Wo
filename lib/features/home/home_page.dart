import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/color_token.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';
import '../../widgets/wo_widget_grid.dart';
import '../plugins/anniversary/anniversary_edit_page.dart';

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

  /// 上次按返回键的时刻，用于「再按一次返回退出」。
  DateTime? _lastBackAt;

  /// 拦截系统返回键：编辑态先退出编辑（布局已在每次改动时即时保存），
  /// 否则需要 2 秒内连按两次才真正退出应用，避免误触退出。
  void _handleBack(bool didPop, Object? result) {
    if (didPop) return;
    if (_editing) {
      setState(() => _editing = false);
      return;
    }
    final now = DateTime.now();
    if (_lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackAt = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('再按一次返回退出'),
        duration: Duration(seconds: 2),
      ),
    );
  }

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

  /// 编辑态下点尺寸按钮，弹窗选择卡片大小（cw×ch）。
  Future<void> _openSizeSheet(InstalledPlugin p) async {
    final picked = await showModalBottomSheet<WoCardSize>(
      context: context,
      builder: (_) => _SizeSheet(
        current: (cw: p.layout.cw, ch: p.layout.ch),
      ),
    );
    if (picked != null && mounted) {
      await _resize(p, picked.cw, picked.ch);
    }
  }

  /// 改变某张卡片的大小并持久化（first-fit 会据新尺寸自动重排）。
  Future<void> _resize(InstalledPlugin p, int cw, int ch) async {
    if (p.layout.cw == cw && p.layout.ch == ch) return;
    final session = WoScope.of(context);
    final current = [
      ..._effectiveOrder(
        session.bootstrap?.installedPlugins ?? const <InstalledPlugin>[],
      ),
    ];
    final idx = current.indexWhere((e) => e.id == p.id);
    if (idx < 0) return;
    current[idx] = p.copyWith(layout: p.layout.copyWith(cw: cw, ch: ch));
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

  /// 点击卡片进入对应插件页（仅非编辑态）。
  ///
  /// 纪念日：绑定卡 → 直接进入所绑定纪念日的编辑页；总览卡（或绑定项已删）
  /// → 进入纪念日列表页。
  Future<void> _openPlugin(InstalledPlugin ip) async {
    if (ip.pluginId != 'anniversary') return;
    final pinnedId = ip.config['anniversary_id'] as String?;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (pinnedId != null && familyId != null) {
      try {
        final list = await session.api.anniversaries(familyId);
        Anniversary? match;
        for (final a in list) {
          if (a.id == pinnedId) {
            match = a;
            break;
          }
        }
        if (match != null && mounted) {
          await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => AnniversaryEditPage(existing: match),
            ),
          );
          if (mounted) await session.refresh();
          return;
        }
      } catch (_) {
        // 取数失败就退回列表页。
      }
    }
    if (mounted) context.push(WoRoutes.anniversary);
  }

  /// 编辑态下给纪念日卡绑定某个纪念日（或切回总览）。
  Future<void> _openBindSheet(InstalledPlugin ip) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final picked = await showModalBottomSheet<_BindChoice>(
      context: context,
      builder: (_) => _BindSheet(
        familyId: familyId,
        currentId: ip.config['anniversary_id'] as String?,
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await session.api.updatePluginConfig(
        familyId,
        ip.id,
        picked.anniversaryId == null
            ? <String, dynamic>{}
            : {'anniversary_id': picked.anniversaryId},
      );
      await session.refresh();
    } catch (e) {
      if (mounted) _toast(context, e);
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handleBack,
      child: Scaffold(
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
                                    onResize: () => _openSizeSheet(plugins[i]),
                                    onBind: plugins[i].pluginId == 'anniversary'
                                        ? () => _openBindSheet(plugins[i])
                                        : null,
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
    this.onResize,
    this.onBind,
    this.showRemove = true,
  });

  final InstalledPlugin installed;
  final bool editing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onRemove;

  /// 编辑态下点它弹出尺寸选择；为空则不显示尺寸按钮。
  final VoidCallback? onResize;

  /// 编辑态下点它弹出「绑定纪念日」选择；为空则不显示绑定按钮。
  final VoidCallback? onBind;

  /// 拖拽预览（feedback）里不需要再画编辑控件（删除 / 尺寸按钮）。
  final bool showRemove;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final preview = installed.preview;
    // 卡片主图标：优先用 preview 自带 emoji（如所选纪念日），回退插件 emoji。
    final emoji = preview.emoji ?? installed.plugin.emoji;
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
                        emoji,
                        style: const TextStyle(fontSize: 22),
                      ),
                      const SizedBox(width: WoTokens.space3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              preview.primary,
                              style: t.titleMedium?.copyWith(
                                color: fg,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // 矮卡也要能看到倒计时（secondary）；没有时回退插件名。
                            Text(
                              preview.secondary ?? installed.plugin.name,
                              style: t.labelMedium?.copyWith(color: fgMid),
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
                        emoji,
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
        if (editing && showRemove && onResize != null)
          Positioned(
            top: 6,
            right: 6,
            child: GestureDetector(
              onTap: onResize,
              child: Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.aspect_ratio,
                  color: Colors.white,
                  size: 13,
                ),
              ),
            ),
          ),
        if (editing && showRemove && onBind != null)
          Positioned(
            bottom: 6,
            right: 6,
            child: GestureDetector(
              onTap: onBind,
              child: Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.link, color: Colors.white, size: 13),
                    SizedBox(width: 3),
                    Text(
                      '绑定',
                      style: TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ],
                ),
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
    required this.onResize,
    this.onBind,
  });

  final int index;
  final InstalledPlugin installed;
  final VoidCallback onRemove;
  final void Function(int from, int to) onReorder;
  final VoidCallback onResize;
  final VoidCallback? onBind;

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
          onResize: onResize,
          onBind: onBind,
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

/// 卡片尺寸（cw×ch，单位 cell）。
typedef WoCardSize = ({int cw, int ch});

/// 可选的预设卡片尺寸。
const _cardSizePresets = <({String label, String hint, int cw, int ch})>[
  (label: '小', hint: '2×1 · 半宽矮条', cw: 2, ch: 1),
  (label: '中', hint: '2×2 · 半宽方形', cw: 2, ch: 2),
  (label: '宽', hint: '4×2 · 通栏', cw: 4, ch: 2),
];

/// 选择卡片大小的底部弹窗。返回所选 [WoCardSize]（取消则返回 null）。
class _SizeSheet extends StatelessWidget {
  const _SizeSheet({required this.current});

  final WoCardSize current;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: WoTokens.space4),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WoTokens.space5),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('卡片大小', style: t.titleLarge),
              ),
            ),
            const SizedBox(height: WoTokens.space2),
            for (final s in _cardSizePresets)
              _SizeOption(
                label: s.label,
                hint: s.hint,
                cw: s.cw,
                ch: s.ch,
                selected: s.cw == current.cw && s.ch == current.ch,
                onTap: () => Navigator.of(context).pop((cw: s.cw, ch: s.ch)),
              ),
          ],
        ),
      ),
    );
  }
}

class _SizeOption extends StatelessWidget {
  const _SizeOption({
    required this.label,
    required this.hint,
    required this.cw,
    required this.ch,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String hint;
  final int cw;
  final int ch;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Material(
      color: selected ? wo.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: WoTokens.space5,
            vertical: WoTokens.space3,
          ),
          child: Row(
            children: [
              // 按 cw×ch 比例画一个迷你预览块。
              SizedBox(
                width: 36,
                height: 36,
                child: Center(
                  child: Container(
                    width: 32 * cw / 4,
                    height: 32 * ch / 4,
                    decoration: BoxDecoration(
                      color: selected ? wo.accent : wo.fgDim,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: WoTokens.space4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: t.titleMedium?.copyWith(
                        color: selected ? wo.accentDeep : wo.fg,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    Text(hint, style: t.bodySmall?.copyWith(color: wo.fgMid)),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, color: wo.accent, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// 绑定选择结果：[anniversaryId] 为空表示「总览（显示最近的）」。
class _BindChoice {
  const _BindChoice(this.anniversaryId);
  final String? anniversaryId;
}

/// 选择这张纪念日卡要绑定哪个纪念日（或切回总览）的底部弹窗。
class _BindSheet extends StatefulWidget {
  const _BindSheet({required this.familyId, this.currentId});

  final String familyId;
  final String? currentId;

  @override
  State<_BindSheet> createState() => _BindSheetState();
}

class _BindSheetState extends State<_BindSheet> {
  late final Future<List<Anniversary>> _future;

  @override
  void initState() {
    super.initState();
    _future = WoScope.api(context).anniversaries(widget.familyId);
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: WoTokens.space4),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WoTokens.space5),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('这张卡显示哪个纪念日', style: t.titleLarge),
              ),
            ),
            const SizedBox(height: WoTokens.space2),
            // 总览选项。
            _BindRow(
              emoji: '🗓️',
              title: '总览（显示最近的）',
              selected: widget.currentId == null,
              onTap: () => Navigator.of(context).pop(const _BindChoice(null)),
            ),
            const Divider(height: 1),
            Flexible(
              child: FutureBuilder<List<Anniversary>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(WoTokens.space5),
                      child: CircularProgressIndicator(),
                    );
                  }
                  final items = snap.data ?? const <Anniversary>[];
                  if (items.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(WoTokens.space5),
                      child: Text(
                        '还没有纪念日，先去添加一个吧。',
                        style: t.bodyMedium?.copyWith(color: wo.fgMid),
                      ),
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      for (final a in items)
                        _BindRow(
                          emoji: a.emoji,
                          title: a.name,
                          subtitle: a.daysUntil == 0
                              ? '就是今天 🎉'
                              : '还有 ${a.daysUntil} 天',
                          selected: a.id == widget.currentId,
                          onTap: () =>
                              Navigator.of(context).pop(_BindChoice(a.id)),
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
}

class _BindRow extends StatelessWidget {
  const _BindRow({
    required this.emoji,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String emoji;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Material(
      color: selected ? wo.accentSoft : Colors.transparent,
      child: ListTile(
        leading: Text(emoji, style: const TextStyle(fontSize: 22)),
        title: Text(
          title,
          style: t.titleMedium?.copyWith(
            color: selected ? wo.accentDeep : wo.fg,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, style: t.bodySmall?.copyWith(color: wo.fgMid)),
        trailing: selected ? Icon(Icons.check_circle, color: wo.accent) : null,
        onTap: onTap,
      ),
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
            if (currentId != null)
              ListTile(
                leading: Icon(Icons.settings_outlined, color: wo.fgMid),
                title: Text('家庭设置', style: t.titleMedium),
                onTap: () {
                  Navigator.of(context).pop();
                  context.push(WoRoutes.familyManage);
                },
              ),
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
                          // 多实例插件（如纪念日）可重复添加，不置灰。
                          installed:
                              !p.multiInstance && installedIds.contains(p.id),
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
