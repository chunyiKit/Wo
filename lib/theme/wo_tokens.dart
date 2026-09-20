import 'package:flutter/material.dart';

export '../widgets/wo_scaffold.dart';
export '../widgets/wo_material_controls.dart';

/// 日落影院设计 token：暖纸与酒棕两套外观。
///
/// 凡是颜色/圆角/阴影/spacing 都走这里，避免在业务代码里散落数值。
class WoTokens {
  WoTokens._();

  // ── 色板 · 落日 / 琥珀 ─────────────────────────────────────────
  static const accent = Color(0xFFA85D2D);
  static const accentDeep = Color(0xFF915025);
  static const accentSoft = Color(0xFFF2DFC9);

  // 浅色
  static const lightBg = Color(0xFFF8F1E7);
  static const lightBgElev = Color(0xFFFFFFFF);
  static const lightBgTint = Color(0xFFEFE4D6);
  static const lightFg = Color(0xFF302219);
  static const lightFgMid = Color(0xFF736052);
  static const lightFgDim = Color(0xFF7D6655);
  static const lightHairline = Color(0x26302219); // rgba(42,39,34,.08)

  // 深色
  static const darkBg = Color(0xFF160F0D);
  static const darkBgElev = Color(0xFF271C17);
  static const darkBgTint = Color(0xFF201612);
  static const darkFg = Color(0xFFFFF0DB);
  static const darkFgMid = Color(0xFFCEB69E);
  static const darkFgDim = Color(0xFFA9907A);
  static const darkHairline = Color(0x33D9A16A); // rgba(255,248,240,.07)
  static const darkAccent = Color(0xFFF2B779);
  static const darkAccentSoft = Color(0xFF483020);

  // 插件分类色（浅 / 深）
  static const photoLight = Color(0xFFE8DCC8);
  static const moneyLight = Color(0xFFE8D4A8);
  static const annivLight = Color(0xFFF0C4B4);
  static const choreLight = Color(0xFFD6DCC8);
  static const petLight = Color(0xFFE8D0E0);

  static const photoDark = Color(0xFF33271C);
  static const moneyDark = Color(0xFF3C2A18);
  static const annivDark = Color(0xFF42281E);
  static const choreDark = Color(0xFF2D2B21);
  static const petDark = Color(0xFF392624);

  // 囤货：柔雾蓝，区别于其它暖色插件，呼应「货架 / 仓库」的清爽感。
  static const stockLight = Color(0xFFC8D2E0);
  static const stockDark = Color(0xFF292825);

  // 回忆：暖玫瑰灰，落在 photo / anniv 之间，色温更复古。
  // ink 是在 memory tint 底色上可读的强调文字色。
  static const memoryLight = Color(0xFFDDCFC0);
  static const memoryDark = Color(0xFF38271D);

  // 看电影：偏冷的薰衣草紫,跟剧院/胶片的紫调对应,跟暖系列(回忆/纪念日)拉开。
  static const movieLight = Color(0xFFD9CCDF);
  static const movieDark = Color(0xFF302326);

  // 家历：沉静的青绿,跟「日历/计划」的冷静感对应,与既有暖色与紫蓝都拉开。
  static const calendarLight = Color(0xFFBFD8D2);
  static const calendarDark = Color(0xFF2B2D24);

  // 订阅管家：偏蓝的靛紫,呼应银行卡/账单的冷静感,与记账(money 暖金)区分开。
  static const subscribeLight = Color(0xFFC3C8EA);
  static const subscribeDark = Color(0xFF302A2B);

  // 植物日记：柔和的鼠尾草绿,对应草木生机,与家历(青绿)略作区分、更偏暖绿。
  static const plantLight = Color(0xFFC6DCC0);
  static const plantDark = Color(0xFF2B2F22);
  // 退休倒计时：海松青,呼应海岛度假的松弛感,与记账(暖金)/订阅(靛紫)区分开。
  static const retireLight = Color(0xFFAFD8CE);
  static const retireDark = Color(0xFF272D25);
  // 到期管家：沉稳的灰紫,像证件/档案/印章的庄重感,与订阅(偏蓝靛紫)、看电影(浅薰衣草)区分开。
  static const expiryLight = Color(0xFFCBC6DA);
  static const expiryDark = Color(0xFF302827);
  // 旅行：远山青绿,与暖橙互补;travelInk 用于地图上去过城市的强调点/文字。
  static const travelLight = Color(0xFFCBDAD2);
  static const travelDark = Color(0xFF2D2B22);
  static const travelInkLight = Color(0xFF3E7A66);
  static const travelInkDark = Color(0xFF8FC4AE);
  static const memoryInkLight = Color(0xFF8B5A3C);
  static const memoryInkDark = Color(0xFFE6B89A);

  // 语义强调色（预算见底等）：黄=warning，红=danger。需在卡片底色上可读。
  static const warningLight = Color(0xFFC98A00);
  static const dangerLight = Color(0xFFC0392B);
  static const warningDark = Color(0xFFE6B84D);
  static const dangerDark = Color(0xFFF06A5D);

  // ── 圆角 ──────────────────────────────────────────────────────
  static const cardRadius = 20.0;
  static const fabRadius = 20.0;
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
    required this.memory,
    required this.memoryInk,
    required this.stock,
    required this.movie,
    required this.calendar,
    required this.subscribe,
    required this.plant,
    required this.retire,
    required this.expiry,
    required this.travel,
    required this.travelInk,
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
  final Color memory;
  final Color memoryInk;
  final Color stock;
  final Color movie;
  final Color calendar;
  final Color subscribe;
  final Color plant;
  final Color retire;
  final Color expiry;
  final Color travel;
  final Color travelInk;
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
    memory: WoTokens.memoryLight,
    memoryInk: WoTokens.memoryInkLight,
    stock: WoTokens.stockLight,
    movie: WoTokens.movieLight,
    calendar: WoTokens.calendarLight,
    subscribe: WoTokens.subscribeLight,
    plant: WoTokens.plantLight,
    retire: WoTokens.retireLight,
    expiry: WoTokens.expiryLight,
    travel: WoTokens.travelLight,
    travelInk: WoTokens.travelInkLight,
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
    accentDeep: WoTokens.darkAccent,
    accentSoft: WoTokens.darkAccentSoft,
    photo: WoTokens.photoDark,
    money: WoTokens.moneyDark,
    anniv: WoTokens.annivDark,
    chore: WoTokens.choreDark,
    pet: WoTokens.petDark,
    memory: WoTokens.memoryDark,
    memoryInk: WoTokens.memoryInkDark,
    stock: WoTokens.stockDark,
    movie: WoTokens.movieDark,
    calendar: WoTokens.calendarDark,
    subscribe: WoTokens.subscribeDark,
    plant: WoTokens.plantDark,
    retire: WoTokens.retireDark,
    expiry: WoTokens.expiryDark,
    travel: WoTokens.travelDark,
    travelInk: WoTokens.travelInkDark,
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
    Color? memory,
    Color? memoryInk,
    Color? stock,
    Color? movie,
    Color? calendar,
    Color? subscribe,
    Color? plant,
    Color? retire,
    Color? expiry,
    Color? travel,
    Color? travelInk,
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
      memory: memory ?? this.memory,
      memoryInk: memoryInk ?? this.memoryInk,
      stock: stock ?? this.stock,
      movie: movie ?? this.movie,
      calendar: calendar ?? this.calendar,
      subscribe: subscribe ?? this.subscribe,
      plant: plant ?? this.plant,
      retire: retire ?? this.retire,
      expiry: expiry ?? this.expiry,
      travel: travel ?? this.travel,
      travelInk: travelInk ?? this.travelInk,
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
      memory: Color.lerp(memory, other.memory, t)!,
      memoryInk: Color.lerp(memoryInk, other.memoryInk, t)!,
      stock: Color.lerp(stock, other.stock, t)!,
      movie: Color.lerp(movie, other.movie, t)!,
      calendar: Color.lerp(calendar, other.calendar, t)!,
      subscribe: Color.lerp(subscribe, other.subscribe, t)!,
      plant: Color.lerp(plant, other.plant, t)!,
      retire: Color.lerp(retire, other.retire, t)!,
      expiry: Color.lerp(expiry, other.expiry, t)!,
      travel: Color.lerp(travel, other.travel, t)!,
      travelInk: Color.lerp(travelInk, other.travelInk, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

extension WoColorsX on BuildContext {
  WoColors get wo => Theme.of(this).extension<WoColors>()!;
}
