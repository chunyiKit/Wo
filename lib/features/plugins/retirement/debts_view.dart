import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/wo_card.dart';
import 'debt_edit_page.dart';
import 'retirement_common.dart';

/// 「负债」tab：家庭负债（房贷 / 车贷 / 其他）列表，定时扣款递减。
class DebtsView extends StatefulWidget {
  const DebtsView({super.key, required this.onChanged});

  final VoidCallback onChanged;

  @override
  State<DebtsView> createState() => _DebtsViewState();
}

class _DebtsViewState extends State<DebtsView> {
  late Future<List<RetireDebt>> _future;
  List<RetireDebt>? _items;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<RetireDebt>> _fetch() {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    return fid == null
        ? Future.value(const <RetireDebt>[])
        : session.api.retireDebts(fid);
  }

  void _store(List<RetireDebt> list) {
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
      // 拉取失败保留旧数据。
    }
    widget.onChanged();
    if (mounted) await WoScope.of(context).refresh();
  }

  Future<void> _openEditor([RetireDebt? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => DebtEditPage(existing: existing)),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _delete(RetireDebt debt) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除负债'),
        content: Text('确定删除「${debt.name}」吗？'),
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
    final fid = session.currentFamilyId;
    if (fid == null) return;
    try {
      await session.api.deleteRetireDebt(fid, debt.id);
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

  @override
  Widget build(BuildContext context) {
    final cached = _items;
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'retire-add-debt',
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('加负债'),
      ),
      body: cached != null
          ? _buildBody(context, cached)
          : AsyncView<List<RetireDebt>>(
              future: _future,
              onRetry: _retry,
              builder: _buildBody,
            ),
    );
  }

  Widget _buildBody(BuildContext context, List<RetireDebt> all) {
    if (all.isEmpty) return _Empty(onAdd: _openEditor);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        WoTokens.space4,
        WoTokens.space3,
        WoTokens.space4,
        100,
      ),
      itemCount: all.length,
      separatorBuilder: (_, __) => const SizedBox(height: WoTokens.space3),
      itemBuilder: (_, i) => _DebtTile(
        debt: all[i],
        onEdit: () => _openEditor(all[i]),
        onDelete: () => _delete(all[i]),
      ),
    );
  }
}

class _DebtTile extends StatelessWidget {
  const _DebtTile({
    required this.debt,
    required this.onEdit,
    required this.onDelete,
  });

  final RetireDebt debt;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return WoCard(
      onTap: onEdit,
      child: Row(
        children: [
          Text(debt.emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        debt.name,
                        style:
                            t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: WoTokens.space2),
                    _Chip(text: debtKindLabel(debt.kind)),
                    if (!debt.active) ...[
                      const SizedBox(width: WoTokens.space2),
                      _Chip(text: '已还清', highlight: true),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '剩 ${yuan(debt.balance)} · 月供 ${yuan(debt.monthlyPayment)}（${debt.paymentDay} 号）',
                  style: t.labelMedium?.copyWith(color: wo.fgMid),
                ),
              ],
            ),
          ),
          if (debt.creatorName != null || debt.creatorEmoji != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: MemberAvatar(
                url: debt.creatorAvatarUrl,
                emoji: debt.creatorEmoji ?? '👤',
                size: 22,
              ),
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

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.highlight = false});
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: highlight
            ? retireGreen.withValues(alpha: 0.2)
            : wo.retire.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: t.labelSmall?.copyWith(color: highlight ? retireGreen : wo.fg),
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
            const Text('🏠', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有负债', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '记下房贷、车贷这类定时扣款，到日自动减负债、扣存款。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('加第一笔负债')),
          ],
        ),
      ),
    );
  }
}
