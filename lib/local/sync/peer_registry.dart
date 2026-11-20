import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../../data/api_client.dart';
import '../local_store.dart';
import '../plugins/memory_routes.dart';
import '../transport/native_local.dart';
import 'strict_json.dart';

bool _fullMatch(RegExp pattern, String value) {
  final match = pattern.firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}
bool syncId(String value) => _fullMatch(RegExp(r'^[A-Za-z0-9_-]{1,100}$'), value);
bool _linkId(String value) => _fullMatch(RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'), value);
bool _familyId(String value) => syncId(value) && !value.startsWith('p_') && !value.startsWith('c_');
bool _role(Object? value) => value == 'owner' || value == 'member';
String wire64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
Uint8List un64(String value) {
  if (!_fullMatch(RegExp(r'^[A-Za-z0-9_-]+$'), value)) throw const FormatException('非规范同步编码');
  final bytes = Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
  if (wire64(bytes) != value) throw const FormatException('非规范同步编码');
  return bytes;
}

class PeerLink {
  PeerLink({required this.id, required this.familyId, required this.remoteDeviceId, required this.secretRef,
    required this.remoteRole, this.active = true, this.coupleLocal = false, this.coupleRemote = false});
  final String id, familyId, remoteDeviceId, secretRef, remoteRole;
  final bool active, coupleLocal, coupleRemote;
  Map<String, dynamic> toJson() => {'id': id, 'family': familyId, 'remote': remoteDeviceId,
    'secret_ref': secretRef, 'role': remoteRole, 'active': active,
    'couple_local': coupleLocal, 'couple_remote': coupleRemote};
  factory PeerLink.fromJson(Map<String, dynamic> j) {
    if (j['id'] is! String || !_linkId(j['id'] as String) ||
        j['family'] is! String || !_familyId(j['family'] as String) ||
        j['remote'] is! String || !syncId(j['remote'] as String) ||
        j['secret_ref'] != 'wo.sync.link.${j['id']}' || !_role(j['role']) ||
        j['active'] is! bool || j['couple_local'] is! bool || j['couple_remote'] is! bool) {
      throw const FormatException('配对记录或权限无效');
    }
    return PeerLink(id: j['id'] as String, familyId: j['family'] as String,
      remoteDeviceId: j['remote'] as String, secretRef: j['secret_ref'] as String,
      remoteRole: j['role'] as String, active: j['active'] as bool,
      coupleLocal: j['couple_local'] as bool, coupleRemote: j['couple_remote'] as bool);
  }
  String get coupleSpace => 'c_${id.replaceAll('-', '')}';
}

class PairInvitation {
  PairInvitation(this.linkId, this.familyId, this.deviceId, this.secret, this.expires,
    this.familyName, {required this.role});
  final String linkId, familyId, deviceId, familyName, role;
  final Uint8List secret;
  final int expires;
  void validate() {
    if (!_linkId(linkId) || !_familyId(familyId) || !syncId(deviceId) || !_role(role) ||
        secret.length != 32 || familyName.length > 80 ||
        familyName.runes.any((c) => c < 32 || c == 127)) {
      throw const FormatException('邀请范围或密钥无效');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (expires <= now || expires > now + 10 * 60 * 1000) {
      throw const FormatException('邀请已过期或设备时间异常');
    }
  }
  String encode() {
    validate();
    return 'wo-local-pair:v1:${wire64(utf8.encode(jsonEncode({'v': 1, 'link': linkId,
      'family': familyId, 'device': deviceId, 'secret': wire64(secret),
      'expires': expires, 'name': familyName, 'role': role})))}';
  }
  static PairInvitation parse(String raw) {
    const prefix = 'wo-local-pair:v1:';
    if (!raw.startsWith(prefix) || raw.length > 4096) throw const FormatException('不是本地配对邀请');
    final value = decodeStrictJson(utf8.decode(un64(raw.substring(prefix.length))));
    const fields = {'v', 'link', 'family', 'device', 'secret', 'expires', 'name', 'role'};
    if (value is! Map || value.length != fields.length || !fields.every(value.containsKey) ||
        value['v'] != 1 || value['expires'] is! int || value['secret'] is! String ||
        value['link'] is! String || value['family'] is! String || value['device'] is! String ||
        value['name'] is! String || value['role'] is! String) throw const FormatException('邀请无效');
    final result = PairInvitation(value['link'] as String, value['family'] as String,
      value['device'] as String, un64(value['secret'] as String), value['expires'] as int,
      value['name'] as String, role: value['role'] as String);
    result.validate();
    return result;
  }
}

class PeerRegistry {
  PeerRegistry(this.store, this.crypto);
  final LocalStore store;
  final LocalCrypto crypto;
  // 所有实例共用队列；Keystore/SQLite 之间的异步间隔不得让第二次授权覆盖第一次。
  static Future<void> _tail = Future<void>.value();
  static Future<T> _serial<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try { result.complete(await action()); } catch (e, s) { result.completeError(e, s); }
    });
    return result.future;
  }
  Future<List<PeerLink>> _links() async => [
    for (final j in (await store.privateValue('sync-links') as List?) ?? [])
      PeerLink.fromJson(Map<String, dynamic>.from(j as Map))];
  Future<List<PeerLink>> links() => _serial(_links);
  static bool _same(PeerLink a, PeerLink b) => a.id == b.id && a.familyId == b.familyId &&
    a.remoteDeviceId == b.remoteDeviceId && a.secretRef == b.secretRef && a.remoteRole == b.remoteRole;
  Future<void> _save(PeerLink link) async {
    PeerLink.fromJson(link.toJson());
    final all = await _links();
    final old = all.where((p) => p.id == link.id).firstOrNull;
    if (old != null && (!_same(old, link) || (!old.active && link.active))) {
      throw const FormatException('不能覆盖或重新启用旧配对身份');
    }
    all.removeWhere((p) => p.id == link.id); all.add(link);
    await store.setPrivate('sync-links', all.map((p) => p.toJson()).toList());
  }
  Future<void> save(PeerLink link) => _serial(() => _save(link));
  Future<Map<String, dynamic>?> _member(String family, String device) =>
    store.get(family, '/families/$family/members', device);
  bool _activeMember(Map<String, dynamic>? member, String family, String device) =>
    member != null && member['family_id'] == family && member['user_id'] == device &&
    member['status'] == 'active' && _role(member['role']);
  Future<void> _fresh(String id) async {
    if (!_linkId(id) || (await _links()).any((p) => p.id == id) ||
        await store.privateValue('sync-invite:$id') != null ||
        await store.privateValue('sync-pending-family:$id') != null) {
      throw const FormatException('邀请标识已存在，不能覆盖已有、撤销或待确认的配对');
    }
    final existing = await crypto.getSecret('wo.sync.link.$id');
    try {
      if (existing != null) throw const FormatException('邀请标识已有设备密钥，不能覆盖');
    } finally { if (existing != null) existing.fillRange(0, existing.length, 0); }
  }
  Future<bool> _currentAllowed(PeerLink link) async {
    final local = await _member(link.familyId, store.deviceId);
    final remote = await _member(link.familyId, link.remoteDeviceId);
    if (local != null && !_activeMember(local, link.familyId, store.deviceId)) return false;
    if (remote != null && (!_activeMember(remote, link.familyId, link.remoteDeviceId) ||
        remote['role'] != link.remoteRole)) return false;
    if (local != null && remote != null) return true;
    // 新家庭的首次状态尚未到达；只承认扫码选定的 owner，不能授权未知普通成员。
    return link.remoteRole == 'owner' && await store.privateValue('sync-pending-family:${link.id}') == true;
  }
  Future<PairInvitation> createInvitation(String familyId) => _serial(() async {
    if (!_familyId(familyId)) throw const FormatException('家庭范围无效');
    final member = await _member(familyId, store.deviceId);
    if (!_activeMember(member, familyId, store.deviceId)) {
      throw ApiException('FORBIDDEN', '仅有效家庭成员可签发配对', statusCode: 403);
    }
    final family = await store.get(familyId, '/families/$familyId/family', familyId);
    final id = const Uuid().v4(); await _fresh(id);
    final secret = await crypto.random(32), ref = 'wo.sync.link.$id';
    final name = family?['name'] is String ? family!['name'] as String : '我的家';
    final invitation = PairInvitation(id, familyId, store.deviceId, secret,
      DateTime.now().millisecondsSinceEpoch + 5 * 60 * 1000, name, role: member!['role'] as String);
    invitation.validate();
    await crypto.putSecret(ref, secret);
    try {
      await store.setPrivate('sync-invite:$id', {'family': familyId, 'expires': invitation.expires,
        'secret_ref': ref, 'local_role': invitation.role});
    } catch (_) { await crypto.deleteSecret(ref); rethrow; }
    return invitation;
  });
  Future<PeerLink> accept(PairInvitation invitation) => _serial(() async {
    invitation.validate();
    if (invitation.deviceId == store.deviceId) throw const FormatException('不能与本机配对');
    await _fresh(invitation.linkId); // 必须在 putSecret 之前，不允许用 QR 改写已有 secret。
    final all = await _links();
    if (all.any((p) => p.remoteDeviceId == invitation.deviceId &&
        p.familyId == invitation.familyId && p.active)) throw const FormatException('设备已配对');
    final local = await _member(invitation.familyId, store.deviceId);
    final known = local != null || await store.get(invitation.familyId,
      '/families/${invitation.familyId}/family', invitation.familyId) != null;
    if (known) {
      final inviter = await _member(invitation.familyId, invitation.deviceId);
      if (!_activeMember(local, invitation.familyId, store.deviceId) ||
          !_activeMember(inviter, invitation.familyId, invitation.deviceId) ||
          inviter!['role'] != invitation.role) throw const FormatException('邀请人与本机家庭成员权限不符');
    } else if (invitation.role != 'owner') {
      throw const FormatException('新家庭只能由主理人引入，普通成员不能为新设备授予成员身份');
    }
    final ref = 'wo.sync.link.${invitation.linkId}';
    final link = PeerLink(id: invitation.linkId, familyId: invitation.familyId,
      remoteDeviceId: invitation.deviceId, secretRef: ref, remoteRole: invitation.role);
    await crypto.putSecret(ref, invitation.secret);
    try {
      await store.batch([], privateUpdates: {'sync-links': [...all, link].map((p) => p.toJson()).toList(),
        if (!known) 'sync-pending-family:${link.id}': true});
    } catch (_) { await crypto.deleteSecret(ref); rethrow; }
    return link;
  });
  Future<PeerLink?> _pending(String linkId, String remote) async {
    final raw = await store.privateValue('sync-invite:$linkId');
    if (raw is! Map || raw['family'] is! String || !_familyId(raw['family'] as String) ||
        raw['expires'] is! int || (raw['expires'] as int) <= DateTime.now().millisecondsSinceEpoch ||
        raw['secret_ref'] != 'wo.sync.link.$linkId' || !_role(raw['local_role'])) return null;
    final family = raw['family'] as String;
    final local = await _member(family, store.deviceId), member = await _member(family, remote);
    if (!_activeMember(local, family, store.deviceId) || local!['role'] != raw['local_role']) return null;
    if (member != null && !_activeMember(member, family, remote)) return null;
    if (member == null && raw['local_role'] != 'owner') return null;
    return PeerLink(id: linkId, familyId: family, remoteDeviceId: remote,
      secretRef: raw['secret_ref'] as String, remoteRole: member?['role'] as String? ?? 'member');
  }
  Future<PeerLink?> lookup(String linkId, String remote) => _serial(() async {
    if (!_linkId(linkId) || !syncId(remote) || remote == store.deviceId) return null;
    for (final p in await _links()) {
      if (p.id == linkId) return p.active && p.remoteDeviceId == remote && await _currentAllowed(p) ? p : null;
    }
    return _pending(linkId, remote);
  });
  Future<void> authenticated(PeerLink link) => _serial(() async {
    PeerLink.fromJson(link.toJson());
    final all = await _links(), current = all.where((p) => p.id == link.id).firstOrNull;
    if (current != null) {
      if (!current.active || !_same(current, link) || !await _currentAllowed(current)) throw const FormatException('配对已撤销或邀请已由另一设备消费');
      return; // 第二条同设备连接幂等；不同 remote 绝不能借已消费邀请继续获权。
    }
    final allowed = await _pending(link.id, link.remoteDeviceId);
    if (allowed == null || !_same(allowed, link)) throw const FormatException('邀请已失效或成员权限改变');
    final member = await _member(link.familyId, link.remoteDeviceId);
    final changes = <Map<String, dynamic>>[];
    if (member == null) {
      // _pending 已重新确认本机仍为 owner；成员只可为已在本机成员表中的对端配对。
      changes.add({'space': link.familyId, 'collection': '/families/${link.familyId}/members',
        'id': link.remoteDeviceId, 'fields': {'family_id': link.familyId, 'user_id': link.remoteDeviceId,
          'role': 'member', 'status': 'active', 'display_name': '新家人', 'avatar_emoji': '👤',
          'avatar_url': null, 'joined_at': DateTime.now().toUtc().toIso8601String()}});
    }
    await store.batch(changes, privateUpdates: {
      'sync-links': [...all, link].map((p) => p.toJson()).toList(), 'sync-invite:${link.id}': null});
  });
  Future<Set<String>> scopes(PeerLink link) => _serial(() async {
    final current = (await _links()).where((p) => p.id == link.id).firstOrNull;
    if (current == null || !current.active || !_same(current, link) || !_familyId(current.familyId) ||
        !await _currentAllowed(current)) {
      throw const FormatException('配对已撤销或权限范围改变');
    }
    return {current.familyId, if (current.coupleLocal && current.coupleRemote) current.coupleSpace};
  });
  Future<void> coupleConsent(String linkId, {bool? local, bool? remote}) => _serial(() async {
    final old = (await _links()).where((p) => p.id == linkId && p.active).firstOrNull;
    if (old == null) throw const FormatException('配对不可用');
    final next = PeerLink(id: old.id, familyId: old.familyId, remoteDeviceId: old.remoteDeviceId,
      secretRef: old.secretRef, remoteRole: old.remoteRole, coupleLocal: local ?? old.coupleLocal,
      coupleRemote: remote ?? old.coupleRemote);
    final updates = <String, dynamic>{};
    if (next.coupleLocal && next.coupleRemote) {
      final binding = await store.privateValue('memory-couple:${old.familyId}');
      if (binding is Map && (binding['partner'] != old.remoteDeviceId || binding['space'] != next.coupleSpace)) {
        throw const FormatException('已有伴侣范围，不能静默改绑');
      }
      updates['memory-couple:${old.familyId}'] = {'space': next.coupleSpace, 'partner': old.remoteDeviceId};
    }
    final all = await _links(); all.removeWhere((p) => p.id == old.id); all.add(next);
    await store.batch([], privateUpdates: {'sync-links': all.map((p) => p.toJson()).toList(), ...updates});
  });
  Future<void> revoke(String id) => _serial(() async {
    final old = (await _links()).where((p) => p.id == id).firstOrNull;
    if (old == null) return;
    await _save(PeerLink(id: old.id, familyId: old.familyId, remoteDeviceId: old.remoteDeviceId,
      secretRef: old.secretRef, remoteRole: old.remoteRole, active: false));
    await crypto.deleteSecret(old.secretRef);
  });
}

class LocalMemoryAccess implements MemoryAccess {
  LocalMemoryAccess(this.store);
  final LocalStore store;
  Future<String> _private(String fid) => PeerRegistry._serial(() async {
    var scope = await store.privateValue('memory-private:$fid') as String?;
    if (scope == null) { scope = 'p_${const Uuid().v4()}'; await store.setPrivate('memory-private:$fid', scope); }
    return scope;
  });
  @override Future<List<String>> visibleSpaces(String familyId) async {
    final couple = await store.privateValue('memory-couple:$familyId');
    return [familyId, await _private(familyId), if (couple is Map && couple['space'] is String) couple['space'] as String];
  }
  @override Future<String> spaceFor(String familyId, String visibility) async {
    if (visibility == 'family') return familyId;
    if (visibility == 'private') return _private(familyId);
    if (visibility == 'couple') {
      final c = await store.privateValue('memory-couple:$familyId');
      if (c is Map && c['space'] is String && c['partner'] is String) return c['space'] as String;
      throw ApiException('COUPLE_BINDING_REQUIRED', '请先与伴侣双方明确确认受限同步，内容不会回落到全家', statusCode: 409);
    }
    throw const FormatException('可见范围无效');
  }
}
