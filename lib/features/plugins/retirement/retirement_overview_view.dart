import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import 'plan_edit_page.dart';
import 'retirement_common.dart';

/// 「总览」tab：退休倒计时 + 目标进度 + 需求6（还需几个月）/ 需求7（每月差额）+
/// 月结余拆解 + 资产负债汇总。数据由后端 `/dashboard` 算好。
class RetirementOverviewView extends StatefulWidget {
  const RetirementOverviewView({super.key, required this.refreshSignal});

  /// 资产 / 负债变更后会 notify，触发静默重算。
  final Listenable refreshSignal;

  @override
  State<RetirementOverviewView> createState() => _RetirementOverviewViewState();
}

class _RetirementOverviewViewState extends State<RetirementOverviewView> {
  late Future<RetireDashboard> _future;
  RetireDashboard? _data;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    widget.refreshSignal.addListener(_refreshSilently);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  @override
  void dispose() {
    widget.refreshSignal.removeListener(_refreshSilently);
    super.dispose();
  }

  Future<RetireDashboard> _fetch() {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    return fid == null
        ? Future.value(_empty)
        : session.api.retireDashboard(fid);
  }

  void _store(RetireDashboard d) {
    if (mounted) setState(() => _data = d);
  }

  Future<void> _retry() {
    setState(() {
      _data = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  Future<void> _refreshSilently() async {
    try {
      final d = await _fetch();
      if (mounted) setState(() => _data = d);
    } catch (_) {
      // 拉取失败保留旧数据。
    }
  }

  Future<void> _openPlanEditor() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PlanEditPage()),
    );
    if (changed == true) {
      await _refreshSilently();
      if (mounted) await WoScope.of(context).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cached = _data;
    return cached != null
        ? _content(context, cached)
        : AsyncView<RetireDashboard>(
            future: _future,
            onRetry: _retry,
            builder: _content,
          );
  }

  Widget _content(BuildContext context, RetireDashboard d) {
    return RefreshIndicator(
      onRefresh: _refreshSilently,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          WoTokens.space4,
          WoTokens.space4,
          WoTokens.space4,
          100,
        ),
        children: [
          _CountdownCard(d: d, onEdit: _openPlanEditor),
          const SizedBox(height: WoTokens.space3),
          _GoalCard(d: d, onEdit: _openPlanEditor),
          const SizedBox(height: WoTokens.space3),
          _SurplusCard(d: d),
          const SizedBox(height: WoTokens.space3),
          _NetWorthCard(d: d),
        ],
      ),
    );
  }
}

/// 没有家庭时的空仪表盘占位。
const _empty = RetireDashboard(
  totalDeposit: 0,
  totalFund: 0,
  totalAssets: 0,
  totalDebt: 0,
  netWorth: 0,
  current: 0,
  monthlyIncome: 0,
  monthlyDebt: 0,
  monthlyExpense: 0,
  monthlySurplus: 0,
);

/// 把月份数渲染成「X 年 Y 个月」。
String _months(int m) {
  if (m <= 0) return '0 个月';
  final y = m ~/ 12;
  final mm = m % 12;
  if (y > 0 && mm > 0) return '$y 年 $mm 个月';
  if (y > 0) return '$y 年';
  return '$mm 个月';
}

class _CountdownCard extends StatelessWidget {
  const _CountdownCard({required this.d, required this.onEdit});
  final RetireDashboard d;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final days = d.daysToRetire;
    String big;
    String sub;
    if (d.retireDate == null) {
      big = '未设退休日期';
      sub = '点右上角编辑，开始规划';
    } else if (days != null && days <= 0) {
      big = '🎉 可以退休啦';
      sub = '退休日期：${_isoDate(d.retireDate!)}';
    } else {
      big = '还有 ${_months(d.monthsToRetire ?? 0)}';
      sub = '退休日期 ${_isoDate(d.retireDate!)} · 约 $days 天';
    }
    return WoCard(
      color: wo.retire,
      onTap: onEdit,
      child: Row(
        children: [
          const Text('🏖️', style: TextStyle(fontSize: 34)),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  big,
                  style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(sub, style: t.bodySmall?.copyWith(color: wo.fgMid)),
              ],
            ),
          ),
          Icon(Icons.edit_outlined, size: 20, color: wo.fgDim),
        ],
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.d, required this.onEdit});
  final RetireDashboard d;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    if (d.savingsGoal == null || d.savingsGoal! <= 0) {
      return WoCard(
        onTap: onEdit,
        child: Row(
          children: [
            Expanded(
              child: Text(
                '还没设存款目标，点这里设定目标金额',
                style: t.bodyMedium?.copyWith(color: wo.fgMid),
              ),
            ),
            Icon(Icons.chevron_right, color: wo.fgDim),
          ],
        ),
      );
    }

    final goal = d.savingsGoal!;
    final ratio = (d.current / goal).clamp(0.0, 1.0);
    final pct = (d.current / goal * 100).round();

    return WoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '存款目标',
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '${pct.clamp(0, 999)}%',
                style: t.titleSmall?.copyWith(color: wo.retire),
              ),
            ],
          ),
          const SizedBox(height: WoTokens.space2),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 10,
              backgroundColor: wo.bgTint,
              valueColor: AlwaysStoppedAnimation(wo.retire),
            ),
          ),
          const SizedBox(height: WoTokens.space2),
          Text(
            '已有 ${yuan(d.current)} / 目标 ${yuan(goal)}'
            '（口径：${goalBasisLabel(d.goalBasis)}）',
            style: t.bodySmall?.copyWith(color: wo.fgMid),
          ),
          const Divider(height: WoTokens.space5),
          _req6(context),
          const SizedBox(height: WoTokens.space3),
          _req7(context),
        ],
      ),
    );
  }

  // 需求 6：还需几个月达标。
  Widget _req6(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    String text;
    if (d.goalReached) {
      text = '🎉 已达成存款目标';
    } else if (d.monthsToGoal == null) {
      text = '按当前每月结余（${yuan(d.monthlySurplus)}）无法达成目标';
    } else {
      text = '按当前每月结余 ${yuan(d.monthlySurplus)}，'
          '还需 ${_months(d.monthsToGoal!)}达标';
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.timelapse, size: 18, color: wo.fgMid),
        const SizedBox(width: WoTokens.space2),
        Expanded(child: Text(text, style: t.bodyMedium)),
      ],
    );
  }

  // 需求 7：要按退休日达标，每月差额（+盈余红 / −缺口绿）。
  Widget _req7(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    if (d.retireDate == null) {
      return _line(
        context,
        Icons.flag_outlined,
        '设好退休日期后，这里会算出每月还需提高多少',
        wo.fgMid,
      );
    }
    final gap = d.monthlyGap;
    if (gap == null) {
      return _line(context, Icons.flag_outlined, '退休日期已到，无法计算每月差额', wo.fgMid);
    }
    final shortfall = gap < 0;
    final color = shortfall ? retireGreen : wo.danger;
    final headline = shortfall ? '每月还需提高' : '每月已有盈余';
    final detail = shortfall
        ? '想在退休日攒够目标，月收入还得再提高 ${yuan(gap.abs())}'
        : '按当前结余，到退休日能超出目标，每月富余 ${yuan(gap.abs())}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.flag_outlined, size: 18, color: color),
        const SizedBox(width: WoTokens.space2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('$headline ', style: t.bodyMedium),
                  Text(
                    yuan(gap, sign: true),
                    style: t.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(detail, style: t.bodySmall?.copyWith(color: wo.fgMid)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _line(BuildContext context, IconData icon, String text, Color color) {
    final t = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: WoTokens.space2),
        Expanded(
          child: Text(text, style: t.bodyMedium?.copyWith(color: color)),
        ),
      ],
    );
  }
}

class _SurplusCard extends StatelessWidget {
  const _SurplusCard({required this.d});
  final RetireDashboard d;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final usesExpense = d.surplusBasis == 'income_debt_expense';
    final usesDebt = d.surplusBasis != 'income_only';
    return WoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '每月结余',
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '口径：${surplusBasisLabel(d.surplusBasis)}',
                style: t.labelSmall?.copyWith(color: wo.fgDim),
              ),
            ],
          ),
          const SizedBox(height: WoTokens.space2),
          _row(context, '月固定收入', d.monthlyIncome, wo.fgMid),
          if (usesDebt) _row(context, '月负债扣款', -d.monthlyDebt, wo.fgMid),
          if (usesExpense)
            _row(context, '月支出（上月记账）', -d.monthlyExpense, wo.fgMid),
          const Divider(height: WoTokens.space4),
          _row(context, '每月结余', d.monthlySurplus, wo.fg, bold: true),
          if (usesExpense && !d.accountingInstalled) ...[
            const SizedBox(height: WoTokens.space2),
            Text(
              '未安装「记账」插件，月支出按 ¥0 估算',
              style: t.labelSmall?.copyWith(color: wo.fgDim),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    double value,
    Color color, {
    bool bold = false,
  }) {
    final t = Theme.of(context).textTheme;
    final style = (bold ? t.titleSmall : t.bodyMedium)
        ?.copyWith(color: color, fontWeight: bold ? FontWeight.w700 : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(yuan(value, sign: value != 0 && !bold), style: style),
        ],
      ),
    );
  }
}

class _NetWorthCard extends StatelessWidget {
  const _NetWorthCard({required this.d});
  final RetireDashboard d;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return WoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '资产负债',
            style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: WoTokens.space2),
          _row(context, '总资产（存款 + 公积金）', d.totalAssets, wo.fg),
          _row(context, '总负债', d.totalDebt, wo.fgMid),
          const Divider(height: WoTokens.space4),
          _row(context, '净资产', d.netWorth, wo.fg, bold: true),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    double value,
    Color color, {
    bool bold = false,
  }) {
    final t = Theme.of(context).textTheme;
    final style = (bold ? t.titleSmall : t.bodyMedium)
        ?.copyWith(color: color, fontWeight: bold ? FontWeight.w700 : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(yuan(value), style: style),
        ],
      ),
    );
  }
}

String _isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
