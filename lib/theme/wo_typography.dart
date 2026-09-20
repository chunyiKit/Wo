import 'package:flutter/material.dart';

/// 标题使用随包内置的 Noto Serif SC；正文使用 Roboto 与系统中文回退。
class WoTypography {
  WoTypography._();

  static const fontFamily = 'Roboto';
  static const editorialFamily = 'NotoSerifSC';

  static TextStyle editorial(Color color, {double size = 32}) => TextStyle(
        fontFamily: editorialFamily,
        fontSize: size,
        fontWeight: FontWeight.w400,
        height: 1.35,
        letterSpacing: 0.3,
        color: color,
      );

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
      fontFamily: size >= 18 ? editorialFamily : fontFamily,
      fontFamilyFallback: fontFamilyFallback,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: letter,
      color: color,
      height: 1.35,
    );
  }
}
