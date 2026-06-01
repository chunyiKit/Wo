import 'package:flutter/material.dart';

import '../../../theme/wo_tokens.dart';
import 'buy_items_view.dart';
import 'stock_items_view.dart';

/// 囤货铺首页：两个联动 tab —— 「囤货」记录家里有什么、还剩多少；
/// 「采买」是共享待买清单。两个 tab 各自管理列表与新增（见各自的 View）。
class StockPage extends StatelessWidget {
  const StockPage({super.key, this.initialTabIndex = 0});

  /// 0 = 囤货 tab,1 = 采买 tab。首页采买提醒点进来时传 1 直接落到 采买。
  final int initialTabIndex;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return DefaultTabController(
      length: 2,
      initialIndex: initialTabIndex,
      child: Scaffold(
        backgroundColor: wo.bg,
        appBar: AppBar(
          title: const Text('囤货铺'),
          bottom: TabBar(
            indicatorColor: wo.stock,
            tabs: const [
              Tab(text: '囤货'),
              Tab(text: '采买'),
            ],
          ),
        ),
        body: const SafeArea(
          child: TabBarView(
            children: [
              StockItemsView(),
              BuyItemsView(),
            ],
          ),
        ),
      ),
    );
  }
}
