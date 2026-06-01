import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/wo_card.dart';
import 'calendar_edit_page.dart';

/// 家历首页：把全家的日程 / 待办按时间排成一份「议程」。
///
/// 顺序：未完成的有日期项按「过期 / 今天 / 明天 / 本周 / 以后」分组，
/// 然后是无日期待办，最后是可折叠的已完成。勾选完成、点开编辑、可催负责人。
class CalendarListPage extends StatefulWidget {
  const CalendarListPage({super.key});

  @override
  State<CalendarListPage> createState() => _CalendarListPageState();
}

class _CalendarListPageState extends State<CalendarListPage> {
  // `_future` 只驱动首屏 spinner;数据缓存进 `_items`,之后的增删改静默就地替换,
  // 不闪——见 CLAUDE.md「列表页刷新不能闪一下」。
  late Future<List<CalendarItem>> _future;
  List<CalendarItem>? _items;
  bool _loaded = false;
  bool _showDone = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<CalendarItem>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <CalendarItem>[])
        : session.api.calendarItems(familyId);
  }

  void _store(List<CalendarItem> list) {
    if (mounted) setState(() => _items = list);
  }

  Future<void> _retry() {
    setState(() {
      _items = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  Future<void> _refreshSilently() async {
    try {
      final list = await _fetch();
      if (mounted) setState(() => _items = list);
    } catch (_) {
      // 拉取失败就继续显示旧数据,不打断操作。
    }
    if (mounted) await WoScope.of(context).refresh();
  }

  Future<void> _openEditor([CalendarItem? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CalendarEditPage(existing: existing)),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _toggle(CalendarItem c) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      if (c.done) {
        await session.api.reopenCalendarItem(familyId, c.id);
      } else {
        await session.api.completeCalendarItem(familyId, c.id);
      }
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _remind(CalendarItem c) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.remindCalendarItem(familyId, c.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已提醒 ${c.assigneeName ?? '负责人'}')),
        );
      }
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _delete(CalendarItem c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text('确定删除「${c.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.deleteCalendarItem(familyId, c.id);
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  void _toast(Object error) {
    final msg = switch (error) {
      ApiException e => e.message,
      NetworkException e => e.message,
      _ => '操作失败',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 把有日期的未完成项按到期远近分到固定的几个桶里。
  static String _bucket(int daysUntil) {
    if (daysUntil < 0) return '已过期';
    if (daysUntil == 0) return '今天';
    if (daysUntil == 1) return '明天';
    if (daysUntil <= 7) return '本周内';
    return '以后';
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('家历')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        backgroundColor: wo.calendar,
        foregroundColor: wo.fg,
        icon: const Icon(Icons.add),
        label: const Text('加一项'),
      ),
      body: SafeArea(
        child: _items != null
            ? _buildBody(context, _items!)
            : AsyncView<List<CalendarItem>>(
                future: _future,
                onRetry: _retry,
                builder: _buildBody,
              ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<CalendarItem> all) {
    final myId = WoScope.of(context).user?.id;
    if (all.isEmpty) return _Empty(onAdd: _openEditor);

    final open = all.where((c) => !c.done).toList();
    final dated = open.where((c) => !c.isTodo).toList();
    final todos = open.where((c) => c.isTodo).toList();
    final done = all.where((c) => c.done).toList();

    // 行集合：分组标题 + 条目，混在一个 ListView 里。
    final rows = <Widget>[];

    String? lastBucket;
    for (final c in dated) {
      final b = _bucket(c.daysUntil ?? 0);
      if (b != lastBucket) {
        rows.add(_SectionHeader(text: b));
        lastBucket = b;
      }
      rows.add(
        _ItemTile(
          item: c,
          isMine: c.assignedTo != null && c.assignedTo == myId,
          onToggle: () => _toggle(c),
          onRemind: () => _remind(c),
          onEdit: () => _openEditor(c),
          onDelete: () => _delete(c),
        ),
      );
    }

    if (todos.isNotEmpty) {
      rows.add(const _SectionHeader(text: '待办（无日期）'));
      for (final c in todos) {
        rows.add(
          _ItemTile(
            item: c,
            isMine: c.assignedTo != null && c.assignedTo == myId,
            onToggle: () => _toggle(c),
            onRemind: () => _remind(c),
            onEdit: () => _openEditor(c),
            onDelete: () => _delete(c),
          ),
        );
      }
    }

    if (done.isNotEmpty) {
      rows.add(
        _DoneHeader(
          count: done.length,
          expanded: _showDone,
          onTap: () => setState(() => _showDone = !_showDone),
        ),
      );
      if (_showDone) {
        for (final c in done) {
          rows.add(
            _ItemTile(
              item: c,
              isMine: c.assignedTo != null && c.assignedTo == myId,
              onToggle: () => _toggle(c),
              onRemind: () => _remind(c),
              onEdit: () => _openEditor(c),
              onDelete: () => _delete(c),
            ),
          );
        }
      }
    }

    if (rows.isEmpty) return _Empty(onAdd: _openEditor);

    return RefreshIndicator(
      onRefresh: _refreshSilently,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          WoTokens.space4,
          WoTokens.space2,
          WoTokens.space4,
          100,
        ),
        children: rows,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final danger = text == '已过期';
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(4, WoTokens.space3, 4, WoTokens.space2),
      child: Text(
        text,
        style: t.labelLarge?.copyWith(
          color: danger ? wo.danger : wo.fgMid,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DoneHeader extends StatelessWidget {
  const _DoneHeader({
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: WoTokens.space3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              vertical: WoTokens.space2, horizontal: 4),
          child: Row(
            children: [
              Text(
                '已完成 $count',
                style: t.labelLarge?.copyWith(
                  color: wo.fgMid,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: wo.fgDim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.isMine,
    required this.onToggle,
    required this.onRemind,
    required this.onEdit,
    required this.onDelete,
  });

  final CalendarItem item;
  final bool isMine;
  final VoidCallback onToggle;
  final VoidCallback onRemind;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final done = item.done;
    final overdue = !done && (item.daysUntil ?? 0) < 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: WoTokens.space3),
      child: WoCard(
        onTap: onEdit,
        child: Row(
          children: [
            GestureDetector(
              onTap: onToggle,
              behavior: HitTestBehavior.opaque,
              child: Icon(
                done ? Icons.check_circle : Icons.radio_button_unchecked,
                color: done ? wo.calendar : wo.fgDim,
                size: 28,
              ),
            ),
            const SizedBox(width: WoTokens.space3),
            Text(item.emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: WoTokens.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: t.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      decoration: done ? TextDecoration.lineThrough : null,
                      color: done ? wo.fgDim : wo.fg,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  _MetaLine(item: item, isMine: isMine, overdue: overdue),
                ],
              ),
            ),
            if (!done && item.isAssigned)
              IconButton(
                tooltip: '提醒 TA',
                icon: Icon(Icons.notifications_active_outlined,
                    color: wo.calendar),
                onPressed: onRemind,
              ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: wo.fgDim),
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'delete') onDelete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 条目副行：日期 / 时间 + 重复标记 + 负责人。
class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.item,
    required this.isMine,
    required this.overdue,
  });

  final CalendarItem item;
  final bool isMine;
  final bool overdue;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  String _dateLabel() {
    final d = item.nextDate ?? item.eventDate;
    if (d == null) return '';
    final time = item.timeLabel;
    final base = '${d.month}月${d.day}日 周${_weekdays[d.weekday - 1]}';
    return time.isEmpty ? base : '$base $time';
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final chips = <Widget>[];

    if (!item.isTodo) {
      chips.add(
        Text(
          _dateLabel(),
          style: t.labelSmall?.copyWith(
            color: overdue ? wo.danger : wo.fgMid,
            fontWeight: overdue ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      );
      if (item.isRecurring) {
        chips.add(_RepeatBadge(repeat: item.repeat));
      }
    }

    if (item.isAssigned && item.assigneeName != null) {
      chips.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            MemberAvatar(
              url: item.assigneeAvatarUrl,
              emoji: item.assigneeEmoji ?? '👤',
              size: 16,
            ),
            const SizedBox(width: 4),
            Text(
              isMine ? '${item.assigneeName}（我）' : item.assigneeName!,
              style: t.labelSmall?.copyWith(
                color: isMine ? wo.calendar : wo.fgMid,
                fontWeight: isMine ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    if (chips.isEmpty) {
      return Text('待办', style: t.labelSmall?.copyWith(color: wo.fgDim));
    }

    return Wrap(
      spacing: WoTokens.space2,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: chips,
    );
  }
}

class _RepeatBadge extends StatelessWidget {
  const _RepeatBadge({required this.repeat});
  final String repeat;

  static const _labels = {
    'daily': '每天',
    'weekly': '每周',
    'monthly': '每月',
  };

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: wo.calendar.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.repeat, size: 11, color: wo.calendar),
          const SizedBox(width: 2),
          Text(
            _labels[repeat] ?? '重复',
            style: t.labelSmall?.copyWith(
              color: wo.calendar,
              fontWeight: FontWeight.w600,
            ),
          ),
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
            const Text('📅', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有安排', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把全家的日程和待办都记在这里，谁几点有事一目了然。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('加第一项')),
          ],
        ),
      ),
    );
  }
}
