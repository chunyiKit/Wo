import 'package:flutter/widgets.dart';

import '../../data/models.dart';
import 'accounting/accounting_page.dart';
import 'anniversary/anniversary_list_page.dart';
import 'calendar/calendar_list_page.dart';
import 'chore/chore_list_page.dart';
import 'expiry/expiry_page.dart';
import 'memory/memory_list_page.dart';
import 'movie/movie_list_page.dart';
import 'plant/plant_list_page.dart';
import 'recipe/recipe_list_page.dart';
import 'retirement/retirement_page.dart';
import 'stock/stock_page.dart';
import 'subscription/subscription_page.dart';
import 'travel/travel_home_page.dart';

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
  'movie': _moviePage,
  'calendar': _calendarPage,
  'subscription': _subscriptionPage,
  'plant': _plantPage,
  'retirement': _retirementPage,
  'expiry': _expiryPage,
  'travel': _travelPage,
};

Widget _accountingPage(InstalledPlugin ip) => const AccountingPage();
Widget _anniversaryPage(InstalledPlugin ip) => const AnniversaryListPage();
Widget _recipePage(InstalledPlugin ip) => const RecipeListPage();
Widget _chorePage(InstalledPlugin ip) => const ChoreListPage();
Widget _memoryPage(InstalledPlugin ip) => const MemoryListPage();
Widget _stockPage(InstalledPlugin ip) => const StockPage();
Widget _moviePage(InstalledPlugin ip) => const MovieListPage();
Widget _calendarPage(InstalledPlugin ip) => const CalendarListPage();
Widget _subscriptionPage(InstalledPlugin ip) => const SubscriptionPage();
Widget _plantPage(InstalledPlugin ip) => const PlantListPage();
Widget _retirementPage(InstalledPlugin ip) => const RetirementPage();
Widget _expiryPage(InstalledPlugin ip) => const ExpiryPage();
Widget _travelPage(InstalledPlugin ip) => const TravelListPage();

/// 返回插件对应的详情页；未注册的插件返回 null（卡片点击无动作）。
Widget? pluginPageFor(InstalledPlugin ip) =>
    _pluginPages[ip.pluginId]?.call(ip);
