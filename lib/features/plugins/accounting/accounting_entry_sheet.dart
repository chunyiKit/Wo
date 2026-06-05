import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'expense_categories.dart';

/// 记一笔 / 编辑支出的底部表单。保存成功后 `Navigator.pop(true)`。
///
/// [draft] 用于「拍小票」识别后预填金额 / 分类 / 备注（仅新增时生效），
/// 用户仍可在保存前修改。
Future<bool?> showExpenseEntrySheet(
  BuildContext context, {
  Expense? existing,
  ReceiptDraft? draft,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ExpenseEntrySheet(existing: existing, draft: draft),
  );
}

class _ExpenseEntrySheet extends StatefulWidget {
  const _ExpenseEntrySheet({this.existing, this.draft});

  final Expense? existing;
  final ReceiptDraft? draft;

  @override
  State<_ExpenseEntrySheet> createState() => _ExpenseEntrySheetState();
}

class _ExpenseEntrySheetState extends State<_ExpenseEntrySheet> {
  late String _category;
  late final TextEditingController _note;
  late final FocusNode _noteFocus;
  bool _submitting = false;

  // 计算器状态：金额输入不再调起系统输入法，由下方自绘键盘驱动。
  // _input  当前正在输入的操作数（字符串，允许带 `.`）。
  // _acc    已确定的累加值；按下运算符后从 _input 折叠到这里。
  // _op     挂起的运算符（`+` `−` `×` `÷` 之一）。
  // _justComputed  按 `=` 后置为 true，下一次按数字会覆盖 _input。
  // _calcError     非空时键盘进入错误态（如 ÷0），AC/⌫ 可清除。
  String _input = '';
  double? _acc;
  String? _op;
  bool _justComputed = false;
  String? _calcError;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    // 拍小票草稿仅在新增时预填；分类要落在内置标签里才采用，否则回退到默认。
    final d = e == null ? widget.draft : null;
    final draftCat = d != null && expenseCategories.any((c) => c.code == d.category)
        ? d.category
        : null;
    _category = e?.category ?? draftCat ?? expenseCategories.first.code;
    _input = e != null
        ? _trimAmount(e.amount)
        : (d?.amount != null ? _trimAmount(d!.amount!) : '');
    _note = TextEditingController(text: e?.note ?? d?.note ?? '');
    _noteFocus = FocusNode();
    _noteFocus.addListener(_onNoteFocusChange);
  }

  void _onNoteFocusChange() {
    if (mounted) setState(() {});
  }

  static String _trimAmount(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _note.dispose();
    _noteFocus.removeListener(_onNoteFocusChange);
    _noteFocus.dispose();
    super.dispose();
  }

  double? _compute(double a, double b, String op) {
    switch (op) {
      case '+':
        return a + b;
      case '−':
        return a - b;
      case '×':
        return a * b;
      case '÷':
        return b == 0 ? null : a / b;
    }
    return null;
  }

  /// 把任意 double 渲染为最短的展示形式（去掉无意义的尾零）。
  String _fmtNum(double v) {
    if (v == v.roundToDouble() && v.abs() < 1e12) return v.toInt().toString();
    var s = v.toStringAsFixed(2);
    if (s.endsWith('0')) s = s.substring(0, s.length - 1);
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  /// 算式区显示的文本（含挂起的累加值与运算符）。
  String get _displayText {
    if (_calcError != null) return _calcError!;
    final parts = <String>[];
    if (_acc != null) parts.add(_fmtNum(_acc!));
    if (_op != null) parts.add(_op!);
    if (_input.isNotEmpty) parts.add(_input);
    if (parts.isEmpty) return '0';
    return parts.join(' ');
  }

  /// 提交时取的最终金额：自动收尾挂起的运算符。
  double? get _finalAmount {
    if (_calcError != null) return null;
    final cur = _input.isEmpty ? null : double.tryParse(_input);
    double? result;
    if (_acc != null && _op != null && cur != null) {
      result = _compute(_acc!, cur, _op!);
    } else if (cur != null) {
      result = cur;
    } else if (_acc != null) {
      // 「12 +」未完成的表达式，按 12 处理。
      result = _acc;
    }
    if (result == null) return null;
    final rounded = (result * 100).round() / 100;
    if (rounded <= 0) return null;
    return rounded;
  }

  void _press(String k) {
    HapticFeedback.selectionClick();
    // 用户开始操作计算键盘时，主动收起备注的系统键盘，避免互相遮挡。
    if (_noteFocus.hasFocus) _noteFocus.unfocus();
    setState(() {
      if (_calcError != null) {
        // 错误态下仅接受 AC / ⌫，用于清除错误后重新输入。
        if (k == 'AC' || k == '⌫') {
          _input = '';
          _acc = null;
          _op = null;
          _justComputed = false;
          _calcError = null;
        }
        return;
      }
      switch (k) {
        case 'AC':
          _input = '';
          _acc = null;
          _op = null;
          _justComputed = false;
          break;
        case '⌫':
          if (_justComputed) {
            // 「=」之后按退格，整段清空（因为继续编辑结果意义不大）。
            _input = '';
            _justComputed = false;
            break;
          }
          if (_input.isNotEmpty) {
            _input = _input.substring(0, _input.length - 1);
          } else if (_op != null) {
            _op = null;
          } else if (_acc != null) {
            _acc = null;
          }
          break;
        case '+':
        case '−':
        case '×':
        case '÷':
          _justComputed = false;
          final cur = _input.isEmpty ? null : double.tryParse(_input);
          if (cur != null) {
            if (_acc != null && _op != null) {
              final r = _compute(_acc!, cur, _op!);
              if (r == null) {
                _calcError = '÷ 0 错误';
                _acc = null;
                _op = null;
                _input = '';
                break;
              }
              _acc = r;
            } else {
              _acc = cur;
            }
            _input = '';
          }
          // 无任何操作数时按运算符直接忽略。
          if (_acc != null) _op = k;
          break;
        case '=':
          final cur = _input.isEmpty ? null : double.tryParse(_input);
          if (_acc != null && _op != null && cur != null) {
            final r = _compute(_acc!, cur, _op!);
            if (r == null) {
              _calcError = '÷ 0 错误';
              _acc = null;
              _op = null;
              _input = '';
              break;
            }
            _input = _fmtResult(r);
            _acc = null;
            _op = null;
            _justComputed = true;
          }
          break;
        case '·':
          if (_justComputed) {
            _input = '';
            _justComputed = false;
          }
          if (_input.contains('.')) break;
          _input = _input.isEmpty ? '0.' : '$_input.';
          break;
        default:
          // 0-9
          if (_justComputed) {
            _input = '';
            _justComputed = false;
          }
          if (_input.contains('.')) {
            final dotIdx = _input.indexOf('.');
            // 小数最多两位。
            if (_input.length - dotIdx - 1 >= 2) break;
          } else if (_input.length >= 8) {
            // 整数最多 8 位。
            break;
          }
          if (_input == '0') {
            // 避免出现 「012」 之类的多余前导零。
            _input = k;
          } else {
            _input += k;
          }
      }
    });
  }

  String _fmtResult(double v) {
    final rounded = (v * 100).round() / 100;
    if (rounded == rounded.roundToDouble() && rounded.abs() < 1e12) {
      return rounded.toInt().toString();
    }
    var s = rounded.toStringAsFixed(2);
    if (s.endsWith('0')) s = s.substring(0, s.length - 1);
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  Future<void> _save() async {
    final amount = _finalAmount;
    if (amount == null || _submitting) return;
    _noteFocus.unfocus();
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
    final canSave = _finalAmount != null && !_submitting;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final screenH = MediaQuery.of(context).size.height;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        // 限制最大高度，留出顶部状态栏余量；超出部分由内部滚动区承担。
        constraints: BoxConstraints(maxHeight: screenH - 80),
        child: Container(
          decoration: BoxDecoration(
            color: wo.bgElev,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(WoTokens.sheetRadius),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    WoTokens.space6,
                    WoTokens.space5,
                    WoTokens.space6,
                    WoTokens.space4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Center(
                        child: Text(
                          _isEditing ? '编辑支出' : '记一笔',
                          style: t.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(height: WoTokens.space5),
                      _AmountDisplay(
                        text: _displayText,
                        isError: _calcError != null,
                        onTap: () => _noteFocus.unfocus(),
                      ),
                      const SizedBox(height: WoTokens.space4),
                      Text(
                        '标签',
                        style: t.titleSmall?.copyWith(color: wo.fgMid),
                      ),
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
                        focusNode: _noteFocus,
                        maxLength: 200,
                        decoration: const InputDecoration(
                          labelText: '备注（可选）',
                          hintText: '写点什么',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _CalcKeypad(
                onKey: _press,
                onSave: canSave ? _save : null,
                saving: _submitting,
                isEditing: _isEditing,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 金额展示区：不弹系统键盘，只渲染当前算式 + 错误提示。
class _AmountDisplay extends StatelessWidget {
  const _AmountDisplay({
    required this.text,
    required this.isError,
    required this.onTap,
  });

  final String text;
  final bool isError;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: WoTokens.space3),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: wo.hairline, width: 1)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              '¥',
              style: t.headlineSmall?.copyWith(
                color: wo.fgMid,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: WoTokens.space2),
            Expanded(
              child: FittedBox(
                alignment: Alignment.centerLeft,
                fit: BoxFit.scaleDown,
                child: Text(
                  text,
                  maxLines: 1,
                  style: t.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isError ? wo.danger : wo.fg,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自绘计算键盘 —— 5 行 × 4 列，最后一列底部两格合并为「完成 / 保存」。
class _CalcKeypad extends StatelessWidget {
  const _CalcKeypad({
    required this.onKey,
    required this.onSave,
    required this.saving,
    required this.isEditing,
  });

  final void Function(String key) onKey;
  final VoidCallback? onSave;
  final bool saving;
  final bool isEditing;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: BoxDecoration(
        color: wo.bgTint,
        border: Border(top: BorderSide(color: wo.hairline, width: 1)),
      ),
      padding: EdgeInsets.fromLTRB(
        WoTokens.space2,
        WoTokens.space2,
        WoTokens.space2,
        WoTokens.space2 + safeBottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row([_k('AC'), _k('÷'), _k('×'), _k('⌫')]),
          _row([_k('7'), _k('8'), _k('9'), _k('−')]),
          _row([_k('4'), _k('5'), _k('6'), _k('+')]),
          _row([_k('1'), _k('2'), _k('3'), _k('=')]),
          _row([
            _k('0', flex: 2),
            _k('·'),
            _SaveKey(onTap: onSave, saving: saving, isEditing: isEditing),
          ]),
        ],
      ),
    );
  }

  static const _digits = {
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    '·',
  };
  static const _utils = {'AC', '⌫'};

  Widget _row(List<Widget> children) => Row(children: children);

  Widget _k(String label, {int flex = 1}) {
    final kind = _digits.contains(label)
        ? _KeyKind.digit
        : _utils.contains(label)
            ? _KeyKind.util
            : _KeyKind.op;
    return _CalcKey(
      label: label,
      kind: kind,
      flex: flex,
      onTap: () => onKey(label),
    );
  }
}

enum _KeyKind { digit, op, util }

class _CalcKey extends StatelessWidget {
  const _CalcKey({
    required this.label,
    required this.kind,
    required this.onTap,
    this.flex = 1,
  });

  final String label;
  final _KeyKind kind;
  final VoidCallback onTap;
  final int flex;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final (bg, fg) = switch (kind) {
      _KeyKind.digit => (wo.bgElev, wo.fg),
      _KeyKind.op => (wo.bgElev, wo.accentDeep),
      _KeyKind.util => (wo.bgElev, wo.fgMid),
    };
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          height: 52,
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Center(
                child: label == '⌫'
                    ? Icon(Icons.backspace_outlined, color: fg, size: 22)
                    : Text(
                        label,
                        style: t.titleLarge?.copyWith(
                          color: fg,
                          fontWeight: kind == _KeyKind.digit
                              ? FontWeight.w600
                              : FontWeight.w700,
                          fontSize: kind == _KeyKind.util ? 16 : 22,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SaveKey extends StatelessWidget {
  const _SaveKey({
    required this.onTap,
    required this.saving,
    required this.isEditing,
  });

  final VoidCallback? onTap;
  final bool saving;
  final bool isEditing;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final enabled = onTap != null;
    final bg = enabled ? wo.accent : wo.bgElev;
    final fg = enabled ? Colors.white : wo.fgDim;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          height: 52,
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Center(
                child: saving
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(fg),
                        ),
                      )
                    : Text(
                        isEditing ? '保存' : '完成',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: fg,
                        ),
                      ),
              ),
            ),
          ),
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
