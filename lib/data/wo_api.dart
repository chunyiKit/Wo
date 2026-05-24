import 'api_client.dart';
import 'models.dart';

/// 业务仓库：把后端端点封装成带类型的方法。页面只跟它打交道。
class WoApi {
  WoApi(this._client);

  final ApiClient _client;

  String get userId => _client.userId;
  set userId(String value) => _client.userId = value;

  // ── 认证 ────────────────────────────────────────────────────
  /// 手机号登录/注册。号码已存在则登录，不存在则注册（暂无短信验证码）。
  Future<AuthResult> login(String phone) async => AuthResult.fromJson(
        await _client.post('/auth/login', body: {'phone': phone})
            as Map<String, dynamic>,
      );

  // ── 启动 / 我 ────────────────────────────────────────────────
  Future<Bootstrap> bootstrap() async => Bootstrap.fromJson(
        await _client.get('/me/bootstrap') as Map<String, dynamic>,
      );

  Future<Me> me() async =>
      Me.fromJson(await _client.get('/me') as Map<String, dynamic>);

  Future<List<Family>> myFamilies() async {
    final data = await _client.get('/me/families') as List;
    return data.map((e) => Family.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ── 家庭 ────────────────────────────────────────────────────
  Future<Family> createFamily({
    required String name,
    String? slogan,
    required String emoji,
  }) async {
    final data = await _client.post(
      '/families',
      body: {
        'name': name,
        if (slogan != null && slogan.isNotEmpty) 'slogan': slogan,
        'emoji': emoji,
      },
    );
    return Family.fromJson(data as Map<String, dynamic>);
  }

  Future<Family> getFamily(String familyId) async => Family.fromJson(
        await _client.get('/families/$familyId') as Map<String, dynamic>,
      );

  Future<Family> switchFamily(String familyId) async => Family.fromJson(
        await _client.post('/families/$familyId/switch')
            as Map<String, dynamic>,
      );

  Future<List<Member>> members(String familyId) async {
    final data = await _client.get('/families/$familyId/members') as List;
    return data.map((e) => Member.fromJson(e as Map<String, dynamic>)).toList();
  }

  // ── 邀请 ────────────────────────────────────────────────────
  Future<InvitationResult> createInvitation(
    String familyId, {
    String role = 'member',
    int ttlSeconds = 7 * 24 * 3600,
    String channel = 'link',
  }) async {
    final data = await _client.post(
      '/families/$familyId/invitations',
      body: {
        'role': role,
        'ttl_seconds': ttlSeconds,
        'channel': channel,
      },
    );
    return InvitationResult.fromJson(data as Map<String, dynamic>);
  }

  Future<InvitationPreview> previewInvitation(String code) async =>
      InvitationPreview.fromJson(
        await _client.get('/invitations/$code/preview') as Map<String, dynamic>,
      );

  Future<Family> acceptInvitation(String code) async => Family.fromJson(
        await _client.post('/invitations/$code/accept') as Map<String, dynamic>,
      );

  // ── 插件市场 ────────────────────────────────────────────────
  Future<List<Plugin>> plugins() async {
    final data = await _client.get('/plugins') as List;
    return data.map((e) => Plugin.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Plugin> plugin(String pluginId) async => Plugin.fromJson(
        await _client.get('/plugins/$pluginId') as Map<String, dynamic>,
      );

  // ── 家庭已装插件 ────────────────────────────────────────────
  Future<List<InstalledPlugin>> installedPlugins(String familyId) async {
    final data = await _client.get('/families/$familyId/plugins') as List;
    return data
        .map((e) => InstalledPlugin.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<InstalledPlugin> installPlugin(
    String familyId,
    String pluginId,
  ) async {
    final data = await _client
        .post('/families/$familyId/plugins', body: {'plugin_id': pluginId});
    return InstalledPlugin.fromJson(data as Map<String, dynamic>);
  }

  Future<void> uninstallPlugin(String familyId, String installId) =>
      _client.delete('/families/$familyId/plugins/$installId');

  /// 更新某张已装卡片的配置（如纪念日卡绑定 `{anniversary_id: ...}`）。
  Future<InstalledPlugin> updatePluginConfig(
    String familyId,
    String installId,
    Map<String, dynamic> config,
  ) async {
    final data = await _client.patch(
      '/families/$familyId/plugins/$installId',
      body: {'config': config},
    );
    return InstalledPlugin.fromJson(data as Map<String, dynamic>);
  }

  /// 整体更新家庭首页布局。[items] 必须覆盖且仅覆盖所有已装插件，每项形如
  /// `{install_id, col, row, cw, ch}`。后端会校验越界 / 重叠后原子替换。
  Future<void> updateLayout(
    String familyId,
    List<Map<String, dynamic>> items,
  ) =>
      _client.put('/families/$familyId/layout', body: {'items': items});

  // ── 通知 ────────────────────────────────────────────────────
  Future<List<WoNotification>> notifications({int limit = 50}) async {
    final data =
        await _client.get('/notifications', query: {'limit': limit}) as List;
    return data
        .map((e) => WoNotification.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> markNotificationRead(String id) =>
      _client.patch('/notifications/$id/read');

  Future<int> markAllNotificationsRead() async {
    final data = await _client.post('/notifications/read-all');
    return ((data as Map<String, dynamic>)['marked'] as num?)?.toInt() ?? 0;
  }

  // ── 纪念日插件 ──────────────────────────────────────────────
  Future<List<Anniversary>> anniversaries(String familyId) async {
    final data = await _client
        .get('/families/$familyId/plugins/anniversary/dates') as List;
    return data
        .map((e) => Anniversary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Anniversary> createAnniversary(
    String familyId, {
    required String name,
    required DateTime eventDate,
    required String emoji,
    bool isLunar = false,
    String? note,
  }) async {
    final data = await _client.post(
      '/families/$familyId/plugins/anniversary/dates',
      body: {
        'name': name,
        'event_date': _formatDate(eventDate),
        'emoji': emoji,
        'is_lunar': isLunar,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
    return Anniversary.fromJson(data as Map<String, dynamic>);
  }

  Future<Anniversary> updateAnniversary(
    String familyId,
    String id, {
    required String name,
    required DateTime eventDate,
    required String emoji,
    bool isLunar = false,
    String? note,
  }) async {
    final data = await _client.put(
      '/families/$familyId/plugins/anniversary/dates/$id',
      body: {
        'name': name,
        'event_date': _formatDate(eventDate),
        'emoji': emoji,
        'is_lunar': isLunar,
        'note': note,
      },
    );
    return Anniversary.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteAnniversary(String familyId, String id) =>
      _client.delete('/families/$familyId/plugins/anniversary/dates/$id');

  static String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
