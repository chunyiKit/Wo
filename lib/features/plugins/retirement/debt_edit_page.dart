import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'retirement_common.dart';

/// 负债新增 / 编辑页。[existing] 为空 = 新增。保存成功后 `Navigator.pop(true)`。
class DebtEditPage extends StatefulWidget {
  const DebtEditPage({super.key, this.existing});

  final RetireDebt? existing;

  @override
  State<DebtEditPage> createState() => _DebtEditPageState();
}

class _DebtEditPageState extends State<DebtEditPage> {
  late String _kind;
  late final TextEditingController _name;
  late final TextEditingController _balance;
  late final TextEditingController _payment;
  late int _paymentDay;
  String? _fromAccountId;
  late bool _active;

  List<RetireAccount> _accounts = const [];
  bool _submitting = false;
  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    _kind = d?.kind ?? 'mortgage';
    _name = TextEditingController(text: d?.name ?? '');
    _balance = TextEditingController(text: _numText(d?.balance));
    _payment = TextEditingController(text: _numText(d?.monthlyPayment));
    _paymentDay = d?.paymentDay ?? 5;
    _fromAccountId = d?.fromAccountId;
    _active = d?.active ?? true;
    _loadAccounts();
  }

  static String _numText(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  }

  Future<void> _loadAccounts() async {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;
    try {
      final list = await session.api.retireAccounts(fid);
      if (!mounted) return;
      setState(() {
        _accounts = list;
        // 关联的账户若已被删，回退到「不关联」。
        if (_fromAccountId != null &&
            !list.any((a) => a.id == _fromAccountId)) {
          _fromAccountId = null;
        }
      });
    } catch (_) {
      // 拉不到账户就只显示「不关联」。
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    _payment.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;

    final balance = double.tryParse(_balance.text.trim()) ?? 0;
    final payment = double.tryParse(_payment.text.trim()) ?? 0;

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      if (_isEditing) {
        await session.api.updateRetireDebt(
          fid,
          widget.existing!.id,
          name: name,
          kind: _kind,
          emoji: debtKindEmoji(_kind),
          balance: balance,
          monthlyPayment: payment,
          paymentDay: _paymentDay,
          fromAccountId: _fromAccountId,
          active: _active,
        );
      } else {
        await session.api.createRetireDebt(
          fid,
          name: name,
          kind: _kind,
          emoji: debtKindEmoji(_kind),
          balance: balance,
          monthlyPayment: payment,
          paymentDay: _paymentDay,
          fromAccountId: _fromAccountId,
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
    final canSave = _name.text.trim().isNotEmpty && !_submitting;

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: Text(_isEditing ? '编辑负债' : '加负债')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: WoTokens.space2,
                children: [
                  for (final k in debtKinds)
                    ChoiceChip(
                      label: Text('${debtKindEmoji(k)} ${debtKindLabel(k)}'),
                      selected: _kind == k,
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                ],
              ),
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _name,
                maxLength: 40,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '负债名称',
                  hintText: '比如「商贷」「车贷」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              TextField(
                controller: _balance,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: '剩余欠款',
                  prefixText: '¥ ',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              TextField(
                controller: _payment,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: '每月月供',
                  prefixText: '¥ ',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              Row(
                children: [
                  Text('每月扣款日', style: t.bodyMedium),
                  const Spacer(),
                  DropdownButton<int>(
                    value: _paymentDay,
                    items: [
                      for (var d = 1; d <= 28; d++)
                        DropdownMenuItem(value: d, child: Text('$d 号')),
                    ],
                    onChanged: (v) =>
                        setState(() => _paymentDay = v ?? _paymentDay),
                  ),
                ],
              ),
              const SizedBox(height: WoTokens.space2),
              Row(
                children: [
                  Expanded(child: Text('从哪个账户扣款', style: t.bodyMedium)),
                  DropdownButton<String?>(
                    value: _fromAccountId,
                    hint: const Text('不关联'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('不关联'),
                      ),
                      for (final a in _accounts)
                        DropdownMenuItem<String?>(
                          value: a.id,
                          child: Text('${a.emoji} ${a.name}'),
                        ),
                    ],
                    onChanged: (v) => setState(() => _fromAccountId = v),
                  ),
                ],
              ),
              Text(
                '到扣款日自动减少这笔负债；关联账户时同时从该账户扣除并记流水。',
                style: t.labelSmall?.copyWith(color: wo.fgDim),
              ),
              if (_isEditing) ...[
                const SizedBox(height: WoTokens.space2),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用自动扣款'),
                  subtitle: const Text('关闭后这笔负债不再自动扣款'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              ],
              const SizedBox(height: WoTokens.space4),
              FilledButton(
                onPressed: canSave ? _save : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isEditing ? '保存' : '添加'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
