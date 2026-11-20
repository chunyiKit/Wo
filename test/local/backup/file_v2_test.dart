// 测试源码尚未执行。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/backup/package_binding.dart';
import 'package:wo/local/backup/portable_archive.dart';
import 'mobile_backup_client_test.dart' show TestCrypto;

class _SyntheticFile implements BackupSource {
  _SyntheticFile(this.bytes);
  final Uint8List bytes;
  @override BackupEntry get entry=>BackupEntry(id:'opaque_document',kind:'file',size:bytes.length,sha256:hashing.sha256.convert(bytes).toString(),sourceExact:false);
  PortableEntry get portable=>PortableEntry(id:entry.id,kind:'file',size:entry.size,sha256:entry.sha256,sourceExact:false);
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>Stream.value(Uint8List.sublistView(bytes,offset,offset+length));
}
void main(){
  final source=_SyntheticFile(Uint8List.fromList(utf8.encode('%PDF-1.7\nsynthetic private document\n%%EOF\n')));
  test('file使用v2，v1及未知版本不接受file；旧kind仍写v1',(){
    final outer=BackupManifest(familyId:'family',backupId:'backup',entries:[source.entry]);
    final inner=PortableManifest(familyId:'family',entries:[source.portable]);
    expect(outer.version,2);expect(inner.version,2);
    expect(BackupManifest.fromJson(outer.toJson()).version,2);
    expect(PortableManifest.fromJson(inner.toJson()).version,2);
    for(final version in [0,1,3]){
      expect(()=>BackupManifest.fromJson({...outer.toJson(),'version':version}),throwsA(isA<BackupException>()));
      expect(()=>PortableManifest.fromJson({...inner.toJson(),'version':version}),throwsA(isA<BackupException>()));
    }
    final records=BackupEntry(id:'records',kind:'records',size:1,sha256:'a'*64,sourceExact:false);
    expect(BackupManifest(familyId:'family',backupId:'backup',entries:[records]).version,1);
    expect(PortableManifest(familyId:'family',entries:[]).version,1);
    for(final size in [backupMaxAttachmentBytes+1,0]){
      expect(()=>BackupEntry(id:'document',kind:'file',size:size,sha256:'a'*64,sourceExact:false),throwsA(isA<BackupException>()));
      expect(()=>PortableEntry(id:'document',kind:'file',size:size,sha256:'a'*64,sourceExact:false),throwsA(isA<BackupException>()));
    }
    expect(()=>BackupEntry(id:'document',kind:'file',size:1,sha256:'a'*64,sourceExact:true),throwsA(isA<BackupException>()));
    expect(()=>PortableEntry(id:'document',kind:'file',size:1,sha256:'a'*64,sourceExact:true),throwsA(isA<BackupException>()));
    expect(PortableManifest(familyId:'family',entries:[PortableEntry(id:'lost',kind:'file',size:0,sha256:'',sourceExact:false,missingReason:'permission_denied')]).version,2);
  });
  test('file同包index写v2并拒v1file、未知版本和错误SHA inventory',(){
    final entries=[source.portable.toJson()];
    final bytes=BackupPackageBinding.create(familyId:'family',backupId:'backup',sealedId:'sealed',publicEntries:[],restrictedEntries:entries);
    final raw=jsonDecode(utf8.decode(bytes)) as Map<String,dynamic>;expect(raw['version'],2);
    final outer=BackupManifest(familyId:'family',backupId:'backup',entries:[BackupEntry(id:'sealed',kind:'sealed',size:200,sha256:'b'*64,sourceExact:false)]);
    BackupPackageBinding.validate(bytes,outer:outer,sealedId:'sealed',innerEntries:entries);
    for(final version in [0,1,3]){
      expect(()=>BackupPackageBinding.validate(Uint8List.fromList(utf8.encode(jsonEncode({...raw,'version':version}))),outer:outer,sealedId:'sealed',innerEntries:entries),throwsA(isA<BackupException>()));
    }
    expect(()=>BackupPackageBinding.validate(bytes,outer:outer,sealedId:'sealed',innerEntries:[{...entries.single,'sha256':'c'*64}]),throwsA(isA<BackupException>()));
  });
  test('file恢复新私有文件后再pack的字节SHA不变',()async{
    final parent=await Directory.systemTemp.createTemp('wo-file-v2-');
    try{
      final archive=PortableArchive(TestCrypto()),manifest=PortableManifest(familyId:'family',entries:[source.portable]);
      final restore=await archive.restoreToNewDirectory(archive.pack(manifest,{source.entry.id:source}),parent,expectedFamily:'family');
      final recovered=restore.files[source.entry.id]!;
      expect(recovered.newId,isNot(source.entry.id));expect(await recovered.file.readAsBytes(),source.bytes);
      expect(restore.restricted,true);expect(restore.recordsApplied,false);expect(restore.fullDeviceComplete,false);
      final readBack=_SyntheticFile(await recovered.file.readAsBytes());
      final again=await archive.restoreToNewDirectory(archive.pack(manifest,{source.entry.id:readBack}),parent,expectedFamily:'family');
      expect(hashing.sha256.convert(await again.files[source.entry.id]!.file.readAsBytes()).toString(),source.entry.sha256);
    }finally{await parent.delete(recursive:true);}
  },skip:Platform.isWindows);
}
