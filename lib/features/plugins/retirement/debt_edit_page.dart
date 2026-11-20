import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'retirement_common.dart';
import 'finance_ui_support.dart';

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
  final _requestKey = FinanceRequestKey();
  String? _reviewFrontier, _latestBalanceText;
  bool _recordChanged = false;
  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final d = widget.existing;
    _reviewFrontier = d?.conflictFrontier;
    _kind = d?.kind ?? 'mortgage';
    _name = TextEditingController(text: d?.name ?? '');
    _balance = TextEditingController(text: d?.balanceConflict == true ? '' : (d?.balanceText ?? _numText(d?.balance)));
    _payment = TextEditingController(text: d?.monthlyPaymentText ?? _numText(d?.monthlyPayment));
    _paymentDay = d?.paymentDay ?? 5;
    _fromAccountId = d?.fromAccountId;
    _active = d?.active ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadAccounts();
    });
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

    String balanceText, paymentText;
    try { balanceText = financeAmount(_balance.text); paymentText = financeAmount(_payment.text, emptyZero: true); }
    on FormatException catch (error) { _toast(error); return; }
    final balance = double.parse(balanceText), payment = double.parse(paymentText);

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      var preserveBalance = false;
      String? expectedFrontier;
      if (session.api.isLocal && _isEditing) {
        final currentRows = (await session.api.retireDebts(fid)).where((row) => row.id == widget.existing!.id).toList();
        if (currentRows.isEmpty) throw ApiException('NOT_FOUND', '此记录已删除，请返回列表', statusCode: 404);
        final current = currentRows.single;
        expectedFrontier = current.conflictFrontier;
        final original = financeAmount(widget.existing!.balanceText ?? _numText(widget.existing!.balance), negative: true);
        final needsReview = current.balanceConflict || widget.existing!.balanceConflict || _recordChanged || balanceText != original;
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
            title: const Text('确认实际欠款'),
            content: Text('请先核对实际剩余欠款，确认将「$name」记为 ¥$balanceText。既有流水会保留。'),
            actions: [WoTextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('继续核对')),
              WoFilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('已核对，确认金额'))]));
          if (confirmed != true || !mounted) { if (mounted) setState(() => _submitting = false); return; }
        }
      }
      final clientId = session.api.isLocal ? _requestKey.forBody([fid, widget.existing?.id, name, _kind, balanceText,
        paymentText, _paymentDay, _fromAccountId, _active, preserveBalance, expectedFrontier]) : null;
      if (_isEditing) {
        await session.api.updateRetireDebt(
          fid,
          widget.existing!.id,
          name: name,
          kind: _kind,
          emoji: debtKindEmoji(_kind),
          balance: balance,
          monthlyPayment: payment, balanceText: balanceText, monthlyPaymentText: paymentText, clientId: clientId,
          paymentDay: _paymentDay,
          fromAccountId: _fromAccountId,
          active: _active, preserveBalance: preserveBalance, expectedConflictFrontier: expectedFrontier,
        );
      } else {
        await session.api.createRetireDebt(
          fid,
          name: name,
          kind: _kind,
          emoji: debtKindEmoji(_kind),
          balance: balance,
          monthlyPayment: payment, balanceText: balanceText, monthlyPaymentText: paymentText, clientId: clientId,
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

    return WoScaffold(
      backgroundColor: wo.bg,
      appBar: WoAppBar(title: Text(_isEditing ? '编辑负债' : '加负债')),
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
              if (widget.existing?.balanceConflict == true) ...[
                Text('存在待核对财务记录。请填写实际金额，保存前需明确确认；不会删除历史流水。', style: t.bodyMedium?.copyWith(color: wo.warning)),
                const SizedBox(height: WoTokens.space3),
              ],
              if (WoScope.api(context).isLocal) const LocalFinanceStatus(),
              Wrap(
                spacing: WoTokens.space2,
                children: [
                  for (final k in debtKinds)
                    WoChoiceChip(
                      label: Text('${debtKindEmoji(k)} ${debtKindLabel(k)}'),
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
                  labelText: '负债名称',
                  hintText: '比如「商贷」「车贷」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              WoTextField(
                controller: _balance,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: '剩余欠款',
                  prefixText: '¥ ',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              WoTextField(
                controller: _payment,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
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
                  WoDropdownButton<int>(
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
                  WoDropdownButton<String?>(
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
                WoScope.api(context).isLocal ? '打开 App 时按本月账期记录还款，关联账户余额同步更新。' : '到扣款日自动减少这笔负债；关联账户时同时从该账户扣除并记流水。',
                style: t.labelSmall?.copyWith(color: wo.fgDim),
              ),
              if (_isEditing) ...[
                const SizedBox(height: WoTokens.space2),
                WoSwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(WoScope.api(context).isLocal ? '启用本地还款记账' : '启用自动扣款'),
                  subtitle: const Text('关闭后这笔负债不再自动扣款'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              ],
              const SizedBox(height: WoTokens.space4),
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
