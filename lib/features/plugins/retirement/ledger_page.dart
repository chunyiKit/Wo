import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import 'retirement_common.dart';

/// 自动流水页：入账 / 月供扣款 / 上月支出结算的历史记录。
class RetireLedgerPage extends StatefulWidget {
  const RetireLedgerPage({super.key});

  @override
  State<RetireLedgerPage> createState() => _RetireLedgerPageState();
}

class _RetireLedgerPageState extends State<RetireLedgerPage> {
  late Future<List<RetireLedgerEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<List<RetireLedgerEntry>> _fetch() {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    return fid == null
        ? Future.value(const <RetireLedgerEntry>[])
        : session.api.retireLedger(fid);
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('自动流水')),
      body: SafeArea(
        child: AsyncView<List<RetireLedgerEntry>>(
          future: _future,
          onRetry: () => setState(() => _future = _fetch()),
          builder: (context, rows) {
            if (rows.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(WoTokens.space6),
                  child: Text(
                    '还没有自动流水。\n到入账日 / 扣款日，或每月结算后会出现在这里。',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: wo.fgMid),
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                WoTokens.space4,
                WoTokens.space3,
                WoTokens.space4,
                100,
              ),
              itemCount: rows.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: WoTokens.space2),
              itemBuilder: (_, i) => _LedgerTile(entry: rows[i]),
            );
          },
        ),
      ),
    );
  }
}

class _LedgerTile extends StatelessWidget {
  const _LedgerTile({required this.entry});
  final RetireLedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final inflow = entry.kind == 'income';
    // 入账为进账（绿 +）；扣款 / 结算为出账（默认色 −）。
    final amountText = entry.amount == 0
        ? '—'
        : (inflow ? yuan(entry.amount, sign: true) : '−${yuan(entry.amount)}');
    final amountColor = inflow ? retireGreen : wo.fg;
    return WoCard(
      padding: const EdgeInsets.symmetric(
        horizontal: WoTokens.space4,
        vertical: WoTokens.space3,
      ),
      child: Row(
        children: [
          Text(
            ledgerKindEmoji(entry.kind),
            style: const TextStyle(fontSize: 22),
          ),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.note ?? ledgerKindLabel(entry.kind),
                  style: t.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${ledgerKindLabel(entry.kind)} · ${entry.period}',
                  style: t.labelSmall?.copyWith(color: wo.fgDim),
                ),
              ],
            ),
          ),
          Text(
            amountText,
            style: t.titleSmall?.copyWith(
              color: amountColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
