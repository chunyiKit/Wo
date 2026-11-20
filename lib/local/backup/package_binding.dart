import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashing;
import 'backup_models.dart';

/// 位于已认证sealed内部，关联同一包的公开字节；不是成员/原操作来源证明。
class BackupPackageBinding {
  static const entryId='wo_backup_package_binding_v1';
  static const coverageEntryId='wo_restore_coverage_v1';
  static const coverageReasons={'unbound_ancestor_public','ancestor_coverage_unknown'};
  static Uint8List coverage(String familyId,Iterable<String> reasons){
    final list=reasons.toSet().toList()..sort();
    if(!validBackupId(familyId)||list.any((e)=>!coverageReasons.contains(e)))throw const BackupException('invalid_recovery_coverage');
    return Uint8List.fromList(utf8.encode(jsonEncode({'version':1,'kind':'wo_restore_coverage','family_id':familyId,'reasons':list})));
  }
  static List<String> readCoverage(Uint8List bytes,String familyId){
    if(bytes.length>65536)throw const BackupException('invalid_recovery_coverage');
    final j=backupObject(decodeBackupJson(utf8.decode(bytes,allowMalformed:false)));
    if(j.length!=4||j['version'] is! int||j['version']!=1||j['kind']!='wo_restore_coverage'||j['family_id']!=familyId||j['reasons'] is! List)throw const BackupException('invalid_recovery_coverage');
    final list=j['reasons'] as List;if(list.length>coverageReasons.length||list.any((e)=>e is! String||!coverageReasons.contains(e))||list.toSet().length!=list.length)throw const BackupException('invalid_recovery_coverage');
    return List<String>.unmodifiable(list.cast<String>());
  }
  static const maxBytes=8*1024*1024;
  static Object? _ordered(Object? value){
    if(value is Map){final keys=value.keys.cast<String>().toList()..sort();return {for(final key in keys)key:_ordered(value[key])};}
    if(value is List)return value.map(_ordered).toList();return value;
  }
  static String _canonical(Object? value)=>jsonEncode(_ordered(value));
  static List<Map<String,dynamic>> _inventory(Iterable<Map<String,dynamic>> rows){
    final list=rows.map((e)=>Map<String,dynamic>.from(e)).toList();
    if(list.any((e)=>e['id'] is! String))throw const BackupException('package_binding_invalid');
    list.sort((a,b)=>(a['id'] as String).compareTo(b['id'] as String));return list;
  }
  static void _identities(String family,String backup,String sealed,List<Map<String,dynamic>> public,List<Map<String,dynamic>> restricted){
    if(sealed.toLowerCase()==entryId||!validBackupId(family)||!validBackupId(backup)||!validBackupId(sealed)||public.length>4095||restricted.length>19999||public.length+restricted.length>19999)throw const BackupException('package_binding_limit');
    final ids=<String>{entryId.toLowerCase(),sealed.toLowerCase()};
    for(final row in [...public,...restricted]){
      final id=row['id'];if(id is! String||!validBackupId(id)||!ids.add(id.toLowerCase()))throw const BackupException('package_binding_collision');
    }
  }
  static int _inventoryVersion(List<Map<String,dynamic>> public,List<Map<String,dynamic>> restricted){
    for(final e in [...public,...restricted]){
      if(e['kind']=='file'&&(e['size'] is! int||(e['size'] as int)>backupMaxAttachmentBytes||e['source_exact']==true))throw const BackupException('package_file_limit');
    }
    return [...public,...restricted].any((e)=>e['kind']=='file')?2:1;
  }
  static Uint8List create({required String familyId,required String backupId,required String sealedId,
      required Iterable<BackupEntry> publicEntries,required Iterable<Map<String,dynamic>> restrictedEntries}){
    final public=_inventory(publicEntries.map((e)=>e.toJson())),restricted=_inventory(restrictedEntries);
    if(public.any((e)=>!{'photo','video','thumbnail','file'}.contains(e['kind'])))throw const BackupException('package_public_kind');
    _identities(familyId,backupId,sealedId,public,restricted);
    final bytes=Uint8List.fromList(utf8.encode(_canonical({'version':_inventoryVersion(public,restricted),'kind':'wo_backup_package_binding',
      'family_id':familyId,'backup_id':backupId,'sealed_id':sealedId,'public_entries':public,'restricted_entries':restricted})));
    final total=[...public,...restricted].fold<int>(bytes.length,(sum,row)=>sum+(row['size'] as int));
    if(total>100*1024*1024*1024)throw const BackupException('package_total_limit');
    if(bytes.length>maxBytes)throw const BackupException('package_binding_limit');return bytes;
  }
  /// 必须在匹配VaultContext认证后调用；outer与inner均已严格解析和验证文件SHA。
  static void validate(Uint8List bytes,{required BackupManifest outer,required String sealedId,
      required Iterable<Map<String,dynamic>> innerEntries}){
    if(bytes.isEmpty||bytes.length>maxBytes)throw const BackupException('package_binding_limit');
    final j=backupObject(decodeBackupJson(utf8.decode(bytes,allowMalformed:false)));
    if(j.length!=7||j.keys.any((k)=>!{'version','kind','family_id','backup_id','sealed_id','public_entries','restricted_entries'}.contains(k))||
      j['version'] is! int||![1,2].contains(j['version'])||j['kind']!='wo_backup_package_binding'||j['family_id']!=outer.familyId||j['backup_id']!=outer.backupId||j['sealed_id']!=sealedId||
      j['public_entries'] is! List||j['restricted_entries'] is! List)throw const BackupException('package_binding_context');
    final sealed=outer.entries.where((e)=>e.kind=='sealed').toList();if(sealed.length!=1||sealed.single.id!=sealedId)throw const BackupException('package_binding_context');
    final public=_inventory((j['public_entries'] as List).map(backupObject)),restricted=_inventory((j['restricted_entries'] as List).map(backupObject));
    _identities(outer.familyId,outer.backupId,sealedId,public,restricted);
    final requiredVersion=_inventoryVersion(public,restricted);
    if(j['version']==1&&requiredVersion==2)throw const BackupException('package_binding_version');
    if([...public,...restricted].any((e)=>e['size'] is! int))throw const BackupException('package_binding_invalid');
    if([...public,...restricted].fold<int>(bytes.length,(sum,row)=>sum+(row['size'] as int))>100*1024*1024*1024)throw const BackupException('package_total_limit');
    final expectedPublic=_inventory(outer.entries.where((e)=>e.kind!='sealed').map((e)=>e.toJson()));
    final expectedRestricted=_inventory(innerEntries.where((e)=>e['id']!=entryId));
    if(_canonical(public)!=_canonical(expectedPublic)||_canonical(restricted)!=_canonical(expectedRestricted))throw const BackupException('package_binding_inventory');
    if(expectedPublic.any((e)=>!{'photo','video','thumbnail','file'}.contains(e['kind'])))throw const BackupException('package_public_kind');
  }
  static String digest(Uint8List bytes)=>hashing.sha256.convert(bytes).toString();
}

class PackageBindingSource implements BackupSource {
  PackageBindingSource(Uint8List bytes,{String id=BackupPackageBinding.entryId}):_bytes=Uint8List.fromList(bytes),entry=BackupEntry(
    id:id,kind:'records',size:bytes.length,sha256:BackupPackageBinding.digest(bytes),sourceExact:false);
  final Uint8List _bytes;
  @override final BackupEntry entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async{
    if(offset<0||length<0||offset+length>_bytes.length)throw const BackupException('invalid_source_range');
    return Stream.value(Uint8List.sublistView(_bytes,offset,offset+length));
  }
}
