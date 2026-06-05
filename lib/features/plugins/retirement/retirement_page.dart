import 'package:flutter/material.dart';

import '../../../theme/wo_tokens.dart';
import 'accounts_view.dart';
import 'debts_view.dart';
import 'ledger_page.dart';
import 'retirement_overview_view.dart';

/// 退休倒计时首页：三个 tab —— 「总览」算倒计时与目标测算，「资产」「负债」管明细。
///
/// 资产 / 负债变更会通过 [_tick] 通知「总览」静默重算，省得手动下拉刷新。
class RetirementPage extends StatefulWidget {
  const RetirementPage({super.key});

  @override
  State<RetirementPage> createState() => _RetirementPageState();
}

class _RetirementPageState extends State<RetirementPage> {
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);

  void _bump() => _tick.value++;

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: wo.bg,
        appBar: AppBar(
          title: const Text('退休倒计时'),
          actions: [
            IconButton(
              tooltip: '自动流水',
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const RetireLedgerPage()),
              ),
            ),
          ],
          bottom: TabBar(
            indicatorColor: wo.retire,
            tabs: const [
              Tab(text: '总览'),
              Tab(text: '资产'),
              Tab(text: '负债'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              RetirementOverviewView(refreshSignal: _tick),
              AccountsView(onChanged: _bump),
              DebtsView(onChanged: _bump),
            ],
          ),
        ),
      ),
    );
  }
}
