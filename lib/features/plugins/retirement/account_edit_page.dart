import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'retirement_common.dart';

/// 账户新增 / 编辑页。[existing] 为空 = 新增。保存成功后 `Navigator.pop(true)`。
class AccountEditPage extends StatefulWidget {
  const AccountEditPage({super.key, this.existing});

  final RetireAccount? existing;

  @override
  State<AccountEditPage> createState() => _AccountEditPageState();
}

class _AccountEditPageState extends State<AccountEditPage> {
  late String _kind;
  late final TextEditingController _name;
  late final TextEditingController _balance;
  late final TextEditingController _income;
  late int _incomeDay;

  bool _submitting = false;
  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final a = widget.existing;
    _kind = a?.kind ?? 'deposit';
    _name = TextEditingController(text: a?.name ?? '');
    _balance = TextEditingController(text: _numText(a?.balance));
    _income = TextEditingController(
      text: (a != null && a.monthlyIncome > 0) ? _numText(a.monthlyIncome) : '',
    );
    _incomeDay = a?.incomeDay ?? 10;
  }

  static String _numText(double? v) {
    if (v == null) return '';
    return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    _income.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;

    final balance = double.tryParse(_balance.text.trim()) ?? 0;
    final income = double.tryParse(_income.text.trim()) ?? 0;

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      if (_isEditing) {
        await session.api.updateRetireAccount(
          fid,
          widget.existing!.id,
          name: name,
          kind: _kind,
          emoji: accountKindEmoji(_kind),
          balance: balance,
          monthlyIncome: income,
          incomeDay: _incomeDay,
        );
      } else {
        await session.api.createRetireAccount(
          fid,
          name: name,
          kind: _kind,
          emoji: accountKindEmoji(_kind),
          balance: balance,
          monthlyIncome: income,
          incomeDay: _incomeDay,
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
    final hasIncome = (double.tryParse(_income.text.trim()) ?? 0) > 0;

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: Text(_isEditing ? '编辑账户' : '加账户')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: WoTokens.space2,
                children: [
                  for (final k in accountKinds)
                    ChoiceChip(
                      label:
                          Text('${accountKindEmoji(k)} ${accountKindLabel(k)}'),
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
                  labelText: '账户名称',
                  hintText: '比如「工资卡」「住房公积金」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              TextField(
                controller: _balance,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: '当前余额',
                  prefixText: '¥ ',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              TextField(
                controller: _income,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '每月固定收入（可选）',
                  hintText: '留空表示该账户没有固定进账',
                  prefixText: '¥ ',
                ),
              ),
              if (hasIncome) ...[
                const SizedBox(height: WoTokens.space3),
                Row(
                  children: [
                    Text('每月入账日', style: t.bodyMedium),
                    const Spacer(),
                    DropdownButton<int>(
                      value: _incomeDay,
                      items: [
                        for (var d = 1; d <= 28; d++)
                          DropdownMenuItem(value: d, child: Text('$d 号')),
                      ],
                      onChanged: (v) =>
                          setState(() => _incomeDay = v ?? _incomeDay),
                    ),
                  ],
                ),
                Text(
                  '到这天自动把月收入计入余额，并记一条流水。',
                  style: t.labelSmall?.copyWith(color: wo.fgDim),
                ),
              ],
              const SizedBox(height: WoTokens.space5),
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
