import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'expense_categories.dart';

/// 记一笔 / 编辑支出的底部表单。保存成功后 `Navigator.pop(true)`。
Future<bool?> showExpenseEntrySheet(
  BuildContext context, {
  Expense? existing,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ExpenseEntrySheet(existing: existing),
  );
}

class _ExpenseEntrySheet extends StatefulWidget {
  const _ExpenseEntrySheet({this.existing});

  final Expense? existing;

  @override
  State<_ExpenseEntrySheet> createState() => _ExpenseEntrySheetState();
}

class _ExpenseEntrySheetState extends State<_ExpenseEntrySheet> {
  late String _category;
  late final TextEditingController _amount;
  late final TextEditingController _note;
  bool _submitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _category = e?.category ?? expenseCategories.first.code;
    _amount = TextEditingController(
      text: e == null ? '' : _trimAmount(e.amount),
    );
    _note = TextEditingController(text: e?.note ?? '');
  }

  static String _trimAmount(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  double? get _parsedAmount {
    final v = double.tryParse(_amount.text.trim());
    if (v == null || v <= 0) return null;
    return v;
  }

  Future<void> _save() async {
    final amount = _parsedAmount;
    if (amount == null || _submitting) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    final note = _note.text.trim();
    try {
      if (_isEditing) {
        await session.api.updateExpense(
          familyId,
          widget.existing!.id,
          amount: amount,
          category: _category,
          note: note.isEmpty ? null : note,
        );
      } else {
        await session.api.createExpense(
          familyId,
          amount: amount,
          category: _category,
          note: note.isEmpty ? null : note,
        );
      }
      if (mounted) nav.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        _toast(e);
      }
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
    final t = Theme.of(context).textTheme;
    final canSave = _parsedAmount != null && !_submitting;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: wo.bgElev,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(WoTokens.sheetRadius),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          WoTokens.space6,
          WoTokens.space5,
          WoTokens.space6,
          WoTokens.space6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Text(
                _isEditing ? '编辑支出' : '记一笔',
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: WoTokens.space5),
            TextField(
              controller: _amount,
              autofocus: !_isEditing,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              onChanged: (_) => setState(() {}),
              style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                prefixText: '¥ ',
                hintText: '0.00',
                border: InputBorder.none,
              ),
            ),
            const SizedBox(height: WoTokens.space4),
            Text('标签', style: t.titleSmall?.copyWith(color: wo.fgMid)),
            const SizedBox(height: WoTokens.space3),
            Wrap(
              spacing: WoTokens.space2,
              runSpacing: WoTokens.space2,
              children: [
                for (final c in expenseCategories)
                  _CategoryChip(
                    category: c,
                    selected: c.code == _category,
                    onTap: () => setState(() => _category = c.code),
                  ),
              ],
            ),
            const SizedBox(height: WoTokens.space4),
            TextField(
              controller: _note,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: '备注（可选）',
                hintText: '写点什么',
              ),
            ),
            const SizedBox(height: WoTokens.space3),
            FilledButton(
              onPressed: canSave ? _save : null,
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_isEditing ? '保存' : '记下'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final ExpenseCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: WoTokens.space4,
          vertical: WoTokens.space3,
        ),
        decoration: BoxDecoration(
          color: selected ? wo.money : wo.bgTint,
          borderRadius: BorderRadius.circular(WoTokens.chipRadius),
          border: Border.all(
            color: selected ? wo.accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(category.emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: WoTokens.space2),
            Text(
              category.label,
              style: t.labelLarge?.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
