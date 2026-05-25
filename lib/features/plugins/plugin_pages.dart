import 'package:flutter/widgets.dart';

import '../../data/models.dart';
import 'accounting/accounting_page.dart';
import 'anniversary/anniversary_list_page.dart';

/// 根据已安装插件构建它的详情页。
typedef PluginPageBuilder = Widget Function(InstalledPlugin ip);

/// 首页卡片点击 → 详情页的统一注册表。
///
/// 新增插件只需在这里登记一行 + 写它的页面，无需改动首页的点击逻辑，
/// 跳转方式也由 [pluginPageFor] 的调用方统一处理（Navigator.push）。
const Map<String, PluginPageBuilder> _pluginPages = {
  'accounting': _accountingPage,
  'anniversary': _anniversaryPage,
};

Widget _accountingPage(InstalledPlugin ip) => const AccountingPage();
Widget _anniversaryPage(InstalledPlugin ip) => const AnniversaryListPage();

/// 返回插件对应的详情页；未注册的插件返回 null（卡片点击无动作）。
Widget? pluginPageFor(InstalledPlugin ip) => _pluginPages[ip.pluginId]?.call(ip);
