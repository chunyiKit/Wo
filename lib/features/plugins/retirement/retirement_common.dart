import 'package:flutter/material.dart';

/// 退休倒计时插件的共享文案 / 颜色 / 金额格式化。

/// 「需要增加（缺口）」用的绿色。盈余用主题里的 `wo.danger`（红），呼应中式红涨绿跌：
/// +盈余=红，−缺口=绿，与产品约定一致。
const retireGreen = Color(0xFF2E9E5B);

/// 账户类型 → 中文 / emoji。
const accountKinds = ['deposit', 'fund'];
String accountKindLabel(String kind) => switch (kind) {
      'deposit' => '存款',
      'fund' => '公积金',
      _ => kind,
    };
String accountKindEmoji(String kind) => switch (kind) {
      'deposit' => '🏦',
      'fund' => '🏛️',
      _ => '🏦',
    };

/// 负债类型 → 中文 / emoji。
const debtKinds = ['mortgage', 'car', 'other'];
String debtKindLabel(String kind) => switch (kind) {
      'mortgage' => '房贷',
      'car' => '车贷',
      'other' => '其他',
      _ => kind,
    };
String debtKindEmoji(String kind) => switch (kind) {
      'mortgage' => '🏠',
      'car' => '🚗',
      'other' => '💳',
      _ => '🏠',
    };

/// 目标进度口径文案。
const goalBases = ['net_worth', 'total_assets', 'deposit_only'];
String goalBasisLabel(String b) => switch (b) {
      'net_worth' => '净资产（资产−负债）',
      'total_assets' => '总资产（不减负债）',
      'deposit_only' => '仅存款账户',
      _ => b,
    };

/// 月结余口径文案。
const surplusBases = ['income_debt_expense', 'income_debt', 'income_only'];
String surplusBasisLabel(String b) => switch (b) {
      'income_debt_expense' => '收入 − 负债 − 支出',
      'income_debt' => '收入 − 负债',
      'income_only' => '仅月收入',
      _ => b,
    };

/// 流水类型 → 中文 / emoji。
String ledgerKindLabel(String k) => switch (k) {
      'income' => '收入入账',
      'debt_payment' => '月供扣款',
      'expense_settle' => '支出结算',
      _ => k,
    };
String ledgerKindEmoji(String k) => switch (k) {
      'income' => '💰',
      'debt_payment' => '🏠',
      'expense_settle' => '🧮',
      _ => '•',
    };

/// `¥1,234`，整数省略小数；[sign] 为 true 时带 +/−（用于盈余/缺口）。
String yuan(double v, {bool sign = false}) {
  final neg = v < 0;
  final abs = v.abs();
  final whole = abs == abs.roundToDouble();
  final body = _group(abs.toStringAsFixed(whole ? 0 : 2));
  final prefix = sign ? (neg ? '−' : '+') : (neg ? '−' : '');
  return '$prefix¥$body';
}

/// 给整数部分加千分位。
String _group(String numText) {
  final dot = numText.indexOf('.');
  final intPart = dot == -1 ? numText : numText.substring(0, dot);
  final frac = dot == -1 ? '' : numText.substring(dot);
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }
  return '$buf$frac';
}
