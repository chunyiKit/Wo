import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../data/memory_cache.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/wo_card.dart';
import '../../../widgets/wo_open_container.dart';
import '../../../widgets/wo_skeleton.dart';
import 'memory_detail_page.dart';
import 'memory_edit_page.dart';
import 'memory_media.dart';

// 时间线左侧那根贯穿全屏的线：线的 x 位置 + 卡片左缩进（给线和节点留位）。
const double _railX = 28;
const double _railPadLeft = 56;

/// 回忆首页：一条贯穿的纵向时间线，按月分组，每条记录是一张卡片。
///
/// 列表 **keyset 游标分页**：首屏只拉一页（[_pageSize] 条），用 [ListView.builder]
/// 懒渲染，滚到底再静默追加下一页——避免一次性拉全量、一次性 build 所有卡片。
class MemoryListPage extends StatefulWidget {
  const MemoryListPage({super.key});

  @override
  State<MemoryListPage> createState() => _MemoryListPageState();
}

class _MemoryListPageState extends State<MemoryListPage> {
  /// 每页条数：与后端默认对齐，覆盖一屏多一点，滚动时几乎无感续上。
  static const int _pageSize = 20;

  // `_future` 仅驱动「首次加载、且本地无缓存」时的骨架屏；拉到的数据缓存进
  // `_items`，之后的刷新(从详情/编辑返回、下拉、翻页)只静默更新并就地替换，绝不把
  // 整条时间线换成骨架——否则返回时间线会整屏闪一下、缩略图全部重新加载，观感很差。
  //
  // 进页面时优先吃本地缓存(`MemoryCache`)：进程内热缓存命中就首帧直接渲染(秒开)，
  // 未命中再读盘补；网络回来后静默替换并回写缓存 + 预热图片。
  late Future<MemoryPage> _future;
  List<Memory>? _items;

  /// 下一页游标；为 null 表示已到最早一条、没有更多（或首页尚未返回）。
  String? _nextCursor;

  /// 当前用户可见的总条数（表头「共 N 条」用，由后端 meta 给）。
  int? _total;

  /// 翻下一页进行中，避免滚动抖动里重复触发。
  bool _loadingMore = false;
  bool _loaded = false;

  /// 已播放过入场动画的回忆 id：[ListView] 会回收复用，滚回去不应重播动画。
  final Set<String> _animated = {};

  final ScrollController _scroll = ScrollController();

  // 捕获一次 session 引用：网络回调(.then)里要回写缓存 / 预热图片，此时页面可能已退出，
  // 不能再走 `WoScope.of(context)`（context 已失效）。session 与 App 同生命周期，安全。
  late final WoSession _session;

  bool get _hasMore => _nextCursor != null;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _session = WoScope.of(context);
    final familyId = _session.currentFamilyId;
    // 1) 进程内热缓存命中 → 首帧直接渲染，秒开（多见于主页已后台预取过首页）。
    if (familyId != null) {
      final hot = MemoryCache.peek(familyId);
      if (hot != null && hot.isNotEmpty) _items = hot;
    }
    // 2) 启网络拉首页：驱动「无缓存」时的骨架/错误态，回来后静默替换 + 回写。
    _future = _fetchFirst()..then(_applyFirst).catchError(_ignoreFetchError);
    // 3) 进程内没命中就读盘补一手（冷启动后首次），不覆盖已到的网络数据。
    if (_items == null && familyId != null) {
      unawaited(_primeFromDisk(familyId));
    }
  }

  Future<MemoryPage> _fetchFirst() {
    final familyId = _session.currentFamilyId;
    return familyId == null
        ? Future.value(const MemoryPage(items: []))
        : _session.api.memories(familyId, limit: _pageSize);
  }

  /// 读盘缓存抢先渲染：仅当网络还没回来（`_items` 仍为空）时填入，避免覆盖新数据。
  Future<void> _primeFromDisk(String familyId) async {
    final cached = await MemoryCache.load(familyId);
    if (cached != null && cached.isNotEmpty && mounted && _items == null) {
      setState(() => _items = cached);
    }
  }

  /// 首页拉到：就地替换 + 记录游标/总数 + 回写缓存 + 预热图片（回写不依赖 mounted）。
  void _applyFirst(MemoryPage page) {
    if (mounted) {
      setState(() {
        _items = page.items;
        _nextCursor = page.nextCursor;
        _total = page.total;
      });
    }
    _persist(page.items);
  }

  /// `_future` 仍持有原始错误供 AsyncView 渲染；这里只是吞掉链上的二次错误，避免未捕获。
  void _ignoreFetchError(Object _) {}

  /// 缓存只关心首屏，固定回写首页那批（[MemoryCache.save] 内部再截到前几条）。
  void _persist(List<Memory> firstPage) {
    final familyId = _session.currentFamilyId;
    if (familyId == null) return;
    unawaited(MemoryCache.save(familyId, firstPage));
    unawaited(MemoryCache.prewarmImages(_session.api, firstPage));
  }

  /// 首次加载失败后的重试：清空数据，回到骨架屏重新拉首页。
  Future<MemoryPage> _retry() {
    setState(() {
      _items = null;
      _nextCursor = null;
      _total = null;
      _animated.clear();
      _future = _fetchFirst()..then(_applyFirst).catchError(_ignoreFetchError);
    });
    return _future;
  }

  /// 滚动接近底部时自动续拉下一页。
  void _onScroll() {
    if (!_scroll.hasClients || !_hasMore || _loadingMore) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 600) {
      unawaited(_loadMore());
    }
  }

  /// 追加下一页：拉到后就地拼到 `_items` 尾部，不闪、不动已在屏的卡片。
  Future<void> _loadMore() async {
    final familyId = _session.currentFamilyId;
    final cursor = _nextCursor;
    if (familyId == null || cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _session.api
          .memories(familyId, cursor: cursor, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _items = [...?_items, ...page.items];
        _nextCursor = page.nextCursor;
        if (page.total != null) _total = page.total;
        _loadingMore = false;
      });
    } catch (_) {
      // 失败保留已加载内容；用户继续滚动会再次触发重试。
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 返回 / 下拉刷新：只刷新「最新一页」并与已加载内容按 id 合并，绝不丢掉翻过的页、
  /// 不把列表跳回顶部、不闪骨架。翻页前沿(`_nextCursor`)保持不动，续拉照常工作。
  Future<void> _refreshSilently() async {
    final familyId = _session.currentFamilyId;
    if (familyId == null) return;
    try {
      final page = await _session.api.memories(familyId, limit: _pageSize);
      if (mounted) {
        setState(() {
          // 首页是「最新一段」的权威结果；已加载的更早条目（不在首页里的）保留在尾部。
          final firstIds = page.items.map((m) => m.id).toSet();
          final tail = (_items ?? const <Memory>[])
              .where((m) => !firstIds.contains(m.id))
              .toList();
          _items = [...page.items, ...tail];
          if (page.total != null) _total = page.total;
          // `_nextCursor` 不动：它管的是最早一端的续拉前沿，刷新最新一端不该改它。
        });
      }
      _persist(page.items);
    } catch (_) {
      // 拉取失败就继续显示旧数据，不打断浏览。
    }
    // 列表变化会影响首页卡片预览，刷新一次 bootstrap。
    if (mounted) await _session.refresh();
  }

  Future<void> _openEditor() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const MemoryEditPage()),
    );
    if (changed == true) await _refreshSilently();
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final memories = _items;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('回忆')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openEditor,
        icon: const Icon(Icons.add),
        label: const Text('记一段'),
      ),
      body: SafeArea(
        child: memories != null
            ? (memories.isEmpty
                ? _Empty(onAdd: _openEditor)
                : RefreshIndicator(
                    onRefresh: _refreshSilently,
                    child: _buildList(memories),
                  ))
            : AsyncView<MemoryPage>(
                future: _future,
                onRetry: _retry,
                loadingBuilder: (_) => const _TimelineSkeleton(),
                builder: (context, page) => page.items.isEmpty
                    ? _Empty(onAdd: _openEditor)
                    : RefreshIndicator(
                        onRefresh: _refreshSilently,
                        child: _buildList(page.items),
                      ),
              ),
      ),
    );
  }

  /// 把已加载的回忆摊平成「行」描述，交给 [ListView.builder] 懒渲染。背景的贯穿线
  /// 由每一行各画自己那一段、首尾相接连成整线（虚拟化列表无法用一根整线一画到底）。
  Widget _buildList(List<Memory> memories) {
    final total = _total ?? memories.length;
    final rows = _rowsFor(memories, total: total, hasMore: _hasMore);
    return ListView.builder(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: WoTokens.space2, bottom: 100),
      itemCount: rows.length,
      itemBuilder: (context, i) => _rowWidget(context, rows[i]),
    );
  }

  List<_Row> _rowsFor(
    List<Memory> memories, {
    required int total,
    required bool hasMore,
  }) {
    final rows = <_Row>[_NowRow(total)];

    // 按月分组（列表已按 event_date 倒序）。
    final groups = <(String, List<Memory>)>[];
    for (final m in memories) {
      final label = memoryMonthLabel(m.eventDate);
      if (groups.isEmpty || groups.last.$1 != label) {
        groups.add((label, [m]));
      } else {
        groups.last.$2.add(m);
      }
    }

    var first = true;
    var cardIndex = 0; // 仅用于入场动画错峰延迟，封顶避免长列表越往下越慢。
    for (final (label, items) in groups) {
      rows.add(_MonthRow(label, items.length));
      for (final m in items) {
        rows.add(_CardRow(m, first, cardIndex));
        first = false;
        cardIndex++;
      }
    }
    // 还有更多 → 底部留一行加载指示；已到底 → 「故事从这里开始」收尾。
    rows.add(_TailRow(hasMore));
    return rows;
  }

  Widget _rowWidget(BuildContext context, _Row row) {
    return switch (row) {
      _NowRow(:final total) => _NowHeader(count: total),
      _MonthRow(:final label, :final count) =>
        _MonthHeader(label: label, count: count),
      _CardRow(:final memory, :final first, :final animIndex) =>
        _cardRow(context, memory, first, animIndex),
      _TailRow(:final loading) =>
        loading ? const _LoadingMoreRow() : _StartFooter(),
    };
  }

  Widget _cardRow(BuildContext context, Memory m, bool first, int animIndex) {
    final wo = context.wo;
    final row = _RailRow(
      node: _node(wo, first ? _NodeKind.first : _NodeKind.entry),
      nodeTop: 20,
      child: Padding(
        padding: const EdgeInsets.only(bottom: WoTokens.space3),
        child:
            _MemoryCardContainer(memory: m, onMemoryChanged: _refreshSilently),
      ),
    );
    // 每条回忆只在「首次进入视口」时淡入上滑一次；滚回去复用时不再重播。
    if (_animated.contains(m.id)) return row;
    _animated.add(m.id);
    final delay = animIndex < 8 ? (40 * animIndex).ms : Duration.zero;
    return row
        .animate(key: ValueKey('m-${m.id}'), delay: delay)
        .fadeIn(duration: 280.ms)
        .slideY(
            begin: 0.08, end: 0, duration: 320.ms, curve: Curves.easeOutCubic);
  }
}

// ── 行描述（喂给 ListView.builder 懒渲染）────────────────────────────────────

sealed class _Row {
  const _Row();
}

class _NowRow extends _Row {
  const _NowRow(this.total);
  final int total;
}

class _MonthRow extends _Row {
  const _MonthRow(this.label, this.count);
  final String label;
  final int count;
}

class _CardRow extends _Row {
  const _CardRow(this.memory, this.first, this.animIndex);
  final Memory memory;
  final bool first;
  final int animIndex;
}

/// 列表尾：[loading] 为 true 显示「续拉中」转圈，否则显示时间线终点。
class _TailRow extends _Row {
  const _TailRow(this.loading);
  final bool loading;
}

/// 时间线起点：accent 实心节点 + 「现在」胶囊。
class _NowHeader extends StatelessWidget {
  const _NowHeader({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return _RailRow(
      node: _node(wo, _NodeKind.now),
      nodeTop: 6,
      head: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: WoTokens.space2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: wo.accent,
              borderRadius: BorderRadius.circular(WoTokens.chipRadius),
              boxShadow: WoTokens.fabShadow,
            ),
            child: Text(
              '✦ 现在 · 共 $count 条回忆',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.label, required this.count});
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return _RailRow(
      node: _node(wo, _NodeKind.month),
      nodeTop: 22,
      child: Padding(
        padding:
            const EdgeInsets.fromLTRB(0, WoTokens.space4, 0, WoTokens.space2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              label,
              style: t.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(width: WoTokens.space2),
            Text('$count 条', style: t.labelSmall?.copyWith(color: wo.fgDim)),
          ],
        ),
      ),
    );
  }
}

/// 续拉下一页时的底部转圈占位（线继续贯穿）。
class _LoadingMoreRow extends StatelessWidget {
  const _LoadingMoreRow();

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return _RailRow(
      node: _node(wo, _NodeKind.entry),
      nodeTop: 18,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: WoTokens.space4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      ),
    );
  }
}

class _StartFooter extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return _RailRow(
      node: _node(wo, _NodeKind.start),
      nodeTop: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: WoTokens.space4),
        child: Text(
          '—— 故事从这里开始 ——',
          style: t.bodySmall?.copyWith(
            color: wo.fgDim,
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}

/// 把一个节点摆到贯穿线上，内容卡片整体右缩 [_railPadLeft]。每行自画一段贯穿线
/// （相邻行首尾相接连成整线）；[head] 为时间线顶端那一行，线用 accent→hairline 渐变。
class _RailRow extends StatelessWidget {
  const _RailRow({
    required this.node,
    required this.child,
    this.nodeTop = 18,
    this.head = false,
  });

  final Widget node;
  final Widget child;
  final double nodeTop;
  final bool head;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Stack(
      children: [
        // 这一行自己那段贯穿线。
        Positioned(
          left: _railX - 1,
          top: 0,
          bottom: 0,
          child: Container(
            width: 2,
            decoration: head
                ? BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [wo.accent, wo.hairline],
                    ),
                  )
                : BoxDecoration(color: wo.hairline),
          ),
        ),
        Padding(
          padding:
              const EdgeInsets.only(left: _railPadLeft, right: WoTokens.space4),
          child: child,
        ),
        Positioned(left: _railX, top: nodeTop, child: node),
      ],
    );
  }
}

enum _NodeKind { now, month, first, entry, start }

/// 时间线节点，已做好「中心对齐到线」的水平偏移。
Widget _node(WoColors wo, _NodeKind kind) {
  Widget dot;
  switch (kind) {
    case _NodeKind.now:
      dot = Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: wo.accent,
          shape: BoxShape.circle,
          border: Border.all(color: wo.bg, width: 3),
          boxShadow: [
            BoxShadow(color: wo.accentSoft, blurRadius: 0, spreadRadius: 2),
          ],
        ),
      );
    case _NodeKind.month:
      dot = Transform.rotate(
        angle: 0.785398, // 45°
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: wo.bg,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: wo.accent, width: 2.5),
          ),
        ),
      );
    case _NodeKind.first:
      dot = Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: wo.accent,
          shape: BoxShape.circle,
          border: Border.all(color: wo.bg, width: 3),
        ),
      );
    case _NodeKind.entry:
      dot = Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: wo.bgElev,
          shape: BoxShape.circle,
          border: Border.all(color: wo.accentDeep, width: 2),
        ),
      );
    case _NodeKind.start:
      dot = Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: wo.bg,
          shape: BoxShape.circle,
          border: Border.all(color: wo.fgDim, width: 2),
        ),
      );
  }
  // 让节点中心落在线上（线在 _railX，节点宽度居中）。
  return FractionalTranslation(
    translation: const Offset(-0.5, 0),
    child: dot,
  );
}

/// 把回忆卡片包进 [WoOpenContainer]：点击时卡片本身放大形变成详情页，返回时再缩回卡片
/// （与首页插件卡同一套形变）。详情页带 `true` 返回（编辑 / 删除 / 留言）时静默刷新列表。
class _MemoryCardContainer extends StatelessWidget {
  const _MemoryCardContainer({
    required this.memory,
    required this.onMemoryChanged,
  });

  final Memory memory;
  final Future<void> Function() onMemoryChanged;

  @override
  Widget build(BuildContext context) {
    return WoOpenContainer(
      closedBuilder: (context, open) =>
          _MemoryCard(memory: memory, onTap: open),
      openBuilder: (context) => MemoryDetailPage(memory: memory),
      onClosed: (changed) {
        if (changed == true) onMemoryChanged();
      },
    );
  }
}

/// 时间线上的单张回忆卡片。
class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.memory, required this.onTap});

  final Memory memory;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final m = memory;
    return WoCard(
      onTap: onTap,
      padding: const EdgeInsets.all(WoTokens.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头：日期 + 作者
          Row(
            children: [
              Text(
                memoryDateLabel(m.eventDate),
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: WoTokens.space2),
              Text(
                '${m.eventDate.month} 月 ${m.eventDate.day} 日',
                style: t.labelSmall?.copyWith(color: wo.fgDim),
              ),
              const Spacer(),
              if (m.authorName != null) ...[
                MemberAvatar(
                  url: m.authorAvatarUrl,
                  emoji: m.authorEmoji ?? '👤',
                  size: 18,
                ),
                const SizedBox(width: 4),
                Text(m.authorName!,
                    style: t.labelSmall?.copyWith(color: wo.fgMid)),
              ],
              if (m.visibility == 'private') ...[
                const SizedBox(width: 6),
                Icon(Icons.lock_outline, size: 13, color: wo.fgDim),
              ],
            ],
          ),
          if (m.hasMedia) ...[
            const SizedBox(height: WoTokens.space2),
            MemoryMediaGrid(media: m.media),
          ],
          if (m.title.isNotEmpty) ...[
            const SizedBox(height: WoTokens.space2),
            Text(
              m.mood != null ? '${m.mood} ${m.title}' : m.title,
              style: t.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
          if (m.body != null && m.body!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              m.body!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall?.copyWith(color: wo.fgMid, height: 1.5),
            ),
          ],
          if (m.location != null && m.location!.isNotEmpty) ...[
            const SizedBox(height: WoTokens.space2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.place_outlined, size: 13, color: wo.fgDim),
                const SizedBox(width: 3),
                Text(m.location!,
                    style: t.labelSmall?.copyWith(color: wo.fgDim)),
              ],
            ),
          ],
          if (m.commentCount > 0) ...[
            const SizedBox(height: WoTokens.space2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chat_bubble_outline, size: 13, color: wo.fgDim),
                const SizedBox(width: 4),
                Text(
                  '${m.commentCount} 条留言',
                  style: t.labelSmall?.copyWith(color: wo.fgDim),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 首屏加载占位：复刻时间线骨架（贯穿线 + 月份头 + 几张卡片轮廓），
/// 卡片内部的灰条罩 shimmer 扫光。比转圈更贴合最终布局，落地时不「跳版」。
class _TimelineSkeleton extends StatelessWidget {
  const _TimelineSkeleton();

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final rows = <Widget>[
      // 「现在」胶囊占位
      _RailRow(
        node: _node(wo, _NodeKind.entry),
        nodeTop: 6,
        child: const Padding(
          padding: EdgeInsets.only(bottom: WoTokens.space2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: WoShimmer(
              child: WoSkeletonBox(
                  width: 160, height: 26, radius: WoTokens.chipRadius),
            ),
          ),
        ),
      ),
      // 月份头占位
      _RailRow(
        node: _node(wo, _NodeKind.entry),
        nodeTop: 22,
        child: const Padding(
          padding: EdgeInsets.fromLTRB(0, WoTokens.space4, 0, WoTokens.space2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: WoShimmer(child: WoSkeletonBox(width: 96, height: 14)),
          ),
        ),
      ),
      _skeletonRow(wo, withMedia: true),
      _skeletonRow(wo, withMedia: false),
      _skeletonRow(wo, withMedia: false),
    ];

    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: WoTokens.space2, bottom: 100),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }

  Widget _skeletonRow(WoColors wo, {required bool withMedia}) {
    return _RailRow(
      node: _node(wo, _NodeKind.entry),
      nodeTop: 20,
      child: Padding(
        padding: const EdgeInsets.only(bottom: WoTokens.space3),
        child: WoCard(
          padding: const EdgeInsets.all(WoTokens.space3),
          child: WoShimmer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    WoSkeletonBox(width: 84, height: 12),
                    SizedBox(width: WoTokens.space2),
                    WoSkeletonBox(width: 48, height: 10),
                    Spacer(),
                    WoSkeletonBox(
                        width: 18, height: 18, shape: BoxShape.circle),
                  ],
                ),
                if (withMedia) ...const [
                  SizedBox(height: WoTokens.space2),
                  WoSkeletonBox(
                      width: double.infinity, height: 150, radius: 14),
                ],
                const SizedBox(height: WoTokens.space2),
                const WoSkeletonBox(width: 200, height: 13),
                const SizedBox(height: 8),
                const WoSkeletonBox(width: double.infinity, height: 10),
                const SizedBox(height: 6),
                const WoSkeletonBox(width: double.infinity, height: 10),
                const SizedBox(height: 6),
                const WoSkeletonBox(width: 120, height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;

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
            const Text('📸', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有回忆', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把值得记住的瞬间记下来，配上照片或视频，\n串成你们的时间线。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('记下第一段')),
          ],
        ),
      ),
    );
  }
}
