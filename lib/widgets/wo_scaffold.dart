import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Material 页面骨架，保留统一命名以兼容现有业务页面。
class WoScaffold extends StatelessWidget {
  const WoScaffold({
    super.key,
    this.appBar,
    this.body,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomNavigationBar,
    this.bottomSheet,
    this.backgroundColor,
    this.resizeToAvoidBottomInset,
    this.extendBody = false,
    this.extendBodyBehindAppBar = false,
    this.drawer,
    this.endDrawer,
  });

  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomNavigationBar;
  final Widget? bottomSheet;
  final Color? backgroundColor;
  final bool? resizeToAvoidBottomInset;
  final bool extendBody;
  final bool extendBodyBehindAppBar;
  final Widget? drawer;
  final Widget? endDrawer;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: appBar,
    body: body,
    floatingActionButton: floatingActionButton,
    floatingActionButtonLocation: floatingActionButtonLocation,
    bottomNavigationBar: bottomNavigationBar,
    bottomSheet: bottomSheet,
    backgroundColor: backgroundColor,
    resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    extendBody: extendBody,
    extendBodyBehindAppBar: extendBodyBehindAppBar,
    drawer: drawer,
    endDrawer: endDrawer,
  );
}

/// Material [AppBar] 兼容层。
class WoAppBar extends StatelessWidget implements PreferredSizeWidget {
  const WoAppBar({
    super.key,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.title,
    this.actions,
    this.bottom,
    this.backgroundColor,
    this.foregroundColor,
    this.systemOverlayStyle,
    this.centerTitle,
    this.toolbarHeight = 62,
    this.elevation,
    this.scrolledUnderElevation,
  });

  final Widget? leading;
  final bool automaticallyImplyLeading;
  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final SystemUiOverlayStyle? systemOverlayStyle;
  final bool? centerTitle;
  final double toolbarHeight;
  final double? elevation;
  final double? scrolledUnderElevation;

  @override
  Size get preferredSize =>
      Size.fromHeight(toolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) => AppBar(
    leading: leading,
    automaticallyImplyLeading: automaticallyImplyLeading,
    title: title,
    actions: actions,
    bottom: bottom,
    backgroundColor: backgroundColor,
    foregroundColor: foregroundColor,
    systemOverlayStyle: systemOverlayStyle,
    centerTitle: centerTitle,
    toolbarHeight: toolbarHeight,
    elevation: elevation,
    scrolledUnderElevation: scrolledUnderElevation,
  );
}
