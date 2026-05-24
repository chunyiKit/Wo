import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'wo_tokens.dart';
import 'wo_typography.dart';

/// 「窝（Wo）」Material 3 主题。
///
/// 主色 = 暖橙 `#E8895A`，浅深两套都以同一种 accent 派生 / 调节，
/// 整体调性保持一致。所有色板与 [WoColors] 一一对应。
class WoTheme {
  WoTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final wo = isLight ? WoColors.light : WoColors.dark;

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: wo.accent,
      onPrimary: Colors.white,
      primaryContainer: wo.accentSoft,
      onPrimaryContainer: wo.accentDeep,
      secondary: wo.accentDeep,
      onSecondary: Colors.white,
      secondaryContainer: wo.bgTint,
      onSecondaryContainer: wo.fg,
      tertiary: wo.anniv,
      onTertiary: wo.fg,
      tertiaryContainer: wo.anniv,
      onTertiaryContainer: wo.fg,
      error: const Color(0xFFB3261E),
      onError: Colors.white,
      errorContainer: const Color(0xFFF9DEDC),
      onErrorContainer: const Color(0xFF410E0B),
      surface: wo.bg,
      onSurface: wo.fg,
      surfaceContainerLowest: wo.bg,
      surfaceContainerLow: wo.bgTint,
      surfaceContainer: wo.bgTint,
      surfaceContainerHigh: wo.bgElev,
      surfaceContainerHighest: wo.bgElev,
      onSurfaceVariant: wo.fgMid,
      outline: wo.fgDim,
      outlineVariant: wo.hairline,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: isLight ? wo.fg : wo.bg,
      onInverseSurface: isLight ? wo.bg : wo.fg,
      inversePrimary: isLight ? WoTokens.darkAccent : WoTokens.accent,
    );

    final textTheme = WoTypography.textTheme(wo.fg, wo.fgMid);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: wo.bg,
      canvasColor: wo.bg,
      fontFamily: WoTypography.fontFamily,
      textTheme: textTheme,
      splashFactory: InkSparkle.splashFactory,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: ZoomPageTransitionsBuilder(),
        },
      ),
      extensions: <ThemeExtension<dynamic>>[wo],

      // ── 顶部栏 · Material 3 风格 TopAppBar
      appBarTheme: AppBarTheme(
        backgroundColor: wo.bg,
        foregroundColor: wo.fg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        titleTextStyle: textTheme.titleLarge,
        systemOverlayStyle: isLight
            ? SystemUiOverlayStyle.dark.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: wo.bg,
                systemNavigationBarIconBrightness: Brightness.dark,
              )
            : SystemUiOverlayStyle.light.copyWith(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: wo.bg,
                systemNavigationBarIconBrightness: Brightness.light,
              ),
      ),

      // ── 底部导航 · Material 3 NavigationBar
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: wo.bg.withValues(alpha: 0.96),
        indicatorColor: wo.accentSoft,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: WoTypography.fontFamily,
            fontFamilyFallback: WoTypography.fontFamilyFallback,
            fontSize: 11,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? wo.accentDeep : wo.fgDim,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 22,
            color: selected ? wo.accentDeep : wo.fgDim,
          );
        }),
      ),

      // ── 卡片
      cardTheme: CardThemeData(
        color: wo.bgElev,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WoTokens.cardRadius),
        ),
      ),

      // ── 主按钮（暖橙 FilledButton）
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: wo.accent,
          foregroundColor: Colors.white,
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
      ),

      // ── 次级按钮
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: wo.fg,
          side: BorderSide(color: wo.hairline),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),

      // ── 文字按钮
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: wo.accentDeep,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // ── FAB · 加插件
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: wo.accent,
        foregroundColor: Colors.white,
        elevation: 4,
        focusElevation: 4,
        hoverElevation: 4,
        highlightElevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WoTokens.fabRadius),
        ),
      ),

      // ── 输入框
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: wo.bgTint,
        hintStyle: textTheme.bodyMedium?.copyWith(color: wo.fgDim),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: wo.accent, width: 1.5),
        ),
      ),

      // ── 分割线
      dividerTheme: DividerThemeData(
        color: wo.hairline,
        thickness: 1,
        space: 1,
      ),

      // ── Chip（分类筛选）
      chipTheme: ChipThemeData(
        backgroundColor: wo.bgTint,
        selectedColor: wo.accentSoft,
        labelStyle: textTheme.labelMedium,
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(
          color: wo.accentDeep,
        ),
        side: BorderSide.none,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WoTokens.chipRadius),
        ),
      ),

      // ── 底部 Sheet
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: wo.bg,
        modalBackgroundColor: wo.bg,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(WoTokens.sheetRadius),
          ),
        ),
      ),
    );
  }
}
