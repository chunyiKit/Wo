import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/wo_card.dart';
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
  // `_future` 仅驱动「首次加载」的 spinner；拉到的数据缓存进 `_memories`，
  // 之后的刷新(从详情/编辑返回、下拉)只静默更新 `_memories` 并就地替换，
  // 不再把整条时间线换成 spinner——否则返回时间线会整屏闪一下、所有缩略图
  // 跟着重新加载，观感很差。
  late Future<List<Memory>> _future;
  List<Memory>? _memories;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<Memory>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <Memory>[])
        : session.api.memories(familyId);
  }

  void _store(List<Memory> list) {
    if (mounted) setState(() => _memories = list);
  }

  /// 首次加载失败后的重试：清空数据，回到 spinner 重新拉。
  Future<void> _retry() {
    setState(() {
      _memories = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  /// 返回 / 下拉刷新：保留当前列表，后台静默拉取后就地替换，不闪 spinner。
  Future<void> _refreshSilently() async {
    try {
      final list = await _fetch();
      if (mounted) setState(() => _memories = list);
    } catch (_) {
      // 拉取失败就继续显示旧数据，不打断浏览。
    }
    // 列表变化会影响首页卡片预览，刷新一次 bootstrap。
    if (mounted) await WoScope.of(context).refresh();
  }

  Future<void> _openEditor() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const MemoryEditPage()),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _openDetail(Memory m) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => MemoryDetailPage(memory: m)),
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
                    child: _Timeline(memories: memories, onTapMemory: _openDetail),
                  ))
            : AsyncView<List<Memory>>(
                future: _future,
                onRetry: _retry,
                builder: (context, all) => all.isEmpty
                    ? _Empty(onAdd: _openEditor)
                    : _Timeline(memories: all, onTapMemory: _openDetail),
              ),
      ),
    );
  }
}

/// 整条时间线：背景一根贯穿线（顶部 accent → 中性 hairline），前景内容列。
class _Timeline extends StatelessWidget {
  const _Timeline({required this.memories, required this.onTapMemory});

  final List<Memory> memories;
  final ValueChanged<Memory> onTapMemory;

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
    for (final (label, items) in groups) {
      rows.add(_MonthHeader(label: label, count: items.length));
      for (final m in items) {
        rows.add(
          _RailRow(
            node: _node(wo, firstEntry ? _NodeKind.first : _NodeKind.entry),
            nodeTop: 20,
            child: Padding(
              padding: const EdgeInsets.only(bottom: WoTokens.space3),
              child: _MemoryCard(memory: m, onTap: () => onTapMemory(m)),
            ),
          ),
        );
        firstEntry = false;
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
