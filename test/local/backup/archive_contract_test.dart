import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/backup/backup_transport.dart';
import 'package:wo/local/backup/portable_archive.dart';
import 'package:wo/local/backup/quarantine_store.dart';
import 'package:wo/local/backup/restricted_backup.dart';
import 'package:wo/local/backup/vault_codec.dart';
import 'mobile_backup_client_test.dart' show TestCrypto;

Uint8List unhex(String s)=>Uint8List.fromList(List.generate(s.length~/2,(i)=>int.parse(s.substring(i*2,i*2+2),radix:16)));
Future<Uint8List> collect(Stream<List<int>> stream)async{final b=BytesBuilder();await for(final c in stream){b.add(c);}return b.takeBytes();}
Future<Map<String,dynamic>> vector()async=>jsonDecode(await File('test/local/backup/fixtures/v1.json').readAsString()) as Map<String,dynamic>;

/// 模拟 native 的固定答案，只验证 Dart 的组帧/参数；AES由Go oracle验证，不冒称native实测。
class VectorCrypto extends TestCrypto {
  VectorCrypto(this.v);final Map<String,dynamic> v;int sealCalls=0;
  @override Future<Uint8List> random(int count)async{if(count==40)return unhex(v['random'] as String);return await super.random(count);}
  Map<String,dynamic> frame(Uint8List key,Uint8List nonce,Uint8List aad){
    if(backupHex(key)!=v['derived_key'])throw const BackupException('mock_auth');
    for(final f in v['frames'] as List){final map=f as Map<String,dynamic>;if(backupHex(nonce)==map['nonce']&&backupHex(aad)==map['aad'])return map;}
    throw const BackupException('mock_auth');
  }
  @override Future<Uint8List> seal({required Uint8List key,required Uint8List nonce,required Uint8List plaintext,required Uint8List aad})async{
    final f=frame(key,nonce,aad);expect(backupHex(plaintext),f['plaintext']);sealCalls++;return unhex(f['ciphertext'] as String);
  }
  @override Future<Uint8List> open({required Uint8List key,required Uint8List nonce,required Uint8List ciphertext,required Uint8List aad})async{
    final f=frame(key,nonce,aad);if(backupHex(ciphertext)!=f['ciphertext'])throw const BackupException('mock_auth');return unhex(f['plaintext'] as String);
  }
}
class RestrictedRecords implements BackupSource {
  RestrictedRecords(this.bytes):entry=BackupEntry(id:'records',kind:'records',size:bytes.length,sha256:hashes.sha256.convert(bytes).toString(),sourceExact:false);
  final Uint8List bytes;@override final BackupEntry entry;
  @override BackupPrivacy get privacy=>BackupPrivacy.restricted;
  @override Future<Stream<List<int>>> openRange(int offset,int length)async=>Stream.value(Uint8List.sublistView(bytes,offset,offset+length));
}
PortableManifest manifestOf(Uint8List tar){final size=int.parse(ascii.decode(tar.sublist(124,136)).replaceAll('\u0000','').trim(),radix:8);
  return PortableManifest.fromJson(backupObject(decodeBackupJson(utf8.decode(tar.sublist(512,512+size)))));}
void main(){
  test('Dart GCM call parameters and wire bytes match fixed Go oracle fixture',()async{
    final v=await vector(),crypto=VectorCrypto(await vector());final plain=unhex(v['portable'] as String);
    Stream<List<int>> split()async*{for(var i=0;i<plain.length;i+=17){yield plain.sublist(i,(i+17).clamp(0,plain.length).toInt());}}
    final encoded=await collect(VaultCodec(crypto).encrypt(split(),key:unhex(v['key'] as String),context:VaultContext('family','backup','sealed')));
    expect(backupHex(encoded),v['vault']);expect(crypto.sealCalls,2);
    final verified=await VaultCodec(crypto).verify(Stream.value(encoded),key:unhex(v['key'] as String),context:VaultContext('family','backup','sealed'));
    expect(verified.bytes,plain.length);expect(backupHex(verified.digest),hashes.sha256.convert(plain).toString());
  });
  test('Dart verifier rejects wrong key/context, truncation and appended bytes with mock AEAD',()async{
    final v=await vector(),crypto=VectorCrypto(await vector());final wire=unhex(v['vault'] as String),key=unhex(v['key'] as String);final codec=VaultCodec(crypto);
    final wrong=Uint8List.fromList(key);wrong[0]^=1;
    await expectLater(codec.verify(Stream.value(wire),key:wrong,context:VaultContext('family','backup','sealed')),throwsA(isA<BackupException>()));
    await expectLater(codec.verify(Stream.value(wire),key:key,context:VaultContext('other','backup','sealed')),throwsA(isA<BackupException>()));
    for(final bad in [wire.sublist(0,51),wire.sublist(0,wire.length-1),[...wire,0]]){
      await expectLater(codec.verify(Stream.value(bad),key:key,context:VaultContext('family','backup','sealed')),throwsA(isA<BackupException>()));
    }
  });
  test('portable pack matches GNU physical header fixture and retains declared missing original',()async{
    final v=await vector(),tar=unhex((await vector())['portable'] as String);final manifest=manifestOf(tar),entry=manifest.entries.first;
    final source=RestrictedRecords(Uint8List.sublistView(tar,1536,1536+entry.size));
    final packed=await collect(PortableArchive(TestCrypto()).pack(manifest,{'records':source}));expect(backupHex(packed),v['portable']);
    expect(manifest.entries.last.missingReason,'source_unavailable');expect(utf8.decode(source.bytes).contains('content://'),false);
  });
  test('portable restore uses new IDs and inert files; missing media remains incomplete and restricted',()async{
    final v=await vector();final parent=await Directory.systemTemp.createTemp('wo-synthetic-portable-');addTearDown(()=>parent.delete(recursive:true));
    final result=await PortableArchive(TestCrypto()).restoreToNewDirectory(Stream.value(unhex(v['portable'] as String)),parent,expectedFamily:'family');
    expect(result.sourceFamilyId,'family');expect(result.manifest.entries.length,2);
    expect(result.newFamilyId,isNot('family'));expect(result.newDeviceId,isNotEmpty);expect(result.recordsApplied,false);expect(result.restricted,true);
    expect(result.missing['missing-photo'],'source_unavailable');expect(result.declaredBytesComplete,false);expect(result.fullDeviceComplete,false);
    expect(result.files['records']!.newId,isNot('records'));expect(await result.files['records']!.file.exists(),true);
  },skip:Platform.isWindows);
  test('wrong family, bad data and duplicate-key portable manifests do not publish success',()async{
    final tar=unhex((await vector())['portable'] as String);final parent=await Directory.systemTemp.createTemp('wo-synthetic-invalid-');addTearDown(()=>parent.delete(recursive:true));
    final archive=PortableArchive(TestCrypto());
    await expectLater(archive.restoreToNewDirectory(Stream.value(tar),parent,expectedFamily:'other'),throwsA(isA<BackupException>()));
    final corrupt=Uint8List.fromList(tar);corrupt[1536]^=1;
    await expectLater(archive.restoreToNewDirectory(Stream.value(corrupt),parent,expectedFamily:'family'),throwsA(isA<BackupException>()));
    expect(await parent.list().toList(),isEmpty);
    expect(()=>decodeBackupJson('{"family_id":"family","family_id":"other"}'),throwsA(isA<BackupException>()));
  },skip:Platform.isWindows);
  test('restricted restore reads only ciphertext and recovery key; rebackup preserves source bytes without old grants',()async{
    final v=await vector(),crypto=VectorCrypto(await vector());final parent=await Directory.systemTemp.createTemp('wo-synthetic-restricted-');addTearDown(()=>parent.delete(recursive:true));
    final bytes=unhex(v['vault'] as String);final cipher=File('${parent.path}${Platform.pathSeparator}cipher');await cipher.writeAsBytes(bytes,flush:true);
    await crypto.putSecret('wo.backup.recovery.synthetic',unhex(v['key'] as String));
    final entry=BackupEntry(id:'sealed',kind:'sealed',size:bytes.length,sha256:hashes.sha256.convert(bytes).toString(),sourceExact:false);
    final result=await restoreRestrictedBackup(entry:entry,ciphertext:cipher,expectedFamily:'family',backupId:'backup',
      recoveryKeyRef:'wo.backup.recovery.synthetic',privateParent:parent,crypto:crypto);
    final inert=result.files['records']!;final restored=await inert.file.readAsBytes();expect(hashes.sha256.convert(restored).toString(),inert.entry.sha256);
    expect(result.newDeviceId,isNot('old-device'));expect(result.restricted,true);expect(result.recordsApplied,false);
    final manifest=manifestOf(unhex(v['portable'] as String));
    final packed=await collect(PortableArchive(crypto).pack(manifest,{'records':RestrictedRecords(restored)}));expect(backupHex(packed),v['portable']);
    expect(await parent.list().any((e)=>e is Directory&&e.path.contains('wo-vault-')),false);
  },skip:Platform.isWindows);
  test('quarantine resume rehashes committed ranges; final SHA and cache are independent of database',()async{
    final parent=await Directory.systemTemp.createTemp('wo-synthetic-download-');addTearDown(()=>parent.delete(recursive:true));
    final bytes=Uint8List.fromList([1,2,3,4]);final entry=BackupEntry(id:'records',kind:'records',size:4,sha256:hashes.sha256.convert(bytes).toString(),sourceExact:false);
    final manifest=BackupManifest(familyId:'family',backupId:'backup',entries:[entry]);final store=await QuarantineStore.create(parent);await store.bind(manifest);
    final first=Uint8List.sublistView(bytes,0,2);await store.append(entry,0,first,hashes.sha256.convert(first).toString());
    final resumed=await QuarantineStore.resume(store.directory,parent,manifest);expect(await resumed.verifiedOffset(entry),2);
    final last=Uint8List.sublistView(bytes,2);await resumed.append(entry,2,last,hashes.sha256.convert(last).toString());await resumed.finish(manifest);
    expect(await (await resumed.materializeVerifiedFile(entry)).readAsBytes(),bytes);
    final range=await Directory('${store.directory.path}${Platform.pathSeparator}ranges').list().first;
    await File('${range.path}${Platform.pathSeparator}bytes').writeAsBytes([9,9],flush:true);
    await expectLater(QuarantineStore.resume(store.directory,parent,manifest),throwsA(isA<BackupException>()));
  },skip:Platform.isWindows);
}
