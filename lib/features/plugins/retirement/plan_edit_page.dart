import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'retirement_common.dart';

/// 退休计划编辑页：退休日期、存款目标、目标口径、月结余口径。保存后 `pop(true)`。
class PlanEditPage extends StatefulWidget {
  const PlanEditPage({super.key});

  @override
  State<PlanEditPage> createState() => _PlanEditPageState();
}

class _PlanEditPageState extends State<PlanEditPage> {
  final TextEditingController _goal = TextEditingController();
  DateTime? _retireDate;
  String _goalBasis = 'net_worth';
  String _surplusBasis = 'income_debt_expense';

  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _goal.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final plan = await session.api.retirePlan(fid);
      if (!mounted) return;
      setState(() {
        _retireDate = plan.retireDate;
        if (plan.savingsGoal != null) {
          final g = plan.savingsGoal!;
          _goal.text = g == g.roundToDouble()
              ? g.toStringAsFixed(0)
              : g.toStringAsFixed(2);
        }
        _goalBasis = plan.goalBasis;
        _surplusBasis = plan.surplusBasis;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _retireDate ?? DateTime(now.year + 10, now.month, now.day),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 70),
      helpText: '选择计划退休日期',
    );
    if (picked != null) setState(() => _retireDate = picked);
  }

  Future<void> _save() async {
    if (_submitting) return;
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;

    final goalText = _goal.text.trim();
    final goal = goalText.isEmpty ? null : double.tryParse(goalText);

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      await session.api.updateRetirePlan(
        fid,
        retireDate: _retireDate,
        clearRetireDate: _retireDate == null,
        savingsGoal: goal,
        goalBasis: _goalBasis,
        surplusBasis: _surplusBasis,
      );
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

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('退休计划')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(WoTokens.space5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _label(context, '退休日期'),
                    const SizedBox(height: WoTokens.space2),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pickDate,
                            icon: const Icon(Icons.event),
                            label: Text(
                              _retireDate == null
                                  ? '选择日期'
                                  : _isoDate(_retireDate!),
                            ),
                          ),
                        ),
                        if (_retireDate != null)
                          IconButton(
                            tooltip: '清除',
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(() => _retireDate = null),
                          ),
                      ],
                    ),
                    const SizedBox(height: WoTokens.space4),
                    TextField(
                      controller: _goal,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: '存款目标',
                        hintText: '退休时希望攒到多少',
                        prefixText: '¥ ',
                      ),
                    ),
                    const SizedBox(height: WoTokens.space5),
                    _label(context, '目标进度口径'),
                    Text(
                      '「现在已有」按哪个口径和目标比较',
                      style: t.labelSmall?.copyWith(color: wo.fgDim),
                    ),
                    const SizedBox(height: WoTokens.space2),
                    RadioGroup<String>(
                      groupValue: _goalBasis,
                      onChanged: (v) =>
                          setState(() => _goalBasis = v ?? _goalBasis),
                      child: Column(
                        children: [
                          for (final b in goalBases)
                            RadioListTile<String>(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: Text(goalBasisLabel(b)),
                              value: b,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: WoTokens.space4),
                    _label(context, '月结余口径'),
                    Text(
                      '用于推算「还需几个月」和「每月差额」',
                      style: t.labelSmall?.copyWith(color: wo.fgDim),
                    ),
                    const SizedBox(height: WoTokens.space2),
                    RadioGroup<String>(
                      groupValue: _surplusBasis,
                      onChanged: (v) =>
                          setState(() => _surplusBasis = v ?? _surplusBasis),
                      child: Column(
                        children: [
                          for (final b in surplusBases)
                            RadioListTile<String>(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: Text(surplusBasisLabel(b)),
                              value: b,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: WoTokens.space5),
                    FilledButton(
                      onPressed: _submitting ? null : _save,
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('保存'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _label(BuildContext context, String text) {
    final t = Theme.of(context).textTheme;
    return Text(
      text,
      style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    );
  }
}

String _isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
