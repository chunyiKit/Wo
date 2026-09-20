import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/wo_card.dart';
import 'expense_categories.dart';

class CategoryExpenseBreakdown {
  const CategoryExpenseBreakdown({
    required this.category,
    required this.amount,
    required this.count,
    required this.fraction,
  });

  final ExpenseCategory category;
  final double amount;
  final int count;
  final double fraction;
}

/// 按家庭分类顺序汇总支出；未知分类统一归入「其他」。
List<CategoryExpenseBreakdown> buildCategoryExpenseBreakdown(
  List<Expense> expenses, {
  List<ExpenseCategory> categories = expenseCategories,
}) {
  final totals = <String, double>{};
  final counts = <String, int>{};
  final knownCodes = categories.map((item) => item.code).toSet();
  for (final expense in expenses) {
    final code =
        knownCodes.contains(expense.category) ? expense.category : 'other';
    totals.update(
      code,
      (value) => value + expense.amount,
      ifAbsent: () => expense.amount,
    );
    counts.update(code, (value) => value + 1, ifAbsent: () => 1);
  }
  final total = totals.values.fold<double>(0, (sum, value) => sum + value);
  if (total <= 0) return const [];
  const other = ExpenseCategory('other', '其他', '💰');
  final allCategories = [...categories, other];
  return [
    for (final category in allCategories)
      if ((totals[category.code] ?? 0) > 0)
        CategoryExpenseBreakdown(
          category: category,
          amount: totals[category.code]!,
          count: counts[category.code]!,
          fraction: totals[category.code]! / total,
        ),
  ];
}

class AccountingAnalysisView extends StatefulWidget {
  const AccountingAnalysisView({
    super.key,
    required this.expenses,
    this.categories = expenseCategories,
    required this.expenseBuilder,
  });

  final List<Expense> expenses;
  final List<ExpenseCategory> categories;
  final Widget Function(Expense expense) expenseBuilder;

  @override
  State<AccountingAnalysisView> createState() => _AccountingAnalysisViewState();
}

class _AccountingAnalysisViewState extends State<AccountingAnalysisView> {
  String? _selectedCategory;

  @override
  void didUpdateWidget(covariant AccountingAnalysisView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = _selectedCategory;
    if (selected != null &&
        !buildCategoryExpenseBreakdown(
          widget.expenses,
          categories: widget.categories,
        ).any((item) => item.category.code == selected)) {
      _selectedCategory = null;
    }
  }

  bool _matches(Expense expense, String category) {
    if (category != 'other') return expense.category == category;
    return !widget.categories.any((item) => item.code == expense.category);
  }

  @override
  Widget build(BuildContext context) {
    final breakdown = buildCategoryExpenseBreakdown(
      widget.expenses,
      categories: widget.categories,
    );
    if (breakdown.isEmpty) return const _EmptyAnalysis();
    final selected = _selectedCategory;
    final filtered = selected == null
        ? widget.expenses
        : widget.expenses
            .where((expense) => _matches(expense, selected))
            .toList();
    final total = breakdown.fold<double>(0, (sum, item) => sum + item.amount);
    final t = Theme.of(context).textTheme;
    final wo = context.wo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WoCard(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '分类占比',
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: WoTokens.space5),
              Center(
                child: Semantics(
                  label: '分类支出饼图，总支出${_money(total)}',
                  image: true,
                  child: SizedBox.square(
                    dimension: 180,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          key: const ValueKey('accounting-analysis-pie'),
                          size: const Size.square(180),
                          painter: _ExpensePiePainter(breakdown),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '总支出',
                              style: t.labelMedium?.copyWith(color: wo.fgMid),
                            ),
                            const SizedBox(height: WoTokens.space1),
                            Text(
                              _money(total),
                              style: t.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: WoTokens.space5),
              for (var index = 0; index < breakdown.length; index++) ...[
                _CategoryLegendRow(
                  item: breakdown[index],
                  color: _categoryColor(breakdown[index].category.code),
                ),
                if (index != breakdown.length - 1)
                  const SizedBox(height: WoTokens.space3),
              ],
            ],
          ),
        ),
        const SizedBox(height: WoTokens.space5),
        Row(
          children: [
            Text(
              '分类明细',
              style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            Text(
              '${filtered.length} 笔',
              style: t.bodySmall?.copyWith(color: wo.fgMid),
            ),
          ],
        ),
        const SizedBox(height: WoTokens.space3),
        Wrap(
          spacing: WoTokens.space2,
          runSpacing: WoTokens.space2,
          children: [
            WoChoiceChip(
              key: const ValueKey('analysis-category-all'),
              label: const Text('全部'),
              selected: selected == null,
              onSelected: (_) => setState(() => _selectedCategory = null),
            ),
            for (final item in breakdown)
              WoChoiceChip(
                key: ValueKey('analysis-category-${item.category.code}'),
                avatar: Text(item.category.emoji),
                label: Text(item.category.label),
                selected: selected == item.category.code,
                onSelected: (_) =>
                    setState(() => _selectedCategory = item.category.code),
              ),
          ],
        ),
        const SizedBox(height: WoTokens.space4),
        for (var index = 0; index < filtered.length; index++) ...[
          widget.expenseBuilder(filtered[index]),
          if (index != filtered.length - 1)
            const SizedBox(height: WoTokens.space3),
        ],
      ],
    );
  }
}

class _CategoryLegendRow extends StatelessWidget {
  const _CategoryLegendRow({required this.item, required this.color});

  final CategoryExpenseBreakdown item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final wo = context.wo;
    return Semantics(
      label:
          '${item.category.label}，${_money(item.amount)}，${_percent(item.fraction)}，${item.count}笔',
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: WoTokens.space2),
          Text(item.category.emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: WoTokens.space2),
          Expanded(
            child: Text(
              item.category.label,
              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: WoTokens.space3),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _money(item.amount),
                style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                '${item.count}笔 · ${_percent(item.fraction)}',
                style: t.bodySmall?.copyWith(color: wo.fgMid),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyAnalysis extends StatelessWidget {
  const _EmptyAnalysis();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final wo = context.wo;
    return WoCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WoTokens.space5,
        vertical: WoTokens.space8,
      ),
      child: Center(
        child: Column(
          children: [
            const Icon(Icons.pie_chart_outline, size: 42),
            const SizedBox(height: WoTokens.space3),
            Text('这个月暂无分析数据', style: t.titleMedium),
            const SizedBox(height: WoTokens.space1),
            Text(
              '记下一笔支出后，这里会展示分类占比。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpensePiePainter extends CustomPainter {
  const _ExpensePiePainter(this.items);

  final List<CategoryExpenseBreakdown> items;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 20;
    final rect = Rect.fromCircle(center: center, radius: radius);
    var start = -math.pi / 2;
    for (final item in items) {
      final sweep = math.pi * 2 * item.fraction;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..color = _categoryColor(item.category.code)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 34
          ..strokeCap = StrokeCap.butt,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _ExpensePiePainter oldDelegate) => true;
}

Color _categoryColor(String code) => switch (code) {
      'dining' => const Color(0xFFE8895A),
      'snack' => const Color(0xFFF0B35C),
      'shopping' => const Color(0xFFB989B5),
      'utilities' => const Color(0xFFE1BC48),
      'car' => const Color(0xFF6F9FB3),
      'pet' => const Color(0xFFC982A8),
      'subscription' => const Color(0xFF7E86B8),
      'other' => const Color(0xFF9A9085),
      _ => const [
          Color(0xFFB66A4E),
          Color(0xFF5D8B88),
          Color(0xFF8C79A8),
          Color(0xFFB49A50),
          Color(0xFF6D8A58),
          Color(0xFFAC7390),
        ][code.codeUnits
                .fold<int>(0, (hash, unit) => (hash * 31 + unit) & 0x7fffffff) %
            6],
    };

String _money(double value) {
  if (value == value.roundToDouble()) return '¥${value.toInt()}';
  return '¥${value.toStringAsFixed(2)}';
}

String _percent(double value) => '${(value * 100).toStringAsFixed(1)}%';
