// 只准备3项组合层回归，未执行Dart；此层不冒充Vault认证，真实AEAD由Go另验。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/backup/package_binding.dart';
import 'package:wo/local/backup/portable_archive.dart';
import 'package:wo/local/backup/quarantine_store.dart';
import 'mobile_backup_client_test.dart' show TestCrypto;

class _Source implements BackupSource {
  _Source(this.id,this.kind,this.bytes,{this.exact=false});final String id,kind;final Uint8List bytes;final bool exact;
  @override BackupEntry get entry=>BackupEntry(id:id,kind:kind,size:bytes.length,sha256:hashing.sha256.convert(bytes).toString(),sourceExact:exact);
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>Stream.value(bytes.sublist(offset,offset+length));
  PortableEntry get portable=>PortableEntry(id:id,kind:kind,size:bytes.length,sha256:entry.sha256,sourceExact:exact);
}
void main(){
  late Directory root;late TestCrypto crypto;
  final photo=_Source('original','photo',Uint8List.fromList(List.generate(128,(i)=>i)),exact:true);
  final records=_Source('records','records',Uint8List.fromList(utf8.encode('{"synthetic":"private-only"}')));
  final sealed=_Source('sealed','sealed',Uint8List(121)); // 仅外层字节缓存替身，无AES声明。
  _Source coverageSource(List<String> reasons)=>_Source(BackupPackageBinding.coverageEntryId,'records',BackupPackageBinding.coverage('family',reasons));
  Uint8List index({List<String> coverage=const []})=>BackupPackageBinding.create(familyId:'family',backupId:'backup',sealedId:'sealed',publicEntries:[photo.entry],restrictedEntries:[records.portable.toJson(),if(coverage.isNotEmpty)coverageSource(coverage).portable.toJson()]);
  Future<PortableRestore> inner({bool includeIndex=true,Uint8List? binding,List<String> coverage=const []})async{
    final sources=[records,if(coverage.isNotEmpty)coverageSource(coverage),if(includeIndex)_Source(BackupPackageBinding.entryId,'records',binding??index(coverage:coverage))];
    final manifest=PortableManifest(familyId:'family',entries:sources.map((s)=>s.portable));
    return PortableArchive(crypto).restoreToNewDirectory(PortableArchive(crypto).pack(manifest,{for(final s in sources)s.id:s}),root,expectedFamily:'family');
  }
  BackupManifest outer()=>BackupManifest(familyId:'family',backupId:'backup',entries:[photo.entry,sealed.entry]);
  Future<QuarantineStore> receiver(BackupManifest manifest)async{
    final store=await QuarantineStore.create(root);await store.bind(manifest);
    for(final s in [photo,sealed]){await store.append(s.entry,0,s.bytes,s.entry.sha256);}
    await store.finish(manifest);return store;
  }
  setUp(()async{root=await Directory.systemTemp.createTemp('wo-package-test-');crypto=TestCrypto();});
  tearDown(()async{await root.delete(recursive:true);});
  test('同包绑定后只生成新私有文件；照片SHA及原始records保持不变',()async{
    final source=await inner(coverage:['unbound_ancestor_public']),manifest=outer(),cache=await receiver(outer());
    final result=await PortableArchive(crypto).bindOuterPackage(source,manifest,'sealed',cache);
    expect(result.packageBound,true);expect(result.excludedPublicEntries,0);expect(result.coverageIssues,['unbound_ancestor_public']);expect(result.declaredBytesComplete,false);expect(result.restricted,true);expect(result.fullDeviceComplete,false);
    final original=result.files['original']!;expect(original.newId,isNot('original'));
    expect(hashing.sha256.convert(await original.file.readAsBytes()).toString(),photo.entry.sha256);
    expect(await result.files['records']!.file.readAsBytes(),records.bytes);expect(result.packageOrigin!['backup_id'],'backup');
  },skip:Platform.isWindows);
  test('同ID换包、元数据变更与损坏索引不能回落到legacy关联',()async{
    final source=await inner(),bytes=index();
    final changed=BackupEntry(id:'original',kind:'photo',size:photo.entry.size,sha256:'a'*64,sourceExact:true);
    final wrong=BackupManifest(familyId:'family',backupId:'backup',entries:[changed,sealed.entry]);
    expect(()=>BackupPackageBinding.validate(bytes,outer:wrong,sealedId:'sealed',innerEntries:source.manifest.entries.map((e)=>e.toJson())),throwsA(isA<BackupException>()));
    final other=BackupManifest(familyId:'family',backupId:'other',entries:outer().entries);
    expect(()=>BackupPackageBinding.validate(bytes,outer:other,sealedId:'sealed',innerEntries:source.manifest.entries.map((e)=>e.toJson())),throwsA(isA<BackupException>()));
    final map=jsonDecode(utf8.decode(bytes)) as Map<String,dynamic>;map['version']=2;
    final corrupt=await inner(binding:Uint8List.fromList(utf8.encode(jsonEncode(map))));
    await expectLater(PortableArchive(crypto).bindOuterPackage(corrupt,outer(),'sealed',await receiver(outer())),throwsA(isA<BackupException>()));
  },skip:Platform.isWindows);
  test('没有索引的旧归档只保留内层，不按相同ID收取公开文件',()async{
    final source=await inner(includeIndex:false),result=await PortableArchive(crypto).bindOuterPackage(await inner(includeIndex:false),outer(),'sealed',await receiver(outer()));
    expect(result.packageBound,false);expect(result.excludedPublicEntries,1);expect(result.declaredBytesComplete,false);
    expect(result.files.keys,['records']);expect(source.fullDeviceComplete,false);
  },skip:Platform.isWindows);
}
