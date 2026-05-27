import 'package:flutter/widgets.dart';

import '../../data/models.dart';
import 'accounting/accounting_page.dart';
import 'anniversary/anniversary_list_page.dart';
import 'chore/chore_list_page.dart';
import 'memory/memory_list_page.dart';
import 'recipe/recipe_list_page.dart';
import 'stock/stock_page.dart';

/// 根据已安装插件构建它的详情页。
typedef PluginPageBuilder = Widget Function(InstalledPlugin ip);

/// 首页卡片点击 → 详情页的统一注册表。
///
/// 新增插件只需在这里登记一行 + 写它的页面，无需改动首页的点击逻辑，
/// 跳转方式也由 [pluginPageFor] 的调用方统一处理（Navigator.push）。
const Map<String, PluginPageBuilder> _pluginPages = {
  'accounting': _accountingPage,
  'anniversary': _anniversaryPage,
  'recipe': _recipePage,
  'chore': _chorePage,
  'memory': _memoryPage,
  'stock': _stockPage,
};

Widget _accountingPage(InstalledPlugin ip) => const AccountingPage();
Widget _anniversaryPage(InstalledPlugin ip) => const AnniversaryListPage();
Widget _recipePage(InstalledPlugin ip) => const RecipeListPage();
Widget _chorePage(InstalledPlugin ip) => const ChoreListPage();
Widget _memoryPage(InstalledPlugin ip) => const MemoryListPage();
Widget _stockPage(InstalledPlugin ip) => const StockPage();

/// 返回插件对应的详情页；未注册的插件返回 null（卡片点击无动作）。
Widget? pluginPageFor(InstalledPlugin ip) => _pluginPages[ip.pluginId]?.call(ip);
