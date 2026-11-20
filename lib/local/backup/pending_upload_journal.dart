import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../transport/native_local.dart';
import 'archive_io.dart';
import 'backup_models.dart';
import 'backup_transport.dart';

Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return value.map(_ordered).toList();
  return value;
}
Uint8List _jsonBytes(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(_ordered(value))));
bool _full(RegExp regex, String value) {
  final match = regex.firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}
final _sha = RegExp(r'^[a-f0-9]{64}$');
Never _bad([String code = 'pending_upload_corrupt']) => throw BackupException(code);
void _keys(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) _bad();
}

/// 当前本机配对和恢复钥的绑定，不持久化 token、钥或原媒体句柄。
/// 每次resume/retry须从当前native安全存储重新创建，不能沿用旧实例冒称已核对新凭据。
class PendingUploadBinding {
  PendingUploadBinding._(this.familyId, this.deviceId, this.origin, this.pin,
    this._pairProof, this._keyProof, this._computer, this._recoveryRef, this._crypto);
  final String familyId, deviceId, origin, pin, _pairProof, _keyProof;
  final PairedComputer _computer;
  final String _recoveryRef;
  final LocalCrypto _crypto;

  static Future<PendingUploadBinding> current({required PairedComputer computer,
    required String familyId, required String deviceId, required String recoveryKeyRef,
    required LocalCrypto crypto}) async {
    if (computer.familyId != familyId || computer.deviceId != deviceId ||
        !validBackupId(familyId) || !validBackupId(deviceId) ||
        !_full(RegExp(r'^wo\.backup\.recovery\.[a-f0-9]{32}$'), recoveryKeyRef)) {
      _bad('pending_upload_binding_changed');
    }
    Uint8List? token, key;
    try {
      token = await crypto.getSecret(computer.tokenRef);
      key = await crypto.getSecret(recoveryKeyRef);
      _secrets(token, key);
      final pairProof = await _proof(crypto, 'pair', computer.tokenRef, token!);
      final keyProof = await _proof(crypto, 'recovery', recoveryKeyRef, key!);
      return PendingUploadBinding._(familyId, deviceId, computer.origin.toString(), computer.pin,
        pairProof, keyProof, computer, recoveryKeyRef, crypto);
    } on BackupException { rethrow; }
    catch (_) { _bad('pending_upload_credentials_unavailable'); }
    finally {
      if (token != null) token.fillRange(0, token.length, 0);
      if (key != null) key.fillRange(0, key.length, 0);
    }
  }
  static void _secrets(Uint8List? token, Uint8List? key) {
    if (token == null || key == null || key.length != 32 || token.length != 64 ||
        token.any((b) => !(b >= 48 && b <= 57 || b >= 97 && b <= 102))) {
      _bad('pending_upload_credentials_unavailable');
    }
  }
  static Future<String> _proof(LocalCrypto crypto, String domain, String ref, Uint8List value) async {
    final bytes = Uint8List.fromList([...utf8.encode('WO-PENDING-UPLOAD/1/$domain\n$ref\n'), ...value]);
    try {
      final digest = await crypto.hash(bytes);
      if (digest.length != 32) _bad('pending_upload_credentials_unavailable');
      return backupHex(digest);
    } finally { bytes.fillRange(0, bytes.length, 0); }
  }
  Map<String, dynamic> toJson() => {'family_id': familyId, 'device_id': deviceId,
    'origin': origin, 'pin': pin, 'pair_binding': _pairProof, 'recovery_binding': _keyProof};
  Future<String> _mac(String domain, Map<String, dynamic> payload) async {
    Uint8List? token, key;
    try {
      token = await _crypto.getSecret(_computer.tokenRef);
      key = await _crypto.getSecret(_recoveryRef);
      _secrets(token, key);
      if (await _proof(_crypto, 'pair', _computer.tokenRef, token!) != _pairProof ||
          await _proof(_crypto, 'recovery', _recoveryRef, key!) != _keyProof) {
        _bad('pending_upload_binding_changed');
      }
      final data = Uint8List.fromList([...utf8.encode('WO-PENDING-UPLOAD/1/$domain\n'), ..._jsonBytes(payload)]);
      final digest = await _crypto.hmac(key: key!, data: data);
      if (digest.length != 32) _bad('pending_upload_credentials_unavailable');
      return backupHex(digest);
    } on BackupException { rethrow; }
    catch (_) { _bad('pending_upload_credentials_unavailable'); }
    finally {
      if (token != null) token.fillRange(0, token.length, 0);
      if (key != null) key.fillRange(0, key.length, 0);
    }
  }
}

class PendingUploadJob {
  PendingUploadJob._(this.manifest, Iterable<BackupSource> sources, Iterable<String> notes,
    Iterable<String> omitted, Map<String, int> issues, this.allowPublicMediaOnComputer)
    : sources = List.unmodifiable(sources), coverageNotes = List.unmodifiable(notes),
      omittedScopes = List.unmodifiable(omitted), sourceIssues = Map.unmodifiable(issues);
  final BackupManifest manifest;
  final List<BackupSource> sources;
  final List<String> coverageNotes, omittedScopes;
  final Map<String, int> sourceIssues;
  final bool allowPublicMediaOnComputer;
}

/// privateParent必须由原生已确认的NoBackup私有入口提供；Dart路径检查不替代OS/ACL证明。
/// 全局固定一个slot；只保存最终网络来源，受限资料只能是已经生成的sealed密文。
/// freeze成功之后才允许网络上传；半成品/绑定变化不自动删除或重新加密。
class PendingUploadJournal {
  PendingUploadJournal({required this.privateParent});
  final Directory privateParent;
  static const slotName = 'pending-upload-v1';
  static const _maxMetadata = 4 * 1024 * 1024;
  static Future<void> _tail = Future<void>.value();
  Directory get _slot => Directory('${privateParent.path}/$slotName');
  Directory get _burned => Directory('${privateParent.path}/used-backup-ids-v1');

  Future<T> _locked<T>(Future<T> Function() action) {
    final task = _tail.then<T>((_) async {
      RandomAccessFile? lock;
      try {
        if (Platform.isWindows) _bad('private_acl_unavailable');
        if (await FileSystemEntity.type(privateParent.path, followLinks: false) != FileSystemEntityType.directory ||
            await privateParent.resolveSymbolicLinks() != privateParent.absolute.path) _bad('untrusted_staging_path');
        final lockFile = File('${privateParent.path}/pending-upload-v1.lock');
        final type = await FileSystemEntity.type(lockFile.path, followLinks: false);
        if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.file) _bad('pending_upload_unsafe_path');
        lock = await lockFile.open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
        return await action();
      } on BackupException { rethrow; }
      catch (_) { _bad('pending_upload_io_failed'); }
      finally {
        if (lock != null) {
          try { await lock.unlock(); } catch (_) {}
          try { await lock.close(); } catch (_) {}
        }
      }
    });
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }
  Future<bool> _exists() async {
    final type = await FileSystemEntity.type(_slot.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.directory || await _slot.resolveSymbolicLinks() != _slot.absolute.path) _bad('pending_upload_unsafe_path');
    return true;
  }
  Future<bool> exists() => _locked(_exists);

  Future<PendingUploadJob> freeze({required PendingUploadBinding binding,
    required BackupManifest manifest, required Iterable<BackupSource> sources,
    bool allowPublicMediaOnComputer = false, Iterable<String> coverageNotes = const [],
    Iterable<String> omittedScopes = const [], Map<String, int> sourceIssues = const {}}) => _locked(() async {
    if (await _exists()) _bad('pending_upload_already_exists');
    if (manifest.familyId != binding.familyId) _bad('pending_upload_binding_changed');
    final sourceMap = <String, BackupSource>{};
    for (final source in sources) {
      if (sourceMap.containsKey(source.entry.id)) _bad('pending_upload_source_mismatch');
      sourceMap[source.entry.id] = source;
    }
    if (sourceMap.length != manifest.entries.length) _bad('pending_upload_source_mismatch');
    final files = <String>[];
    for (var i = 0; i < manifest.entries.length; i++) {
      final entry = manifest.entries[i], source = sourceMap[manifest.entries[i].id];
      if (source == null || !backupConstantTimeEquals(_jsonBytes(source.entry.toJson()), _jsonBytes(entry.toJson())) ||
          entry.kind == 'records' || entry.kind == 'sealed' && source.privacy != BackupPrivacy.restricted ||
          entry.kind != 'sealed' && (source.privacy != BackupPrivacy.public || !allowPublicMediaOnComputer)) {
        _bad('pending_upload_source_mismatch');
      }
      files.add(entry.missing.isNotEmpty ? '' : 'payload-${i.toString().padLeft(4, '0')}');
    }
    final notes = _strings(coverageNotes.toList()), omitted = _strings(omittedScopes.toList());
    final issues = _issues(sourceIssues);
    final manifestSha = backupHex((ArchiveSha256()..add(utf8.encode(manifest.canonicalJson))).finish());
    final owner = <String, dynamic>{'v': 1, 'binding': binding.toJson(), 'backup_id': manifest.backupId, 'manifest_sha256': manifestSha};
    final journal = <String, dynamic>{'v': 1, 'state': 'preparing', 'manifest': manifest.toJson(), 'files': files,
      'coverage_notes': notes, 'omitted_scopes': omitted, 'source_issues': issues, 'allow_public_media': allowPublicMediaOnComputer};
    _limit(owner); _limit(journal);
    // 永不回收已使用ID，即使准备失败或用户放弃，也必须用新backup_id重建归档。
    await _burn(manifest.backupId);
    final initial = await privateParent.createTemp('pending-init-');
    var published = false;
    try {
      await Directory('${initial.path}/payloads').create();
      await _writeSigned(File('${initial.path}/owner.json'), owner, binding, 'owner');
      await _writeSigned(File('${initial.path}/journal.json'), journal, binding, 'journal');
      await initial.rename(_slot.path); published = true;
      // owner+preparing完整发布之后才读原件；失败保留slot供匹配绑定显式放弃。
      for (var i = 0; i < manifest.entries.length; i++) {
        if (files[i].isEmpty) continue;
        await _copySource(sourceMap[manifest.entries[i].id]!, File('${_slot.path}/payloads/${files[i]}'));
      }
      journal['state'] = 'ready';
      final next = File('${_slot.path}/journal.next');
      await _writeSigned(next, journal, binding, 'journal');
      await next.rename('${_slot.path}/journal.json');
      return _job(manifest, files, notes, omitted, issues, allowPublicMediaOnComputer);
    } finally {
      if (!published && await initial.exists()) await initial.delete(recursive: true);
    }
  });

  Future<PendingUploadJob?> resume(PendingUploadBinding expectedBinding) => _locked(() async {
    if (!await _exists()) return null;
    final owner = await _owner(expectedBinding);
    final journal = await _readSigned(File('${_slot.path}/journal.json'), expectedBinding, 'journal');
    _keys(journal, {'v', 'state', 'manifest', 'files', 'coverage_notes', 'omitted_scopes', 'source_issues', 'allow_public_media'});
    if (journal['v'] != 1 || !{'preparing', 'ready'}.contains(journal['state'])) _bad();
    if (journal['state'] != 'ready') _bad('pending_upload_not_ready');
    final manifest = BackupManifest.fromJson(backupObject(journal['manifest']));
    if (manifest.familyId != expectedBinding.familyId || manifest.backupId != owner['backup_id'] ||
        backupHex((ArchiveSha256()..add(utf8.encode(manifest.canonicalJson))).finish()) != owner['manifest_sha256']) _bad();
    final rawFiles = journal['files'];
    if (rawFiles is! List || rawFiles.length != manifest.entries.length || rawFiles.any((value) => value is! String) || journal['allow_public_media'] is! bool) _bad();
    final files = rawFiles.cast<String>(), allowPublic = journal['allow_public_media'] as bool;
    for (var i = 0; i < manifest.entries.length; i++) {
      final entry = manifest.entries[i], name = entry.missing.isNotEmpty ? '' : 'payload-${i.toString().padLeft(4, '0')}';
      if (files[i] != name || entry.kind == 'records' || entry.kind != 'sealed' && !allowPublic) _bad();
      if (name.isNotEmpty) await _verify(File('${_slot.path}/payloads/$name'), entry);
    }
    return _job(manifest, files, _strings(journal['coverage_notes']), _strings(journal['omitted_scopes']),
      _issues(journal['source_issues']), allowPublic);
  });

  Future<void> discard(PendingUploadBinding expectedBinding) => _locked(() async {
    if (!await _exists()) return;
    await _owner(expectedBinding); // ready/preparing损坏均不能被其它家庭/设备/凭据删掉。
    await _removeOwned(_slot);
    // used-backup-ids-v1保留；显式放弃不是同ID重加密许可。
  });
  Future<Map<String, dynamic>> _owner(PendingUploadBinding binding) async {
    final owner = await _readSigned(File('${_slot.path}/owner.json'), binding, 'owner');
    _keys(owner, {'v', 'binding', 'backup_id', 'manifest_sha256'});
    if (owner['v'] != 1 || owner['binding'] is! Map || owner['backup_id'] is! String ||
        !validBackupId(owner['backup_id'] as String) || owner['manifest_sha256'] is! String || !_full(_sha, owner['manifest_sha256'] as String)) _bad();
    if (!backupConstantTimeEquals(_jsonBytes(owner['binding']), _jsonBytes(binding.toJson()))) _bad('pending_upload_binding_changed');
    return owner;
  }
  PendingUploadJob _job(BackupManifest manifest, List<String> files, List<String> notes,
    List<String> omitted, Map<String, int> issues, bool allowPublic) => PendingUploadJob._(manifest,
      [for (var i = 0; i < manifest.entries.length; i++) _JournalSource(manifest.entries[i],
        files[i].isEmpty ? null : File('${_slot.path}/payloads/${files[i]}'))], notes, omitted, issues, allowPublic);

  static List<String> _strings(Object? value) {
    if (value is! List || value.length > 4096 || value.any((v) => v is! String || utf8.encode(v).length > 4096)) _bad();
    return List<String>.from(value);
  }
  static Map<String, int> _issues(Object? value) {
    if (value is! Map || value.length > 128) _bad();
    final result = <String, int>{};
    for (final entry in value.entries) {
      if (entry.key is! String || !_full(RegExp(r'^[a-z][a-z0-9_]{0,80}$'), entry.key as String) ||
          entry.value is! int || entry.value < 0 || entry.value > 1 << 40) _bad();
      result[entry.key as String] = entry.value as int;
    }
    return result;
  }
  static void _limit(Map<String, dynamic> value) { if (_jsonBytes(value).length > _maxMetadata) _bad('pending_upload_metadata_limit'); }
  Future<void> _writeSigned(File file, Map<String, dynamic> payload, PendingUploadBinding binding, String domain) async {
    _limit(payload); final mac = await binding._mac(domain, payload);
    await file.writeAsBytes(_jsonBytes({...payload, 'mac': mac}), flush: true);
  }
  Future<Map<String, dynamic>> _readSigned(File file, PendingUploadBinding binding, String domain) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file || await file.length() > _maxMetadata + 128) _bad();
    final raw = backupObject(decodeBackupJson(await file.readAsString()));
    final mac = raw.remove('mac'); if (mac is! String || !_full(_sha, mac)) _bad();
    final expected = await binding._mac(domain, raw);
    if (!backupConstantTimeEquals(utf8.encode(mac), utf8.encode(expected))) _bad('pending_upload_authentication_failed');
    return raw;
  }
  Future<void> _burn(String backupId) async {
    final type = await FileSystemEntity.type(_burned.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) await _burned.create();
    else if (type != FileSystemEntityType.directory) _bad('pending_upload_unsafe_path');
    final digest = backupHex((ArchiveSha256()..add(utf8.encode('WO-PENDING-UPLOAD/1/id\n$backupId'))).finish());
    final marker = File('${_burned.path}/$digest');
    if (await FileSystemEntity.type(marker.path, followLinks: false) != FileSystemEntityType.notFound) _bad('pending_upload_id_already_used');
    var count = 0;
    await for (final _ in _burned.list(followLinks: false)) { if (++count >= 16384) _bad('pending_upload_history_limit'); }
    await marker.writeAsString('used\n', flush: true);
  }
  Future<void> _copySource(BackupSource source, File target) async {
    final output = await target.open(mode: FileMode.write), hash = ArchiveSha256();
    var size = 0, empty = 0;
    try {
      final stream = (await source.openRange(0, source.entry.size).timeout(const Duration(seconds: 30))).timeout(const Duration(seconds: 30));
      await for (final bytes in stream) {
        if (bytes.length > backupChunkBytes) _bad('pending_upload_source_changed');
        if (bytes.isEmpty) { if (++empty > 100) _bad('pending_upload_source_changed'); continue; }
        empty = 0; size += bytes.length;
        if (size > source.entry.size) _bad('pending_upload_source_changed');
        hash.add(bytes); await output.writeFrom(bytes);
      }
      if (size != source.entry.size || backupHex(hash.finish()) != source.entry.sha256) _bad('pending_upload_source_changed');
      await output.flush();
    } finally { await output.close(); }
  }
  Future<void> _verify(File file, BackupEntry entry) async {
    if (await FileSystemEntity.type(file.parent.path, followLinks: false) != FileSystemEntityType.directory ||
        await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != file.absolute.path || await file.length() != entry.size) _bad('pending_upload_source_changed');
    final hash = ArchiveSha256(); var count = 0;
    await for (final bytes in file.openRead()) { count += bytes.length; if (count > entry.size) _bad('pending_upload_source_changed'); hash.add(bytes); }
    if (count != entry.size || backupHex(hash.finish()) != entry.sha256) _bad('pending_upload_source_changed');
  }
  Future<void> _removeOwned(Directory directory) async {
    // 不递归跟随任何链接；只删除该已认证slot中的实体。
    await for (final child in directory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(child.path, followLinks: false);
      if (type == FileSystemEntityType.directory) await _removeOwned(Directory(child.path));
      else if (type == FileSystemEntityType.link) await Link(child.path).delete();
      else await File(child.path).delete();
    }
    await directory.delete();
  }
}
class _JournalSource implements BackupSource {
  _JournalSource(this.entry, this._file);
  @override final BackupEntry entry;
  final File? _file;
  @override BackupPrivacy get privacy => entry.kind == 'sealed' ? BackupPrivacy.restricted : BackupPrivacy.public;
  @override Future<Stream<List<int>>> openRange(int offset, int length) async {
    final file = _file;
    if (file == null || offset < 0 || length < 0 || offset + length > entry.size ||
        await FileSystemEntity.type(file.parent.path, followLinks: false) != FileSystemEntityType.directory ||
        await FileSystemEntity.type(file.path, followLinks: false) != FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != file.absolute.path) _bad('pending_upload_source_changed');
    return file.openRead(offset, offset + length);
  }
}
