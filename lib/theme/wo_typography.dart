import 'package:flutter/material.dart';

/// 字体设置：iOS 用 PingFang / 系统中文；Android 用 HarmonyOS Sans / Noto Sans SC
/// 兜底；数字用 Inter（如未安装则继承默认）。
///
/// 注：HarmonyOS Sans / Inter 字体文件需要在 pubspec.yaml 的 fonts 段声明并
/// 放到 assets/fonts/。本工程默认未捆绑字体——首次集成时由设计/工程协商落地。
class WoTypography {
  WoTypography._();

  static const fontFamily = 'HarmonyOS Sans';

  /// CJK 字体回退链
  static const fontFamilyFallback = <String>[
    'PingFang SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'Roboto',
    'sans-serif',
  ];

  static TextTheme textTheme(Color fg, Color fgMid) => TextTheme(
        displayLarge: _t(fg, 32, FontWeight.w600, -0.5),
        displayMedium: _t(fg, 28, FontWeight.w600, -0.4),
        displaySmall: _t(fg, 24, FontWeight.w600, -0.3),
        headlineLarge: _t(fg, 22, FontWeight.w600, -0.2),
        headlineMedium: _t(fg, 20, FontWeight.w600, -0.1),
        headlineSmall: _t(fg, 18, FontWeight.w600, 0),
        titleLarge: _t(fg, 17, FontWeight.w600, 0),
        titleMedium: _t(fg, 15, FontWeight.w500, 0),
        titleSmall: _t(fgMid, 13, FontWeight.w500, 0),
        bodyLarge: _t(fg, 16, FontWeight.w400, 0),
        bodyMedium: _t(fg, 14, FontWeight.w400, 0),
        bodySmall: _t(fgMid, 12, FontWeight.w400, 0),
        labelLarge: _t(fg, 14, FontWeight.w500, 0),
        labelMedium: _t(fgMid, 12, FontWeight.w500, 0.2),
        labelSmall: _t(fgMid, 11, FontWeight.w500, 0.3),
      );

  static TextStyle _t(
    Color color,
    double size,
    FontWeight weight,
    double letter,
  ) {
    return TextStyle(
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: letter,
      color: color,
      height: 1.35,
    );
  }
}
