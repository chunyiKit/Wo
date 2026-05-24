import 'package:flutter/material.dart';

import 'wo_tokens.dart';

/// 把后端返回的 `color_token`（photo / money / anniv / chore / pet / accent）
/// 映射成本地设计色。见 docs/backend-contract.md §5.6。
extension WoColorTokenX on WoColors {
  Color colorForToken(String token) {
    switch (token) {
      case 'photo':
        return photo;
      case 'money':
        return money;
      case 'anniv':
        return anniv;
      case 'chore':
        return chore;
      case 'pet':
        return pet;
      case 'accent':
      default:
        return accent;
    }
  }

  /// accent 卡片用实心暖橙 + 白字（与原设计里的「纪念日」强调卡一致）。
  bool isEmphasizedToken(String token) => token == 'accent';
}
