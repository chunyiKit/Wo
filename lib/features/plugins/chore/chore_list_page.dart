import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/wo_card.dart';
import 'chore_edit_page.dart';

/// 家务首页：待做 / 已完成筛选 + 列表浏览，可勾选完成、催负责人。
class ChoreListPage extends StatefulWidget {
  const ChoreListPage({super.key});

  @override
  State<ChoreListPage> createState() => _ChoreListPageState();
}

class _ChoreListPageState extends State<ChoreListPage> {
  late Future<List<Chore>> _future;
  bool _loaded = false;

  // null = 全部；false = 待做；true = 已完成。默认看待做。
  bool? _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _reload();
    }
  }

  void _reload() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    _future = familyId == null
        ? Future.value(const <Chore>[])
        : session.api.chores(familyId);
  }

  Future<void> _refreshAll() async {
    if (!mounted) return;
    setState(_reload);
    // 列表变化会影响首页卡片预览，刷新一次 bootstrap。
    await WoScope.of(context).refresh();
  }

  Future<void> _openEditor([Chore? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ChoreEditPage(existing: existing)),
    );
    if (changed == true) await _refreshAll();
  }

  Future<void> _toggleDone(Chore c) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      if (c.done) {
        await session.api.reopenChore(familyId, c.id);
      } else {
        await session.api.completeChore(familyId, c.id);
      }
      await _refreshAll();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _remind(Chore c) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.remindChore(familyId, c.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已提醒 ${c.assigneeName ?? '负责人'}')),
        );
      }
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _resetRecurring() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('一键重新匹配'),
        content: const Text(
          '把所有「每周重复」的家务重新打开为待做，负责人保持不变，开启新一周。确定吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('重新匹配'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      final count = await session.api.resetRecurringChores(familyId);
      await _refreshAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              count > 0 ? '已重新匹配 $count 件重复家务' : '重复家务都已是待做状态',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _delete(Chore c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除家务'),
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
      await session.api.deleteChore(familyId, c.id);
      await _refreshAll();
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

  List<Chore> _filter(List<Chore> all) =>
      _done == null ? all : all.where((c) => c.done == _done).toList();

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final myId = WoScope.of(context).user?.id;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('家务活')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('加家务'),
      ),
      body: SafeArea(
        child: AsyncView<List<Chore>>(
          future: _future,
          onRetry: () => setState(_reload),
          builder: (context, all) {
            if (all.isEmpty) return _Empty(onAdd: _openEditor);
            final items = _filter(all);
            final hasRecurring = all.any((c) => c.recurring);
            return Column(
              children: [
                _FilterBar(
                  selected: _done,
                  onSelect: (v) => setState(() => _done = v),
                  onResetRecurring: hasRecurring ? _resetRecurring : null,
                ),
                Expanded(
                  child: items.isEmpty
                      ? const _EmptyFilter()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(
                            WoTokens.space4,
                            WoTokens.space2,
                            WoTokens.space4,
                            100,
                          ),
                          itemCount: items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: WoTokens.space3),
                          itemBuilder: (_, i) => _ChoreTile(
                            chore: items[i],
                            isMine: items[i].assignedTo != null &&
                                items[i].assignedTo == myId,
                            onToggle: () => _toggleDone(items[i]),
                            onRemind: () => _remind(items[i]),
                            onEdit: () => _openEditor(items[i]),
                            onDelete: () => _delete(items[i]),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 待做 / 已完成 / 全部 三段筛选；有重复家务时右侧显示「一键重新匹配」。
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.selected,
    required this.onSelect,
    this.onResetRecurring,
  });

  final bool? selected;
  final ValueChanged<bool?> onSelect;

  /// 为空时不显示一键重新匹配按钮（家庭里没有重复家务）。
  final VoidCallback? onResetRecurring;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final options = <(bool?, String)>[
      (false, '待做'),
      (true, '已完成'),
      (null, '全部'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WoTokens.space4,
        vertical: WoTokens.space2,
      ),
      child: Row(
        children: [
          for (final (value, label) in options) ...[
            ChoiceChip(
              label: Text(label),
              selected: value == selected,
              onSelected: (_) => onSelect(value),
            ),
            const SizedBox(width: WoTokens.space2),
          ],
          const Spacer(),
          if (onResetRecurring != null)
            TextButton.icon(
              onPressed: onResetRecurring,
              style: TextButton.styleFrom(foregroundColor: wo.chore),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重新匹配'),
            ),
        ],
      ),
    );
  }
}

class _ChoreTile extends StatelessWidget {
  const _ChoreTile({
    required this.chore,
    required this.isMine,
    required this.onToggle,
    required this.onRemind,
    required this.onEdit,
    required this.onDelete,
  });

  final Chore chore;
  final bool isMine;
  final VoidCallback onToggle;
  final VoidCallback onRemind;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final done = chore.done;
    return WoCard(
      onTap: onEdit,
      child: Row(
        children: [
          GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: Icon(
              done ? Icons.check_circle : Icons.radio_button_unchecked,
              color: done ? wo.chore : wo.fgDim,
              size: 28,
            ),
          ),
          const SizedBox(width: WoTokens.space3),
          Text(chore.emoji, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chore.title,
                  style: t.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    decoration: done ? TextDecoration.lineThrough : null,
                    color: done ? wo.fgDim : wo.fg,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Flexible(child: _AssigneeLine(chore: chore, isMine: isMine)),
                    if (chore.recurring) ...[
                      const SizedBox(width: WoTokens.space2),
                      const _RecurringBadge(),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // 已指派且未完成时，可手动催一催。
          if (!done && chore.isAssigned)
            IconButton(
              tooltip: '提醒 TA',
              icon: Icon(Icons.notifications_active_outlined, color: wo.chore),
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
    );
  }
}

/// 「每周」重复标记，提示这条家务参与一键重新匹配。
class _RecurringBadge extends StatelessWidget {
  const _RecurringBadge();

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: wo.chore.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.refresh, size: 11, color: wo.chore),
          const SizedBox(width: 2),
          Text(
            '每周',
            style: t.labelSmall?.copyWith(
              color: wo.chore,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _AssigneeLine extends StatelessWidget {
  const _AssigneeLine({required this.chore, required this.isMine});

  final Chore chore;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    if (!chore.isAssigned || chore.assigneeName == null) {
      return Text(
        '未指派',
        style: t.labelSmall?.copyWith(color: wo.fgDim),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MemberAvatar(
          url: chore.assigneeAvatarUrl,
          emoji: chore.assigneeEmoji ?? '👤',
          size: 16,
        ),
        const SizedBox(width: 4),
        Text(
          isMine ? '${chore.assigneeName}（我）' : chore.assigneeName!,
          style: t.labelSmall?.copyWith(
            color: isMine ? wo.chore : wo.fgMid,
            fontWeight: isMine ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
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
            const Text('🧹', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有家务', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把家里的活儿列出来，分给大家一起干。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('加第一件家务')),
          ],
        ),
      ),
    );
  }
}

class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter();

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
            const Text('✨', style: TextStyle(fontSize: 40)),
            const SizedBox(height: WoTokens.space3),
            Text(
              '这里空空如也',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
            ),
          ],
        ),
      ),
    );
  }
}
