import '../backup/backup_models.dart' show decodeBackupJson;
/// 共用已限制深度并拒绝重复键的本地协议JSON检查器，不调用任何远端服务。
Object? decodeStrictJson(String raw)=>decodeBackupJson(raw);
