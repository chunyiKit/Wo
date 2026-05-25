import 'package:flutter/material.dart';

/// 设计 token — 与 design/tokens.css 一一对应。
///
/// 凡是颜色/圆角/阴影/spacing 都走这里，避免在业务代码里散落数值。
class WoTokens {
  WoTokens._();

  // ── 色板 · 暖橙 / 焦糖 ─────────────────────────────────────────
  static const accent = Color(0xFFE8895A);
  static const accentDeep = Color(0xFFC76A3F);
  static const accentSoft = Color(0xFFFCE4D4);

  // 浅色
  static const lightBg = Color(0xFFFBF7F1);
  static const lightBgElev = Color(0xFFFFFFFF);
  static const lightBgTint = Color(0xFFF4EFE7);
  static const lightFg = Color(0xFF2A2722);
  static const lightFgMid = Color(0xFF6B635A);
  static const lightFgDim = Color(0xFF9A9085);
  static const lightHairline = Color(0x142A2722); // rgba(42,39,34,.08)

  // 深色
  static const darkBg = Color(0xFF15120F);
  static const darkBgElev = Color(0xFF221F1B);
  static const darkBgTint = Color(0xFF1C1916);
  static const darkFg = Color(0xFFF2EDE5);
  static const darkFgMid = Color(0xFFA89F94);
  static const darkFgDim = Color(0xFF6A6660);
  static const darkHairline = Color(0x12FFF8F0); // rgba(255,248,240,.07)
  static const darkAccent = Color(0xFFF09A6E);
  static const darkAccentSoft = Color(0xFF3A2820);

  // 插件分类色（浅 / 深）
  static const photoLight = Color(0xFFE8DCC8);
  static const moneyLight = Color(0xFFE8D4A8);
  static const annivLight = Color(0xFFF0C4B4);
  static const choreLight = Color(0xFFD6DCC8);
  static const petLight = Color(0xFFE8D0E0);

  static const photoDark = Color(0xFF3A3226);
  static const moneyDark = Color(0xFF3A331F);
  static const annivDark = Color(0xFF3A2A22);
  static const choreDark = Color(0xFF2C3026);
  static const petDark = Color(0xFF3A2E36);

  // 语义强调色（预算见底等）：黄=warning，红=danger。需在卡片底色上可读。
  static const warningLight = Color(0xFFC98A00);
  static const dangerLight = Color(0xFFC0392B);
  static const warningDark = Color(0xFFE6B84D);
  static const dangerDark = Color(0xFFF06A5D);

  // ── 圆角 ──────────────────────────────────────────────────────
  static const cardRadius = 22.0;
  static const fabRadius = 18.0;
  static const chipRadius = 999.0;
  static const sheetRadius = 28.0;

  // ── Spacing（4 倍数） ────────────────────────────────────────
  static const space1 = 4.0;
  static const space2 = 8.0;
  static const space3 = 12.0;
  static const space4 = 16.0;
  static const space5 = 20.0;
  static const space6 = 24.0;
  static const space8 = 32.0;

  // ── 阴影 ──────────────────────────────────────────────────────
  static const cardShadow = <BoxShadow>[
    BoxShadow(color: Color(0x0A2A1E14), blurRadius: 2, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0F2A1E14), blurRadius: 20, offset: Offset(0, 6)),
  ];

  static const fabShadow = <BoxShadow>[
    BoxShadow(color: Color(0x52E8895A), blurRadius: 16, offset: Offset(0, 4)),
  ];
}

/// 扩展色：放进 ThemeExtension，方便业务从 Theme.of(context) 取到。
@immutable
class WoColors extends ThemeExtension<WoColors> {
  const WoColors({
    required this.bg,
    required this.bgElev,
    required this.bgTint,
    required this.fg,
    required this.fgMid,
    required this.fgDim,
    required this.hairline,
    required this.accent,
    required this.accentDeep,
    required this.accentSoft,
    required this.photo,
    required this.money,
    required this.anniv,
    required this.chore,
    required this.pet,
    required this.warning,
    required this.danger,
  });

  final Color bg;
  final Color bgElev;
  final Color bgTint;
  final Color fg;
  final Color fgMid;
  final Color fgDim;
  final Color hairline;

  final Color accent;
  final Color accentDeep;
  final Color accentSoft;

  final Color photo;
  final Color money;
  final Color anniv;
  final Color chore;
  final Color pet;
  final Color warning;
  final Color danger;

  static const light = WoColors(
    bg: WoTokens.lightBg,
    bgElev: WoTokens.lightBgElev,
    bgTint: WoTokens.lightBgTint,
    fg: WoTokens.lightFg,
    fgMid: WoTokens.lightFgMid,
    fgDim: WoTokens.lightFgDim,
    hairline: WoTokens.lightHairline,
    accent: WoTokens.accent,
    accentDeep: WoTokens.accentDeep,
    accentSoft: WoTokens.accentSoft,
    photo: WoTokens.photoLight,
    money: WoTokens.moneyLight,
    anniv: WoTokens.annivLight,
    chore: WoTokens.choreLight,
    pet: WoTokens.petLight,
    warning: WoTokens.warningLight,
    danger: WoTokens.dangerLight,
  );

  static const dark = WoColors(
    bg: WoTokens.darkBg,
    bgElev: WoTokens.darkBgElev,
    bgTint: WoTokens.darkBgTint,
    fg: WoTokens.darkFg,
    fgMid: WoTokens.darkFgMid,
    fgDim: WoTokens.darkFgDim,
    hairline: WoTokens.darkHairline,
    accent: WoTokens.darkAccent,
    accentDeep: WoTokens.accent,
    accentSoft: WoTokens.darkAccentSoft,
    photo: WoTokens.photoDark,
    money: WoTokens.moneyDark,
    anniv: WoTokens.annivDark,
    chore: WoTokens.choreDark,
    pet: WoTokens.petDark,
    warning: WoTokens.warningDark,
    danger: WoTokens.dangerDark,
  );

  @override
  WoColors copyWith({
    Color? bg,
    Color? bgElev,
    Color? bgTint,
    Color? fg,
    Color? fgMid,
    Color? fgDim,
    Color? hairline,
    Color? accent,
    Color? accentDeep,
    Color? accentSoft,
    Color? photo,
    Color? money,
    Color? anniv,
    Color? chore,
    Color? pet,
    Color? warning,
    Color? danger,
  }) {
    return WoColors(
      bg: bg ?? this.bg,
      bgElev: bgElev ?? this.bgElev,
      bgTint: bgTint ?? this.bgTint,
      fg: fg ?? this.fg,
      fgMid: fgMid ?? this.fgMid,
      fgDim: fgDim ?? this.fgDim,
      hairline: hairline ?? this.hairline,
      accent: accent ?? this.accent,
      accentDeep: accentDeep ?? this.accentDeep,
      accentSoft: accentSoft ?? this.accentSoft,
      photo: photo ?? this.photo,
      money: money ?? this.money,
      anniv: anniv ?? this.anniv,
      chore: chore ?? this.chore,
      pet: pet ?? this.pet,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
    );
  }

  @override
  WoColors lerp(ThemeExtension<WoColors>? other, double t) {
    if (other is! WoColors) return this;
    return WoColors(
      bg: Color.lerp(bg, other.bg, t)!,
      bgElev: Color.lerp(bgElev, other.bgElev, t)!,
      bgTint: Color.lerp(bgTint, other.bgTint, t)!,
      fg: Color.lerp(fg, other.fg, t)!,
      fgMid: Color.lerp(fgMid, other.fgMid, t)!,
      fgDim: Color.lerp(fgDim, other.fgDim, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentDeep: Color.lerp(accentDeep, other.accentDeep, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      photo: Color.lerp(photo, other.photo, t)!,
      money: Color.lerp(money, other.money, t)!,
      anniv: Color.lerp(anniv, other.anniv, t)!,
      chore: Color.lerp(chore, other.chore, t)!,
      pet: Color.lerp(pet, other.pet, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

extension WoColorsX on BuildContext {
  WoColors get wo => Theme.of(this).extension<WoColors>()!;
}
