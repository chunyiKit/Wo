// 已准备；当前未运行Dart/Flutter/SDK，不等于原生文件系统或密码运行验收。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/local/backup/backup_models.dart';
import 'package:wo/local/backup/pending_upload_journal.dart';
import 'mobile_backup_client_test.dart' show TestCrypto;

class JournalSource implements BackupSource {
  JournalSource(String id, List<int> bytes, {String kind = 'sealed', BackupPrivacy? privacy, String missing = ''})
    : bytes = Uint8List.fromList(bytes), privacy = privacy ?? (kind == 'sealed' ? BackupPrivacy.restricted : BackupPrivacy.public),
      entry = BackupEntry(id: id, kind: kind, size: bytes.length,
        sha256: missing.isEmpty ? hashes.sha256.convert(bytes).toString() : '', sourceExact: kind == 'photo' && missing.isEmpty, missing: missing);
  Uint8List bytes;
  int opens = 0;
  @override final BackupEntry entry;
  @override final BackupPrivacy privacy;
  @override Future<Stream<List<int>>> openRange(int offset, int length) async {
    opens++;
    return Stream.value(Uint8List.sublistView(bytes, offset, offset + length));
  }
}

void main() {
  late Directory directory;
  late TestCrypto crypto;
  late PendingUploadJournal journal;
  late PendingUploadBinding binding;
  late PairedComputer computer;
  const tokenRef = 'wo.backup.token.11111111111111111111111111111111';
  const keyRef = 'wo.backup.recovery.22222222222222222222222222222222';
  Matcher code(String expected) => throwsA(isA<BackupException>().having((e) => e.code, 'code', expected));
  JournalSource sealed([String id = 'opaque']) => JournalSource(id, List<int>.generate(512, (i) => i % 251));
  BackupManifest manifest(Iterable<BackupSource> sources, [String id = 'backup-one']) => BackupManifest(familyId: 'family', backupId: id, entries: sources.map((source) => source.entry));
  Future<Uint8List> bytes(BackupSource source) async {
    final output = BytesBuilder(copy: false);
    await for (final chunk in await source.openRange(0, source.entry.size)) { output.add(chunk); }
    return output.takeBytes();
  }
  Future<PendingUploadBinding> fresh({String family = 'family', String device = 'device', String? pin, String? origin}) =>
    PendingUploadBinding.current(computer: PairedComputer(origin: Uri.parse(origin ?? 'https://127.0.0.1:9443'),
      pin: pin ?? 'f' * 64, familyId: family, deviceId: device, tokenRef: tokenRef),
      familyId: family, deviceId: device, recoveryKeyRef: keyRef, crypto: crypto);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wo-pending-journal-');
    crypto = TestCrypto(); await crypto.putSecret(tokenRef, Uint8List.fromList(ascii.encode('b' * 64)));
    await crypto.putSecret(keyRef, Uint8List.fromList(List.filled(32, 0x42)));
    computer = PairedComputer(origin: Uri.parse('https://127.0.0.1:9443'), pin: 'f' * 64, familyId: 'family', deviceId: 'device', tokenRef: tokenRef);
    binding = await PendingUploadBinding.current(computer: computer, familyId: 'family', deviceId: 'device', recoveryKeyRef: keyRef, crypto: crypto);
    journal = PendingUploadJournal(privateParent: directory);
  });
  tearDown(() async { await directory.delete(recursive: true); });

  test('复制原sealed密文后跨对象重启续传，无重新加密或来源重读', () async {
    final source = sealed(), m = manifest([sealed()]);
    final original = Uint8List.fromList(source.bytes);
    final frozen = await journal.freeze(binding: binding, manifest: m, sources: [source],
      coverageNotes: ['合成覆盖'], omittedScopes: ['未适配合成集合'], sourceIssues: {'source_unavailable': 1});
    expect(source.opens, 1); source.bytes.fillRange(0, source.bytes.length, 0);
    final restarted = PendingUploadJournal(privateParent: directory);
    final resumed = (await restarted.resume(await fresh()))!;
    expect(resumed.manifest.canonicalJson, frozen.manifest.canonicalJson);
    expect(await bytes(resumed.sources.single), original);
    expect(source.opens, 1); expect(resumed.coverageNotes, ['合成覆盖']);
    expect(resumed.omittedScopes, ['未适配合成集合']); expect(resumed.sourceIssues, {'source_unavailable': 1});
    expect(resumed.sources.single.privacy, BackupPrivacy.restricted);
    // TestCrypto不实现AES seal/open，本测试只能依靠复制已有密文字节完成。
  }, skip: Platform.isWindows);
  test('有公开授权才可冻结家庭照片，resume不扩大原许可和清单', () async {
    final photo = JournalSource('photo', [1, 2, 3, 4], kind: 'photo'), cipher = sealed();
    await expectLater(journal.freeze(binding: binding, manifest: manifest([photo, cipher]), sources: [photo, cipher]), code('pending_upload_source_mismatch'));
    expect(await journal.exists(), false);
    final frozen = await journal.freeze(binding: binding, manifest: manifest([photo, cipher]), sources: [photo, cipher], allowPublicMediaOnComputer: true);
    final resumed = (await journal.resume(await fresh()))!;
    expect(resumed.allowPublicMediaOnComputer, true); expect(resumed.manifest.canonicalJson, frozen.manifest.canonicalJson);
    expect(resumed.sources.first.privacy, BackupPrivacy.public); expect(await bytes(resumed.sources.first), [1, 2, 3, 4]);
    final record = JournalSource('records', [1], kind: 'records');
    await journal.discard(binding);
    await expectLater(journal.freeze(binding: binding, manifest: manifest([record], 'backup-records'), sources: [record], allowPublicMediaOnComputer: true), code('pending_upload_source_mismatch'));
  }, skip: Platform.isWindows);
  test('源摘要变更保留preparing，匹配绑定可显式放弃但ID永不重用', () async {
    final source = sealed(); source.bytes[0] ^= 1;
    final m = manifest([source]);
    await expectLater(journal.freeze(binding: binding, manifest: m, sources: [source]), code('pending_upload_source_changed'));
    expect(await journal.exists(), true);
    await expectLater(journal.resume(binding), code('pending_upload_not_ready'));
    await expectLater(journal.freeze(binding: binding, manifest: m, sources: [sealed()]), code('pending_upload_already_exists'));
    await journal.discard(binding); expect(await journal.exists(), false);
    await expectLater(journal.freeze(binding: binding, manifest: m, sources: [sealed()]), code('pending_upload_id_already_used'));
    await journal.freeze(binding: binding, manifest: manifest([sealed()], 'new-backup'), sources: [sealed()]);
  }, skip: Platform.isWindows);
  test('不同家庭设备电脑地址或指纹既不能resume也不能删除', () async {
    await journal.freeze(binding: binding, manifest: manifest([sealed()]), sources: [sealed()]);
    for (final changed in [await fresh(family: 'another'), await fresh(device: 'new-device'), await fresh(pin: 'e' * 64), await fresh(origin: 'https://127.0.0.1:9444')]) {
      await expectLater(journal.resume(changed), throwsA(isA<BackupException>()));
      await expectLater(journal.discard(changed), throwsA(isA<BackupException>()));
      expect(await journal.exists(), true);
    }
    expect((await journal.resume(binding))!.manifest.backupId, 'backup-one');
  }, skip: Platform.isWindows);
  test('同ref实际token或恢复钥变化，以及同钥换ref都拒绝恢复', () async {
    await journal.freeze(binding: binding, manifest: manifest([sealed()]), sources: [sealed()]);
    await crypto.putSecret(tokenRef, Uint8List.fromList(ascii.encode('c' * 64)));
    await expectLater(journal.resume(binding), code('pending_upload_binding_changed'));
    await expectLater(journal.resume(await fresh()), throwsA(isA<BackupException>()));
    await crypto.putSecret(tokenRef, Uint8List.fromList(ascii.encode('b' * 64)));
    await crypto.putSecret(keyRef, Uint8List.fromList(List.filled(32, 0x43)));
    await expectLater(journal.resume(await fresh()), throwsA(isA<BackupException>()));
    await crypto.putSecret(keyRef, Uint8List.fromList(List.filled(32, 0x42)));
    const otherRef = 'wo.backup.recovery.33333333333333333333333333333333';
    await crypto.putSecret(otherRef, Uint8List.fromList(List.filled(32, 0x42)));
    final changed = await PendingUploadBinding.current(computer: computer, familyId: 'family', deviceId: 'device', recoveryKeyRef: otherRef, crypto: crypto);
    await expectLater(journal.resume(changed), throwsA(isA<BackupException>()));
    expect(await journal.exists(), true);
  }, skip: Platform.isWindows);
  test('密文文件或受MAC保护清单篡改都拒绝，不自修复或重加密', () async {
    await journal.freeze(binding: binding, manifest: manifest([sealed()]), sources: [sealed()]);
    final payload = File('${directory.path}/${PendingUploadJournal.slotName}/payloads/payload-0000');
    final original = await payload.readAsBytes(), changed = Uint8List.fromList(await payload.readAsBytes()); changed[0] ^= 1;
    await payload.writeAsBytes(changed, flush: true);
    await expectLater(journal.resume(binding), code('pending_upload_source_changed'));
    await payload.writeAsBytes(original, flush: true);
    final metadata = File('${directory.path}/${PendingUploadJournal.slotName}/journal.json');
    final value = jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
    value['allow_public_media'] = true; await metadata.writeAsString(jsonEncode(value), flush: true);
    await expectLater(journal.resume(binding), code('pending_upload_authentication_failed'));
    expect(await journal.exists(), true); await journal.discard(binding);
  }, skip: Platform.isWindows);
  test('payload链接替换拒绝读取外部字节，discard只移除链接不删目标', () async {
    await journal.freeze(binding: binding, manifest: manifest([sealed()]), sources: [sealed()]);
    final external = File('${directory.path}/outside-source'); await external.writeAsBytes(List.filled(512, 7), flush: true);
    final payload = File('${directory.path}/${PendingUploadJournal.slotName}/payloads/payload-0000'); await payload.delete();
    await Link(payload.path).create(external.path);
    await expectLater(journal.resume(binding), code('pending_upload_source_changed'));
    await journal.discard(binding); expect(await external.exists(), true);
  }, skip: Platform.isWindows);
  test('journal中不保存token恢复钥ref或原媒体句柄，仅摘要绑定', () async {
    await journal.freeze(binding: binding, manifest: manifest([sealed()]), sources: [sealed()]);
    final owner = await File('${directory.path}/${PendingUploadJournal.slotName}/owner.json').readAsString();
    final metadata = await File('${directory.path}/${PendingUploadJournal.slotName}/journal.json').readAsString();
    for (final secret in [tokenRef, keyRef, 'b' * 64, '42' * 32, 'locator', 'bookmark', 'asset_id']) {
      expect(owner + metadata, isNot(contains(secret)));
    }
    expect(binding.toJson()['pair_binding'], 'a9620f61685cd339024ada6c3851934435fe5049ab95c3d75972f4c48b784302');
    expect(binding.toJson()['recovery_binding'], 'd78ea342479587815d96f5124abcbb8800cdca711552a013a7c14cca9566188a');
    expect(owner, contains('pair_binding')); expect(owner, contains('recovery_binding')); expect(metadata, contains('mac'));
  }, skip: Platform.isWindows);
  test('ready resume只复验文件，不改写元数据；空或损坏目录不假称任务恢复', () async {
    expect(await journal.resume(binding), isNull);
    await journal.freeze(binding: binding, manifest: manifest([sealed()]), sources: [sealed()]);
    final file = File('${directory.path}/${PendingUploadJournal.slotName}/journal.json'), before = await File('${directory.path}/${PendingUploadJournal.slotName}/journal.json').readAsBytes();
    await journal.resume(binding); expect(await file.readAsBytes(), before);
    await file.writeAsString('{"v":', flush: true);
    await expectLater(journal.resume(binding), throwsA(isA<BackupException>()));
    expect(await journal.exists(), true); await journal.discard(binding);
  }, skip: Platform.isWindows);
}
