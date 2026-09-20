/// 到期管家的内置类型：证件 / 年检 / 保险 / 合同 / 会员卡 等。
///
/// 后端只存 [code]（稳定标识，见 expiry/models.py 的 ALLOWED_KINDS），
/// label / emoji 在客户端定义。选中某个类型时默认带上它的 [emoji]，用户仍可改。
class ExpiryKind {
  const ExpiryKind(this.code, this.label, this.emoji);

  final String code;
  final String label;
  final String emoji;
}

const expiryKinds = <ExpiryKind>[
  ExpiryKind('id_card', '身份证', '🪪'),
  ExpiryKind('passport', '护照', '📘'),
  ExpiryKind('visa', '签证', '🛂'),
  ExpiryKind('driver_license', '驾照', '🚗'),
  ExpiryKind('vehicle_inspection', '车辆年检', '🔧'),
  ExpiryKind('insurance', '保险', '🛡️'),
  ExpiryKind('contract', '合同', '📝'),
  ExpiryKind('membership', '会员卡', '🎫'),
  ExpiryKind('household', '房产/户口', '🏠'),
  ExpiryKind('other', '其他', '📄'),
];

ExpiryKind kindFor(String code) => expiryKinds.firstWhere(
      (k) => k.code == code,
      orElse: () => const ExpiryKind('other', '其他', '📄'),
    );
