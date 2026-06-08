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
class MemoryListPage extends StatefulWidget {
  const MemoryListPage({super.key});

  @override
  State<MemoryListPage> createState() => _MemoryListPageState();
}

class _MemoryListPageState extends State<MemoryListPage> {
  // `_future` 仅驱动「首次加载、且本地无缓存」时的骨架屏；拉到的数据缓存进
  // `_memories`，之后的刷新(从详情/编辑返回、下拉)只静默更新并就地替换，不再把整条
  // 时间线换成骨架——否则返回时间线会整屏闪一下、所有缩略图跟着重新加载，观感很差。
  //
  // 进页面时优先吃本地缓存(`MemoryCache`)：进程内热缓存命中就首帧直接渲染(秒开)，
  // 未命中再读盘补；网络回来后静默替换并回写缓存 + 预热图片。
  late Future<List<Memory>> _future;
  List<Memory>? _memories;
  bool _loaded = false;

  // 捕获一次 session 引用：网络回调(.then)里要回写缓存 / 预热图片，此时页面可能已退出，
  // 不能再走 `WoScope.of(context)`（context 已失效）。session 与 App 同生命周期，安全。
  late final WoSession _session;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _session = WoScope.of(context);
    final familyId = _session.currentFamilyId;
    // 1) 进程内热缓存命中 → 首帧直接渲染，秒开（多见于主页已后台预取过）。
    if (familyId != null) {
      final hot = MemoryCache.peek(familyId);
      if (hot != null && hot.isNotEmpty) _memories = hot;
    }
    // 2) 启网络：驱动「无缓存」时的骨架/错误态，回来后静默替换 + 回写。
    _future = _fetch()
      ..then(_applyFresh).catchError(_ignoreFetchError);
    // 3) 进程内没命中就读盘补一手（冷启动后首次），不覆盖已到的网络数据。
    if (_memories == null && familyId != null) {
      unawaited(_primeFromDisk(familyId));
    }
  }

  Future<List<Memory>> _fetch() {
    final familyId = _session.currentFamilyId;
    return familyId == null
        ? Future.value(const <Memory>[])
        : _session.api.memories(familyId);
  }

  /// 读盘缓存抢先渲染：仅当网络还没回来（`_memories` 仍为空）时填入，避免覆盖新数据。
  Future<void> _primeFromDisk(String familyId) async {
    final cached = await MemoryCache.load(familyId);
    if (cached != null && cached.isNotEmpty && mounted && _memories == null) {
      setState(() => _memories = cached);
    }
  }

  /// 网络拉到新数据：就地替换 + 回写缓存 + 预热图片（回写不依赖 mounted）。
  void _applyFresh(List<Memory> list) {
    if (mounted) setState(() => _memories = list);
    _persist(list);
  }

  /// `_future` 仍持有原始错误供 AsyncView 渲染；这里只是吞掉链上的二次错误，避免未捕获。
  void _ignoreFetchError(Object _) {}

  void _persist(List<Memory> list) {
    final familyId = _session.currentFamilyId;
    if (familyId == null) return;
    unawaited(MemoryCache.save(familyId, list));
    unawaited(MemoryCache.prewarmImages(_session.api, list));
  }

  /// 首次加载失败后的重试：清空数据，回到骨架屏重新拉。
  Future<void> _retry() {
    setState(() {
      _memories = null;
      _future = _fetch()
        ..then(_applyFresh).catchError(_ignoreFetchError);
    });
    return _future;
  }

  /// 返回 / 下拉刷新：保留当前列表，后台静默拉取后就地替换，不闪骨架。
  Future<void> _refreshSilently() async {
    try {
      final list = await _fetch();
      if (mounted) setState(() => _memories = list);
      _persist(list);
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
    final memories = _memories;
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
                    child: _Timeline(
                      memories: memories,
                      onMemoryChanged: _refreshSilently,
                    ),
                  ))
            : AsyncView<List<Memory>>(
                future: _future,
                onRetry: _retry,
                loadingBuilder: (_) => const _TimelineSkeleton(),
                builder: (context, all) => all.isEmpty
                    ? _Empty(onAdd: _openEditor)
                    : _Timeline(
                        memories: all,
                        onMemoryChanged: _refreshSilently,
                      ),
              ),
      ),
    );
  }
}

/// 整条时间线：背景一根贯穿线（顶部 accent → 中性 hairline），前景内容列。
class _Timeline extends StatelessWidget {
  const _Timeline({required this.memories, required this.onMemoryChanged});

  final List<Memory> memories;

  /// 详情页带着「有改动」返回时调用，触发列表静默刷新。
  final Future<void> Function() onMemoryChanged;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;

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

    final rows = <Widget>[
      _NowHeader(count: memories.length),
    ];
    var firstEntry = true;
    var cardIndex = 0; // 仅用于入场动画的错峰延迟，封顶避免长列表越往下越慢。
    for (final (label, items) in groups) {
      rows.add(_MonthHeader(label: label, count: items.length));
      for (final m in items) {
        final delayMs = 40 * (cardIndex < 8 ? cardIndex : 8);
        rows.add(
          _RailRow(
            node: _node(wo, firstEntry ? _NodeKind.first : _NodeKind.entry),
            nodeTop: 20,
            child: Padding(
              padding: const EdgeInsets.only(bottom: WoTokens.space3),
              child: _MemoryCardContainer(
                memory: m,
                onMemoryChanged: onMemoryChanged,
              ),
            ),
          )
              // key 让元素按回忆 id 复用：静默刷新时已在屏的卡片不重播动画，
              // 只有首屏首次挂载、或新增的回忆才淡入上滑（一次性）。
              .animate(key: ValueKey('m-${m.id}'), delay: delayMs.ms)
              .fadeIn(duration: 280.ms)
              .slideY(begin: 0.08, end: 0, duration: 320.ms, curve: Curves.easeOutCubic),
        );
        firstEntry = false;
        cardIndex++;
      }
    }
    rows.add(_StartFooter());

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: WoTokens.space2, bottom: 100),
      child: Stack(
        children: [
          // 贯穿线（中性），由 Column 的高度撑开。
          Positioned(
            left: _railX - 1,
            top: 0,
            bottom: 0,
            child: Container(width: 2, color: wo.hairline),
          ),
          // 顶段 accent，制造「现在 → 过去」的视觉重力。
          Positioned(
            left: _railX - 1.5,
            top: 0,
            child: Container(
              width: 3,
              height: 64,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [wo.accent, wo.hairline],
                ),
              ),
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        ],
      ),
    );
  }
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
        padding: const EdgeInsets.fromLTRB(0, WoTokens.space4, 0, WoTokens.space2),
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

/// 把一个节点摆到贯穿线上，内容卡片整体右缩 [_railPadLeft]。
class _RailRow extends StatelessWidget {
  const _RailRow({
    required this.node,
    required this.child,
    this.nodeTop = 18,
  });

  final Widget node;
  final Widget child;
  final double nodeTop;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: _railPadLeft, right: WoTokens.space4),
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
                Text(m.authorName!, style: t.labelSmall?.copyWith(color: wo.fgMid)),
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
                Text(m.location!, style: t.labelSmall?.copyWith(color: wo.fgDim)),
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
              child: WoSkeletonBox(width: 160, height: 26, radius: WoTokens.chipRadius),
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
      child: Stack(
        children: [
          Positioned(
            left: _railX - 1,
            top: 0,
            bottom: 0,
            child: Container(width: 2, color: wo.hairline),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        ],
      ),
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
                    WoSkeletonBox(width: 18, height: 18, shape: BoxShape.circle),
                  ],
                ),
                if (withMedia) ...const [
                  SizedBox(height: WoTokens.space2),
                  WoSkeletonBox(width: double.infinity, height: 150, radius: 14),
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
