import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import 'accounting_entry_sheet.dart';
import 'expense_categories.dart';

typedef _AccountingData = ({AccountingSummary summary, List<Expense> expenses});

/// 记账主页：本月支出 / 预算概览 + 支出时间线（倒序）。
class AccountingPage extends StatefulWidget {
  const AccountingPage({super.key});

  @override
  State<AccountingPage> createState() => _AccountingPageState();
}

class _AccountingPageState extends State<AccountingPage> {
  late Future<_AccountingData> _future;

  bool _loaded = false;

  // 当前查看的月份，默认进入时为本月。
  late ({int year, int month}) _selected;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selected = (year: now.year, month: now.month);
  }

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _selected.year == now.year && _selected.month == now.month;
  }

  // 首次加载放在 didChangeDependencies 而非 initState：_reload 通过
  // WoScope.of(context) 依赖 InheritedWidget，在 initState 阶段访问会抛异常。
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
        ? Future.value((
            summary: const AccountingSummary(monthTotal: 0),
            expenses: const <Expense>[],
          ),)
        : _load(session, familyId);
  }

  Future<_AccountingData> _load(WoSession session, String familyId) async {
    final summary = await session.api.accountingSummary(
      familyId,
      year: _selected.year,
      month: _selected.month,
    );
    final expenses = await session.api.expenses(
      familyId,
      year: _selected.year,
      month: _selected.month,
    );
    return (summary: summary, expenses: expenses);
  }

  void _selectMonth(({int year, int month}) m) {
    if (m == _selected) return;
    setState(() {
      _selected = m;
      _reload();
    });
  }

  Future<void> _refreshAll() async {
    if (!mounted) return;
    setState(_reload);
    await WoScope.of(context).refresh();
  }

  Future<void> _addExpense() async {
    final changed = await showExpenseEntrySheet(context);
    if (changed == true) await _refreshAll();
  }

  Future<void> _editExpense(Expense e) async {
    final changed = await showExpenseEntrySheet(context, existing: e);
    if (changed == true) await _refreshAll();
  }

  Future<void> _onLongPress(Expense e) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () => Navigator.of(ctx).pop('edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'edit') {
      await _editExpense(e);
    } else if (action == 'delete') {
      await _deleteExpense(e);
    }
  }

  Future<void> _deleteExpense(Expense e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除支出'),
        content: const Text('确定删除这笔支出吗？此操作不可撤销。'),
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
      await session.api.deleteExpense(familyId, e.id);
      await _refreshAll();
    } catch (err) {
      if (mounted) _toast(err);
    }
  }

  Future<void> _editBudget(double? current) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final controller = TextEditingController(
      text: current == null
          ? ''
          : (current == current.roundToDouble()
              ? current.toInt().toString()
              : current.toStringAsFixed(2)),
    );
    final saved = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置每月预算'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          decoration: const InputDecoration(
            prefixText: '¥ ',
            hintText: '比如 5000',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final v = double.tryParse(controller.text.trim());
              if (v != null && v > 0) Navigator.of(ctx).pop(v);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    try {
      await session.api.setBudget(familyId, saved);
      await _refreshAll();
    } catch (err) {
      if (mounted) _toast(err);
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
    final wo = context.wo;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('记账')),
      floatingActionButton: FloatingActionButton(
        onPressed: _addExpense,
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: AsyncView<_AccountingData>(
          future: _future,
          onRetry: () => setState(_reload),
          builder: (context, data) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(
                WoTokens.space4,
                WoTokens.space4,
                WoTokens.space4,
                100,
              ),
              children: [
                _MonthSelector(
                  selected: _selected,
                  onSelect: _selectMonth,
                ),
                const SizedBox(height: WoTokens.space4),
                _SummaryCard(
                  summary: data.summary,
                  monthLabel: _selected.month,
                  isCurrentMonth: _isCurrentMonth,
                  onEditBudget: () => _editBudget(data.summary.budget),
                ),
                const SizedBox(height: WoTokens.space5),
                if (data.expenses.isEmpty)
                  _EmptyExpenses(
                    onAdd: _addExpense,
                    isCurrentMonth: _isCurrentMonth,
                  )
                else ...[
                  for (final e in data.expenses) ...[
                    _ExpenseTile(
                      expense: e,
                      onLongPress: () => _onLongPress(e),
                    ),
                    const SizedBox(height: WoTokens.space3),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

String _money(double v) {
  if (v == v.roundToDouble()) return '¥${v.toInt()}';
  return '¥${v.toStringAsFixed(2)}';
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.summary,
    required this.monthLabel,
    required this.isCurrentMonth,
    required this.onEditBudget,
  });

  final AccountingSummary summary;
  final int monthLabel;
  final bool isCurrentMonth;
  final VoidCallback onEditBudget;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final budget = summary.budget;
    final remaining = summary.remaining;

    Color? remainingColor;
    if (budget != null && budget > 0 && remaining != null) {
      final ratio = remaining / budget;
      if (ratio < 0.1) {
        remainingColor = wo.danger;
      } else if (ratio < 0.4) {
        remainingColor = wo.warning;
      }
    }

    return WoCard(
      color: wo.money,
      padding: const EdgeInsets.all(WoTokens.space6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isCurrentMonth ? '本月支出' : '$monthLabel月支出',
            style: t.labelMedium?.copyWith(color: wo.fgMid),
          ),
          const SizedBox(height: WoTokens.space1),
          Text(
            _money(summary.monthTotal),
            style: t.displaySmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: WoTokens.space4),
          Row(
            children: [
              Expanded(
                child: _StatItem(
                  label: '每月预算',
                  value: budget == null ? '未设置' : _money(budget),
                ),
              ),
              Expanded(
                child: _StatItem(
                  label: isCurrentMonth ? '本月剩余' : '$monthLabel月剩余',
                  value: remaining == null ? '—' : _money(remaining),
                  valueColor: remainingColor,
                ),
              ),
              IconButton(
                tooltip: '设置预算',
                icon: Icon(Icons.tune, color: wo.fgMid),
                onPressed: onEditBudget,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: t.labelSmall?.copyWith(color: wo.fgMid)),
        const SizedBox(height: 2),
        Text(
          value,
          style: t.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

class _ExpenseTile extends StatelessWidget {
  const _ExpenseTile({required this.expense, required this.onLongPress});

  final Expense expense;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final cat = categoryFor(expense.category);
    final who = expense.creatorName ?? '家人';
    final whoEmoji = expense.creatorEmoji ?? '👤';
    final created = expense.createdAt;
    final timeText = created == null ? '' : _timeLabel(created);
    final subtitle = [
      '$whoEmoji $who',
      if (timeText.isNotEmpty) timeText,
      if (expense.note != null && expense.note!.isNotEmpty) expense.note!,
    ].join(' · ');

    return WoCard(
      onLongPress: onLongPress,
      padding: const EdgeInsets.all(WoTokens.space4),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: wo.money,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(cat.emoji, style: const TextStyle(fontSize: 22)),
          ),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cat.label,
                  style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: t.bodySmall?.copyWith(color: wo.fgMid),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: WoTokens.space3),
          Text(
            _money(expense.amount),
            style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  static String _timeLabel(DateTime dt) {
    final now = DateTime.now();
    final isToday =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final hm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (isToday) return '今天 $hm';
    return '${dt.month}月${dt.day}日 $hm';
  }
}

class _EmptyExpenses extends StatelessWidget {
  const _EmptyExpenses({required this.onAdd, required this.isCurrentMonth});
  final VoidCallback onAdd;
  final bool isCurrentMonth;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: WoTokens.space8),
      child: Column(
        children: [
          const Text('💰', style: TextStyle(fontSize: 48)),
          const SizedBox(height: WoTokens.space4),
          Text(isCurrentMonth ? '还没有支出记录' : '这个月没有支出记录', style: t.titleMedium),
          if (isCurrentMonth) ...[
            const SizedBox(height: WoTokens.space2),
            Text(
              '记下家里的第一笔开销吧。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('记一笔')),
          ],
        ],
      ),
    );
  }
}

/// 月份筛选下拉：默认本月，可向前回看最近 12 个月。
class _MonthSelector extends StatelessWidget {
  const _MonthSelector({required this.selected, required this.onSelect});

  static const int _monthsBack = 12;

  final ({int year, int month}) selected;
  final ValueChanged<({int year, int month})> onSelect;

  List<({int year, int month})> _months() {
    final now = DateTime.now();
    // 本月在最前，向前回溯。
    return [
      for (var i = 0; i < _monthsBack; i++)
        (
          year: DateTime(now.year, now.month - i, 1).year,
          month: DateTime(now.year, now.month - i, 1).month,
        ),
    ];
  }

  String _label(({int year, int month}) m) => '${m.year}年${m.month}月';

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: WoTokens.space3),
        decoration: BoxDecoration(
          color: wo.bgElev,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: wo.hairline),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<({int year, int month})>(
            value: selected,
            isDense: true,
            borderRadius: BorderRadius.circular(12),
            icon: Icon(Icons.keyboard_arrow_down, color: wo.fgMid),
            style: t.titleSmall?.copyWith(
              color: wo.fg,
              fontWeight: FontWeight.w600,
            ),
            items: [
              for (final m in _months())
                DropdownMenuItem(value: m, child: Text(_label(m))),
            ],
            onChanged: (m) {
              if (m != null) onSelect(m);
            },
          ),
        ),
      ),
    );
  }
}
