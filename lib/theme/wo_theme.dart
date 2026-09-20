import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'wo_tokens.dart';
import 'wo_typography.dart';

/// 日落影院：酒棕、象牙与琥珀。共享组件和原生 Material 控件使用同一套样式。
class WoTheme {
  WoTheme._();
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final wo = dark ? WoColors.dark : WoColors.light;
    final onAccent = dark ? const Color(0xFF2A170B) : Colors.white;
    final scheme = ColorScheme.fromSeed(
      seedColor: wo.accent,
      brightness: brightness,
      primary: wo.accent,
      onPrimary: onAccent,
      primaryContainer: wo.accentSoft,
      onPrimaryContainer: wo.fg,
      secondary: wo.accentDeep,
      onSecondary: onAccent,
      secondaryContainer: wo.bgTint,
      onSecondaryContainer: wo.fg,
      surface: wo.bg,
      onSurface: wo.fg,
      onSurfaceVariant: wo.fgMid,
      surfaceContainerLowest: wo.bg,
      surfaceContainerLow: wo.bgTint,
      surfaceContainer: wo.bgElev,
      surfaceContainerHigh: wo.bgElev,
      surfaceContainerHighest: wo.accentSoft,
      outline: wo.fgDim,
      outlineVariant: wo.hairline,
      error: wo.danger,
    );
    final text = WoTypography.textTheme(wo.fg, wo.fgMid);
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(18));
    final outline = OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide(color: wo.hairline),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: wo.bg,
      canvasColor: wo.bg,
      fontFamily: WoTypography.fontFamily,
      textTheme: text,
      splashFactory: InkSparkle.splashFactory,
      extensions: [wo],
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: ZoomPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: wo.bg,
        foregroundColor: wo.fg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 20,
        titleTextStyle: WoTypography.editorial(wo.fg, size: 23),
        iconTheme: IconThemeData(color: wo.accent, size: 22),
        systemOverlayStyle:
            (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
                .copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: wo.bg,
          systemNavigationBarIconBrightness:
              dark ? Brightness.light : Brightness.dark,
        ),
      ),
      cardTheme: CardThemeData(
        color: wo.bgElev,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WoTokens.cardRadius),
          side: BorderSide(color: wo.hairline),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: wo.accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: wo.bgTint,
          disabledForegroundColor: wo.fgDim,
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
          minimumSize: const Size(48, 50),
          shape: shape,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: wo.fg,
          side: BorderSide(color: wo.hairline),
          minimumSize: const Size(48, 48),
          shape: shape,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: wo.accentDeep,
          minimumSize: const Size(44, 44),
          textStyle: text.labelLarge,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(44, 44),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: wo.accent,
        foregroundColor: onAccent,
        elevation: 3,
        highlightElevation: 5,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: wo.bgTint,
        hintStyle: text.bodyMedium?.copyWith(color: wo.fgDim),
        labelStyle: text.bodyMedium?.copyWith(color: wo.fgMid),
        floatingLabelStyle: text.bodySmall?.copyWith(color: wo.accent),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        border: outline,
        enabledBorder: outline,
        focusedBorder: outline.copyWith(
          borderSide: BorderSide(color: wo.accent, width: 1.5),
        ),
        errorBorder: outline.copyWith(borderSide: BorderSide(color: wo.danger)),
        focusedErrorBorder: outline.copyWith(
          borderSide: BorderSide(color: wo.danger, width: 1.5),
        ),
      ),
      dividerTheme:
          DividerThemeData(color: wo.hairline, thickness: .7, space: 1),
      listTileTheme: ListTileThemeData(
        iconColor: wo.accentDeep,
        textColor: wo.fg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        minVerticalPadding: 12,
        horizontalTitleGap: 14,
        titleTextStyle: text.bodyMedium,
        subtitleTextStyle: text.bodySmall,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: wo.bgTint,
        selectedColor: wo.accentSoft,
        labelStyle: text.labelMedium?.copyWith(color: wo.fgMid),
        secondaryLabelStyle: text.labelMedium?.copyWith(color: wo.fg),
        side: BorderSide(color: wo.hairline),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? wo.accentSoft : wo.bg,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? wo.accentDeep
                : wo.fgMid,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: wo.hairline)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: wo.accent,
        unselectedLabelColor: wo.fgMid,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        dividerColor: wo.hairline,
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: wo.accent, width: 2),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: wo.bgElev,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: WoTypography.editorial(wo.fg, size: 23),
        contentTextStyle: text.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(color: wo.hairline),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: wo.bgElev,
        modalBackgroundColor: wo.bgElev,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: wo.fgDim,
        dragHandleSize: const Size(32, 3),
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          side: BorderSide(color: wo.hairline),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: wo.accentSoft,
        contentTextStyle: text.bodyMedium,
        actionTextColor: wo.accentDeep,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: wo.hairline),
        ),
        elevation: 4,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: wo.bgElev,
        surfaceTintColor: Colors.transparent,
        textStyle: text.bodyMedium,
        shape: shape,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: wo.accent,
        linearTrackColor: wo.hairline,
        circularTrackColor: wo.bgTint,
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        side: BorderSide(color: wo.fgDim),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStatePropertyAll(wo.hairline),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: wo.bgElev,
        indicatorColor: wo.accentSoft,
        surfaceTintColor: Colors.transparent,
        height: 68,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: wo.accentSoft,
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: text.bodySmall,
      ),
    );
  }
}
