import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'retirement_common.dart';
import 'finance_ui_support.dart';

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
  final _requestKey = FinanceRequestKey();
  String? _reviewFrontier, _latestBalanceText;
  bool _recordChanged = false;
  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final a = widget.existing;
    _reviewFrontier = a?.conflictFrontier;
    _kind = a?.kind ?? 'deposit';
    _name = TextEditingController(text: a?.name ?? '');
    _balance = TextEditingController(text: a?.balanceConflict == true || a?.settlementConflict == true ? '' : (a?.balanceText ?? _numText(a?.balance)));
    _income = TextEditingController(
      text: (a != null && a.monthlyIncome > 0) ? (a.monthlyIncomeText ?? _numText(a.monthlyIncome)) : '',
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

    String balanceText, incomeText;
    try { balanceText = financeAmount(_balance.text, negative: true); incomeText = financeAmount(_income.text, emptyZero: true); }
    on FormatException catch (error) { _toast(error); return; }
    final balance = double.parse(balanceText), income = double.parse(incomeText);

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      var preserveBalance = false;
      String? expectedFrontier;
      if (session.api.isLocal && _isEditing) {
        final currentRows = (await session.api.retireAccounts(fid)).where((row) => row.id == widget.existing!.id).toList();
        if (currentRows.isEmpty) throw ApiException('NOT_FOUND', '此记录已删除，请返回列表', statusCode: 404);
        final current = currentRows.single;
        expectedFrontier = current.conflictFrontier;
        final original = financeAmount(widget.existing!.balanceText ?? _numText(widget.existing!.balance), negative: true);
        final needsReview = current.balanceConflict || current.settlementConflict || widget.existing!.balanceConflict || widget.existing!.settlementConflict || _recordChanged || balanceText != original;
        preserveBalance = !needsReview;
        if (needsReview) {
          if (expectedFrontier == null) throw ApiException('LOCAL_FINANCIAL_CONFLICT', '请重新读取完整记录后核对', statusCode: 409);
          if (expectedFrontier != _reviewFrontier) {
            if (mounted) {
              setState(() { _reviewFrontier = expectedFrontier; _recordChanged = true;
                _latestBalanceText = current.balanceText ?? _numText(current.balance); _balance.clear(); _submitting = false; });
              _toast(ApiException('LOCAL_FINANCIAL_CONFLICT', '记录有变化，请查看最新账面，再填写实际金额确认', statusCode: 409));
            }
            return;
          }
          if (!mounted) return;
          final confirmed = await showWoDialog<bool>(context: context, builder: (ctx) => WoAlertDialog(
            title: const Text('确认实际余额'),
            content: Text('请先核对实际账户余额，确认将「$name」记为 ¥$balanceText。既有流水会保留。'),
            actions: [WoTextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('继续核对')),
              WoFilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('已核对，确认金额'))]));
          if (confirmed != true || !mounted) { if (mounted) setState(() => _submitting = false); return; }
        }
      }
      final clientId = session.api.isLocal ? _requestKey.forBody([fid, widget.existing?.id, name, _kind, balanceText,
        incomeText, _incomeDay, preserveBalance, expectedFrontier]) : null;
      if (_isEditing) {
        await session.api.updateRetireAccount(
          fid,
          widget.existing!.id,
          name: name,
          kind: _kind,
          emoji: accountKindEmoji(_kind),
          balance: balance,
          monthlyIncome: income, balanceText: balanceText, monthlyIncomeText: incomeText, clientId: clientId,
          incomeDay: _incomeDay, preserveBalance: preserveBalance, expectedConflictFrontier: expectedFrontier,
        );
      } else {
        await session.api.createRetireAccount(
          fid,
          name: name,
          kind: _kind,
          emoji: accountKindEmoji(_kind),
          balance: balance,
          monthlyIncome: income, balanceText: balanceText, monthlyIncomeText: incomeText, clientId: clientId,
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
      FormatException e => e.message,
      NetworkException e => e.message,
      _ => '操作失败',
    };
    ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final canSave = _name.text.trim().isNotEmpty && !_submitting;
    final hasIncome = (double.tryParse(_income.text.trim()) ?? 0) > 0;

    return WoScaffold(
      backgroundColor: wo.bg,
      appBar: WoAppBar(title: Text(_isEditing ? '编辑账户' : '加账户')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_recordChanged) ...[
                Text('记录已更新，当前账面金额：¥${_latestBalanceText ?? ''}。请重新核对实际金额后填写。', style: t.bodyMedium?.copyWith(color: wo.warning)),
                const SizedBox(height: WoTokens.space3),
              ],
              if (widget.existing?.balanceConflict == true || widget.existing?.settlementConflict == true) ...[
                Text('存在待核对财务记录。请填写实际金额，保存前需明确确认；不会删除历史流水。', style: t.bodyMedium?.copyWith(color: wo.warning)),
                const SizedBox(height: WoTokens.space3),
              ],
              if (WoScope.api(context).isLocal) const LocalFinanceStatus(),
              Wrap(
                spacing: WoTokens.space2,
                children: [
                  for (final k in accountKinds)
                    WoChoiceChip(
                      label: Text(
                        '${accountKindEmoji(k)} ${accountKindLabel(k)}',
                      ),
                      selected: _kind == k,
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                ],
              ),
              const SizedBox(height: WoTokens.space3),
              WoTextField(
                controller: _name,
                maxLength: 40,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '账户名称',
                  hintText: '比如「工资卡」「住房公积金」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              WoTextField(
                controller: _balance,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: '当前余额',
                  prefixText: '¥ ',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              WoTextField(
                controller: _income,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
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
                    WoDropdownButton<int>(
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
                  WoScope.api(context).isLocal ? '打开 App 时按本月入账日记录收入并写入流水。' : '到这天自动把月收入计入余额，并记一条流水。',
                  style: t.labelSmall?.copyWith(color: wo.fgDim),
                ),
              ],
              const SizedBox(height: WoTokens.space5),
              WoFilledButton(
                onPressed: canSave ? _save : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: WoProgressIndicator(strokeWidth: 2),
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
