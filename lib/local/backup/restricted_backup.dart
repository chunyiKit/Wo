import 'dart:io';
import 'dart:typed_data';
import '../transport/native_local.dart';
import 'archive_io.dart';
import 'backup_models.dart';
import 'backup_transport.dart';
import 'portable_archive.dart';
import 'vault_codec.dart';
import 'quarantine_store.dart';

/// 只返回native secret引用。恢复者导出/保存密钥必须由显式UI另行完成；只有本机ref不等于可灾备。
Future<String> createBackupRecoveryKey(LocalCrypto crypto)async{
  final bytes=await crypto.random(32);
  try{return await importBackupRecoveryKey(crypto,bytes);}finally{bytes.fillRange(0,bytes.length,0);}
}
Future<String> importBackupRecoveryKey(LocalCrypto crypto,Uint8List bytes)async{
  if(bytes.length!=32)throw const BackupException('invalid_recovery_key');
  final random=await crypto.random(16);if(random.length!=16)throw const BackupException('invalid_random');
  final ref='wo.backup.recovery.${backupHex(random)}';final copy=Uint8List.fromList(bytes);
  try{await crypto.putSecret(ref,copy);return ref;}finally{copy.fillRange(0,copy.length,0);}
}

/// 输入必须来自隔离缓存，先核对外层全文SHA，再认证vault及内层清单/文件SHA。
/// 返回新隔离目录、媒体新ID和新家庭/设备身份；不导库，不重用旧权限或伴侣关系。
Future<PortableRestore> restoreRestrictedBackup({required BackupEntry entry,required File ciphertext,
    required String expectedFamily,required String backupId,required String recoveryKeyRef,
    required Directory privateParent,required LocalCrypto crypto,BackupManifest? outerManifest,QuarantineStore? receiver})async{
  if(entry.kind!='sealed'||!validBackupId(expectedFamily)||!validBackupId(backupId)||
      await FileSystemEntity.type(ciphertext.path,followLinks:false)!=FileSystemEntityType.file)throw const BackupException('invalid_restricted_restore');
  final hash=ArchiveSha256();var size=0;
  await for(final chunk in ciphertext.openRead()){size+=chunk.length;if(size>entry.size)throw const BackupException('ciphertext_digest_mismatch');hash.add(chunk);}
  if(size!=entry.size||backupHex(hash.finish())!=entry.sha256)throw const BackupException('ciphertext_digest_mismatch');
  if((outerManifest==null)!=(receiver==null))throw const BackupException('package_receiver_mismatch');
  if(outerManifest!=null&&(outerManifest.familyId!=expectedFamily||outerManifest.backupId!=backupId||!receiver!.verifiedFor(outerManifest)))throw const BackupException('package_receiver_mismatch');
  if(outerManifest!=null){final matches=outerManifest.entries.where((e)=>e.kind=='sealed'&&e.id==entry.id).toList();
    if(matches.length!=1||matches.single.size!=entry.size||matches.single.sha256!=entry.sha256||matches.single.sourceExact!=entry.sourceExact||matches.single.missing!=entry.missing||matches.single.label!=entry.label)throw const BackupException('package_receiver_mismatch');}
  final key=await crypto.getSecret(recoveryKeyRef);if(key==null||key.length!=32)throw const BackupException('recovery_key_unavailable');
  VaultPlaintextStage? stage;PortableRestore? recovered;
  try{
    stage=await VaultCodec(crypto).decryptToNewStaging(ciphertext,privateParent,key:key,context:VaultContext(expectedFamily,backupId,entry.id));
    recovered=await PortableArchive(crypto).restoreToNewDirectory(stage.file.openRead(),privateParent,expectedFamily:expectedFamily);
    if(outerManifest!=null)return await PortableArchive(crypto).bindOuterPackage(recovered,outerManifest,entry.id,receiver!);
    return recovered;
  }catch(_){if(recovered!=null){try{await recovered.directory.delete(recursive:true);}catch(_){}}rethrow;}finally{key.fillRange(0,key.length,0);if(stage!=null)await stage.dispose();}
}
