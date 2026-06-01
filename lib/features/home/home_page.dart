import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
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
import '../plugins/plugin_pages.dart';
import '../plugins/stock/stock_page.dart';

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

  /// 当前有未完成项的采买清单来源；空列表 → 不展示 banner。
  ///
  /// 当前所有采买条目都落在囤货铺一张表里，按 note 是否以「来自菜谱」开头切
  /// 成「食材采买 / 囤货采买」两组——0 / 1 / 2 三种情况都涵盖：
  /// - 0 组 → 没东西要买，banner 隐藏
  /// - 1 组 → 点 banner 直接进囤货铺采买 tab
  /// - 2 组 → 点 banner 弹气泡，分别可点
  ///
  /// 未来如果更多插件有自己的待办清单，加新条目就行；UI 自动按上面规则切换。
  List<_ShoppingSource> _shoppingSources = const [];

  /// 当前是否在拉采买计数；用于防抖。
  bool _shoppingLoading = false;

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
    final page = pluginPageFor(ip);
    if (page == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => page),
    );
    if (mounted) {
      // 进过任何插件回来都顺手刷一下采买计数：囤货铺里勾掉一项 / 菜谱里加新
      // 食材入采买 / 别的任何会改 stock_buys 的路径都涵盖了。
      await Future.wait([
        WoScope.of(context).refresh(),
        _refreshShoppingSources(),
      ]);
    }
  }

  /// 进 [StockPage] 并直接定位到指定 tab（0 囤货 / 1 采买）。供采买 banner 用。
  Future<void> _openStock({int initialTabIndex = 0}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => StockPage(initialTabIndex: initialTabIndex),
      ),
    );
    if (mounted) {
      await Future.wait([
        WoScope.of(context).refresh(),
        _refreshShoppingSources(),
      ]);
    }
  }

  /// 拉一次未完成的采买条目,按来源切成「食材采买 / 囤货采买」两组并写进 state。
  ///
  /// 没装囤货铺(没有 stock 插件)直接清空——这种情况下 stock_buys 端点理论上
  /// 仍会接受调用,但既然用户没装它,也不该展示这个 banner。
  Future<void> _refreshShoppingSources() async {
    if (_shoppingLoading) return;
    _shoppingLoading = true;
    try {
      final session = WoScope.of(context);
      final familyId = session.currentFamilyId;
      if (familyId == null) {
        if (mounted) setState(() => _shoppingSources = const []);
        return;
      }
      final installed = session.bootstrap?.installedPlugins ?? const [];
      final hasStock = installed.any((p) => p.pluginId == 'stock');
      if (!hasStock) {
        if (mounted) setState(() => _shoppingSources = const []);
        return;
      }

      List<BuyItem> rows;
      try {
        rows = await session.api.buyItems(familyId, bought: false);
      } catch (_) {
        // 后端临时挂掉时静默——下次刷新会再试,没必要打扰用户。
        return;
      }
      final fromRecipe = <BuyItem>[];
      final fromStock = <BuyItem>[];
      for (final r in rows) {
        if ((r.note ?? '').startsWith('来自菜谱')) {
          fromRecipe.add(r);
        } else {
          fromStock.add(r);
        }
      }
      final next = <_ShoppingSource>[
        if (fromRecipe.isNotEmpty)
          _ShoppingSource(
            label: '食材采买',
            emoji: '🍳',
            count: fromRecipe.length,
          ),
        if (fromStock.isNotEmpty)
          _ShoppingSource(
            label: '囤货采买',
            emoji: '📦',
            count: fromStock.length,
          ),
      ];
      if (mounted) setState(() => _shoppingSources = next);
    } finally {
      _shoppingLoading = false;
    }
  }

  /// 点采买 banner:只一个来源就直接进囤货铺采买 tab;多个来源弹气泡选。
  Future<void> _onShoppingBannerTap(GlobalKey anchorKey) async {
    if (_shoppingSources.isEmpty) return;
    if (_shoppingSources.length == 1) {
      await _openStock(initialTabIndex: 1);
      return;
    }
    final picked = await _showShoppingPopup(anchorKey);
    if (picked == null || !mounted) return;
    // 暂时所有来源都落到同一个囤货铺采买 tab——以后如果加了按来源过滤,可以
    // 在这里根据 picked 传不同 filter。
    await _openStock(initialTabIndex: 1);
  }

  /// 在 banner 下方弹一个 PopupMenu,展示各采买来源。
  Future<_ShoppingSource?> _showShoppingPopup(GlobalKey anchorKey) async {
    final ctx = anchorKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return null;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final position = RelativeRect.fromLTRB(
      topLeft.dx,
      bottomRight.dy,
      overlay.size.width - bottomRight.dx,
      0,
    );
    return showMenu<_ShoppingSource>(
      context: context,
      position: position,
      items: [
        for (final s in _shoppingSources)
          PopupMenuItem<_ShoppingSource>(
            value: s,
            child: Row(
              children: [
                Text(s.emoji, style: const TextStyle(fontSize: 18)),
                const SizedBox(width: WoTokens.space2),
                Text(s.label),
                const SizedBox(width: WoTokens.space2),
                Text(
                  '${s.count} 项',
                  style: TextStyle(
                    color: context.wo.fgMid,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    // initState 里拿不到 InheritedWidget,延迟到第一帧后再去 WoScope 拉数据。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshShoppingSources();
    });
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
            // 下拉刷新同时拉 bootstrap 和采买计数,两者独立失败都不互相影响。
            onRefresh: () async {
              await Future.wait([
                session.refresh(),
                _refreshShoppingSources(),
              ]);
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                WoTokens.space4,
                WoTokens.space2,
                WoTokens.space4,
                100,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_shoppingSources.isNotEmpty && !_editing) ...[
                    _ShoppingBanner(
                      sources: _shoppingSources,
                      onTap: _onShoppingBannerTap,
                    ),
                    const SizedBox(height: WoTokens.space3),
                  ],
                  plugins.isEmpty
                      ? _EmptyGrid(onAdd: _openAddPluginSheet)
                      : WoWidgetGrid(
                          crossAxisCount: 4,
                          gap: WoTokens.space3,
                          children: [
                        for (var i = 0; i < plugins.length; i++)
                          WoWidgetGridTile(
                            tileKey: ValueKey(plugins[i].id),
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
                      ],
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
    // secondary 可带强调色（如预算见底），为空回退到 fgMid。
    final secondaryColor = wo.colorForTone(preview.secondaryTone) ?? fgMid;
    final isCompact = installed.layout.ch <= 1;
    // 4×2 大卡且 preview 带了缩略图（目前只有回忆插件返回）时，右半边塞一个
    // 淡入淡出的轮播；其它 4×2 卡（如纪念日）仍走纯文字 Column 布局。
    final showImageCarousel = !isCompact &&
        installed.layout.cw >= 4 &&
        preview.imageUrls.isNotEmpty;

    // 大卡的文字栏（emoji + 插件名 + primary + secondary）抽出来,大卡 + 带轮播
    // 时它放在 Row 左半 Expanded 里，否则就是整张卡的 Column。
    Widget buildBigTextColumn() => Column(
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
              style: (emphasized ? t.headlineMedium : t.titleMedium)?.copyWith(
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
                style: t.bodySmall?.copyWith(
                  color: secondaryColor,
                  fontWeight:
                      preview.secondaryTone != null ? FontWeight.w700 : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        );

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
                              style: t.labelMedium?.copyWith(
                                color: preview.secondary != null
                                    ? secondaryColor
                                    : fgMid,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : showImageCarousel
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: buildBigTextColumn()),
                          const SizedBox(width: WoTokens.space3),
                          Expanded(
                            child: _MemoryCarousel(
                              urls: [
                                for (final p in preview.imageUrls)
                                  '${WoScope.api(context).baseUrl}$p',
                              ],
                              headers: WoScope.api(context).imageHeaders,
                            ),
                          ),
                        ],
                      )
                    : buildBigTextColumn(),
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

/// 4×2 卡片右半边的图片轮播：每 4 秒切下一张，淡入淡出。
///
/// 用 [AnimatedSwitcher] 而不是 PageView 是因为 PageView 的横向滑动跟卡片本身
/// 的拖拽 / 进详情页冲突，而且左右切的动效在 home 这种紧凑卡片里太突兀。
/// AnimatedSwitcher 的默认 layoutBuilder 是把 in/out 两个 child 叠在 Stack 里同时
/// 渐变，所以淡入淡出是天然的——只需要给每个 [CachedNetworkImage] 套一个以 url
/// 为 key 的 [ValueKey]，Switcher 才会识别出 child 变了。
///
/// 缓存复用：home 卡片走这里加载的图片，跟回忆详情页里的 [MemoryMediaTile] 同
/// URL，所以走的是同一份 [DefaultCacheManager] 缓存——首次冷启动会拉网络，进
/// 详情页时已经在内存里了。
class _MemoryCarousel extends StatefulWidget {
  const _MemoryCarousel({
    required this.urls,
    required this.headers,
  });

  final List<String> urls;
  final Map<String, String> headers;

  @override
  State<_MemoryCarousel> createState() => _MemoryCarouselState();
}

class _MemoryCarouselState extends State<_MemoryCarousel> {
  static const _switchInterval = Duration(seconds: 4);
  static const _fadeDuration = Duration(milliseconds: 700);

  int _idx = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didUpdateWidget(covariant _MemoryCarousel old) {
    super.didUpdateWidget(old);
    // URL 列表换了（preview 重新拉了）：把 index 收敛到合法范围并重置 timer。
    if (widget.urls.length != old.urls.length ||
        !_listEq(widget.urls, old.urls)) {
      _idx = _idx.clamp(0, widget.urls.length - 1);
      _restart();
    }
  }

  bool _listEq(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _restart() {
    _timer?.cancel();
    if (widget.urls.length <= 1) return;
    _timer = Timer.periodic(_switchInterval, (_) {
      if (!mounted) return;
      setState(() => _idx = (_idx + 1) % widget.urls.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty) return const SizedBox.shrink();
    final url = widget.urls[_idx];
    return ClipRRect(
      // 比卡片自己 22 的圆角小一档，跟卡片是包含关系视觉上更顺。
      borderRadius: BorderRadius.circular(12),
      child: AnimatedSwitcher(
        duration: _fadeDuration,
        // 不需要 sizeTransition 包裹——子元素自己撑满父容器，AnimatedSwitcher 走
        // 默认 layoutBuilder(Stack)，新旧 child 同时存在并各自 fade。
        child: CachedNetworkImage(
          key: ValueKey(url),
          imageUrl: url,
          httpHeaders: widget.headers,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          placeholder: (_, __) => Container(
            color: Colors.black.withValues(alpha: 0.08),
          ),
          errorWidget: (_, __, ___) => Container(
            color: Colors.black.withValues(alpha: 0.08),
          ),
        ),
      ),
    );
  }
}

/// 首页采买提醒的数据来源:一组「按来源分类的未完成采买条目」。
///
/// 当前两个固定来源（食材采买 / 囤货采买）按 BuyItem.note 是否「来自菜谱」前缀
/// 切分,以后多了别的采买入口可以再加新的 _ShoppingSource。
class _ShoppingSource {
  const _ShoppingSource({
    required this.label,
    required this.emoji,
    required this.count,
  });

  final String label;
  final String emoji;
  final int count;
}

/// 首页顶部的采买未完成提醒条。
///
/// 一行 banner:左侧购物车图标 + 文案,右侧箭头。点击行为由父级决定（[onTap] 接
/// 收一个 [GlobalKey],父级用它定位 banner 的屏幕位置,在它下方弹气泡）。
class _ShoppingBanner extends StatelessWidget {
  _ShoppingBanner({required this.sources, required this.onTap});

  final List<_ShoppingSource> sources;

  /// 父级处理点击,会把 [GlobalKey] 用来定位气泡的锚点。
  final Future<void> Function(GlobalKey anchor) onTap;

  /// 给整条 banner 一个 key,父级靠它的 RenderBox 算气泡位置。
  final GlobalKey _anchor = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final total = sources.fold<int>(0, (sum, s) => sum + s.count);
    final detail = sources.length > 1
        // 多来源直接列出来:「食材 3 · 囤货 2」,顺便提示点开能展开。
        ? sources.map((s) => '${s.label.replaceAll('采买', '')} ${s.count}').join(' · ')
        : '${sources.first.label} $total 项';
    return InkWell(
      key: _anchor,
      onTap: () => onTap(_anchor),
      borderRadius: BorderRadius.circular(WoTokens.cardRadius),
      child: Ink(
        padding: const EdgeInsets.symmetric(
          horizontal: WoTokens.space4,
          vertical: WoTokens.space3,
        ),
        decoration: BoxDecoration(
          color: wo.accentSoft,
          borderRadius: BorderRadius.circular(WoTokens.cardRadius),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: wo.accent.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.shopping_cart_outlined,
                color: wo.accentDeep,
                size: 20,
              ),
            ),
            const SizedBox(width: WoTokens.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '采买清单还有 $total 项未完成',
                    style: t.titleSmall?.copyWith(
                      color: wo.fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: t.bodySmall?.copyWith(color: wo.fgMid),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: wo.fgMid,
              size: 22,
            ),
          ],
        ),
      ),
    );
  }
}
