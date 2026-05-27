import 'api_client.dart';
import 'app_update.dart';
import 'models.dart';

/// 业务仓库：把后端端点封装成带类型的方法。页面只跟它打交道。
class WoApi {
  WoApi(this._client);

  final ApiClient _client;

  String get userId => _client.userId;
  set userId(String value) => _client.userId = value;

  /// 后端 host（不含 /api/v1）。下载 APK 等需要拼完整地址时用。
  String get baseUrl => _client.baseUrl;

  // ── 应用内更新 ───────────────────────────────────────────────
  /// 取后端最新发布版本；尚未发布任何版本时返回 null。
  Future<AppRelease?> latestRelease() async {
    final data = await _client.get('/app/version');
    if (data == null) return null;
    return AppRelease.fromJson(data as Map<String, dynamic>);
  }

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

  /// 更新当前用户资料（目前支持昵称）。仅传需要变更的字段。
  Future<WoUser> updateMe({String? displayName}) async {
    final data = await _client.patch(
      '/me',
      body: {
        if (displayName != null) 'display_name': displayName,
      },
    );
    return WoUser.fromJson(data as Map<String, dynamic>);
  }

  /// 上传/替换当前用户头像。返回更新后的用户（avatar_version 已 +1）。
  Future<WoUser> uploadMyAvatar({
    required List<int> bytes,
    String filename = 'avatar.jpg',
  }) async {
    final data = await _client.uploadFile(
      '/me/avatar',
      bytes: bytes,
      filename: filename,
    );
    return WoUser.fromJson(data as Map<String, dynamic>);
  }

  // ── 通知偏好 ─────────────────────────────────────────────────
  /// 读取当前用户的通知偏好（总推送开关 + 各来源开关）。
  Future<NotificationPreferences> notificationPreferences() async =>
      NotificationPreferences.fromJson(
        await _client.get('/me/notification-preferences')
            as Map<String, dynamic>,
      );

  /// 部分更新通知偏好：仅传需要变更的字段。返回更新后的完整偏好。
  Future<NotificationPreferences> updateNotificationPreferences({
    bool? pushEnabled,
    Map<String, bool>? sources,
  }) async {
    final data = await _client.patch(
      '/me/notification-preferences',
      body: {
        if (pushEnabled != null) 'push_enabled': pushEnabled,
        if (sources != null && sources.isNotEmpty) 'sources': sources,
      },
    );
    return NotificationPreferences.fromJson(data as Map<String, dynamic>);
  }

  /// 移除头像，回退到 emoji。返回更新后的用户。
  Future<WoUser> deleteMyAvatar() async {
    final data = await _client.delete('/me/avatar');
    return WoUser.fromJson(data as Map<String, dynamic>);
  }

  /// 用户头像原图的完整地址（含 host）。没头像返回 null。
  String? userAvatarUrl(WoUser u) =>
      u.hasAvatar ? '${_client.baseUrl}${u.avatarUrl}' : null;

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

  /// 修改家庭资料（名称/标语/emoji）。仅传需要变更的字段。owner/admin 才有权限。
  Future<Family> updateFamily(
    String familyId, {
    String? name,
    String? slogan,
    String? emoji,
  }) async {
    final data = await _client.patch(
      '/families/$familyId',
      body: {
        if (name != null) 'name': name,
        if (slogan != null) 'slogan': slogan,
        if (emoji != null) 'emoji': emoji,
      },
    );
    return Family.fromJson(data as Map<String, dynamic>);
  }

  Future<List<Member>> members(String familyId) async {
    final data = await _client.get('/families/$familyId/members') as List;
    return data.map((e) => Member.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 离开家庭（移除自己的成员身份）。主理人不能直接离开（后端返回 403）。
  Future<void> leaveFamily(String familyId) async {
    await _client.delete('/families/$familyId/members/me');
  }

  /// 修改成员角色（owner/admin 可操作，不能改主理人；目标角色限家人/管理员/孩子/宠物）。
  Future<Member> updateMemberRole(
    String familyId,
    String userId,
    String role,
  ) async {
    final data = await _client.patch(
      '/families/$familyId/members/$userId',
      body: {'role': role},
    );
    return Member.fromJson(data as Map<String, dynamic>);
  }

  /// 转让主理人（仅当前主理人可操作）。转让后自己降为管理员。
  Future<void> transferOwnership(String familyId, String newOwnerId) async {
    await _client.post(
      '/families/$familyId/transfer-ownership',
      body: {'new_owner_id': newOwnerId},
    );
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

  Future<void> deleteNotification(String id) =>
      _client.delete('/notifications/$id');

  // ── 设备推送 token ──────────────────────────────────────────
  /// 注册本机的极光 registration id，用于接收远程推送。后端按 registration id
  /// 幂等 upsert，重复调用安全。[platform] 取 'android' / 'ios'。
  Future<void> registerDevice({
    required String registrationId,
    required String platform,
  }) =>
      _client.post(
        '/devices/register',
        body: {'registration_id': registrationId, 'platform': platform},
      );

  /// 注销本机 token（登出时调用）。后端按 (registration id, 当前用户) 删除，
  /// 不存在也返回成功。
  Future<void> unregisterDevice(String registrationId) =>
      _client.delete('/devices/$registrationId');

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
    bool notifyEnabled = false,
    int notifyDaysBefore = 0,
  }) async {
    final data = await _client.post(
      '/families/$familyId/plugins/anniversary/dates',
      body: {
        'name': name,
        'event_date': _formatDate(eventDate),
        'emoji': emoji,
        'is_lunar': isLunar,
        if (note != null && note.isNotEmpty) 'note': note,
        'notify_enabled': notifyEnabled,
        'notify_days_before': notifyDaysBefore,
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
    bool notifyEnabled = false,
    int notifyDaysBefore = 0,
  }) async {
    final data = await _client.put(
      '/families/$familyId/plugins/anniversary/dates/$id',
      body: {
        'name': name,
        'event_date': _formatDate(eventDate),
        'emoji': emoji,
        'is_lunar': isLunar,
        'note': note,
        'notify_enabled': notifyEnabled,
        'notify_days_before': notifyDaysBefore,
      },
    );
    return Anniversary.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteAnniversary(String familyId, String id) =>
      _client.delete('/families/$familyId/plugins/anniversary/dates/$id');

  // ── 菜谱插件 ────────────────────────────────────────────────
  Future<List<Recipe>> recipes(String familyId, {String? category}) async {
    final data = await _client.get(
      '/families/$familyId/plugins/recipe/recipes',
      query: (category != null && category.isNotEmpty)
          ? {'category': category}
          : null,
    ) as List;
    return data.map((e) => Recipe.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Recipe> recipe(String familyId, String id) async {
    final data =
        await _client.get('/families/$familyId/plugins/recipe/recipes/$id');
    return Recipe.fromJson(data as Map<String, dynamic>);
  }

  Future<Recipe> createRecipe(
    String familyId, {
    required String name,
    required String emoji,
    required String category,
    required int minutes,
    required int difficulty,
    int? servings,
    String? note,
    List<RecipeIngredient> ingredients = const [],
    List<String> steps = const [],
  }) async {
    final data = await _client.post(
      '/families/$familyId/plugins/recipe/recipes',
      body: {
        'name': name,
        'emoji': emoji,
        'category': category,
        'minutes': minutes,
        'difficulty': difficulty,
        if (servings != null) 'servings': servings,
        if (note != null && note.isNotEmpty) 'note': note,
        'ingredients': ingredients.map((e) => e.toJson()).toList(),
        'steps': steps,
      },
    );
    return Recipe.fromJson(data as Map<String, dynamic>);
  }

  Future<Recipe> updateRecipe(
    String familyId,
    String id, {
    required String name,
    required String emoji,
    required String category,
    required int minutes,
    required int difficulty,
    int? servings,
    String? note,
    List<RecipeIngredient> ingredients = const [],
    List<String> steps = const [],
  }) async {
    final data = await _client.put(
      '/families/$familyId/plugins/recipe/recipes/$id',
      body: {
        'name': name,
        'emoji': emoji,
        'category': category,
        'minutes': minutes,
        'difficulty': difficulty,
        'servings': servings,
        'note': note,
        'ingredients': ingredients.map((e) => e.toJson()).toList(),
        'steps': steps,
      },
    );
    return Recipe.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteRecipe(String familyId, String id) =>
      _client.delete('/families/$familyId/plugins/recipe/recipes/$id');

  /// 上传/替换菜谱封面照片。返回更新后的菜谱（cover_version 已 +1）。
  Future<Recipe> uploadRecipeCover(
    String familyId,
    String id, {
    required List<int> bytes,
    String filename = 'cover.jpg',
  }) async {
    final data = await _client.uploadFile(
      '/families/$familyId/plugins/recipe/recipes/$id/cover',
      bytes: bytes,
      filename: filename,
    );
    return Recipe.fromJson(data as Map<String, dynamic>);
  }

  /// 移除封面照片，菜谱回退到 emoji。返回更新后的菜谱。
  Future<Recipe> deleteRecipeCover(String familyId, String id) async {
    final data = await _client
        .delete('/families/$familyId/plugins/recipe/recipes/$id/cover');
    return Recipe.fromJson(data as Map<String, dynamic>);
  }

  /// 菜谱封面原图的完整地址（含 host）。没封面返回 null。
  String? recipeCoverUrl(Recipe r) =>
      r.hasCover ? '${_client.baseUrl}${r.coverUrl}' : null;

  /// 加载封面原图要带的鉴权头。
  Map<String, String> get imageHeaders => _client.imageHeaders;

  // ── 菜谱标签（家庭共享的分类清单）──────────────────────────
  Future<List<String>> recipeTags(String familyId) async {
    final data =
        await _client.get('/families/$familyId/plugins/recipe/tags') as List;
    return data.map((e) => e as String).toList();
  }

  /// 新建标签，返回更新后的完整标签列表。
  Future<List<String>> addRecipeTag(String familyId, String name) async {
    final data = await _client.post(
      '/families/$familyId/plugins/recipe/tags',
      body: {'name': name},
    ) as List;
    return data.map((e) => e as String).toList();
  }

  /// 删除标签，返回更新后的完整标签列表。
  Future<List<String>> deleteRecipeTag(String familyId, String name) async {
    final data = await _client.delete(
      '/families/$familyId/plugins/recipe/tags',
      query: {'name': name},
    ) as List;
    return data.map((e) => e as String).toList();
  }

  // ── 家务插件 ────────────────────────────────────────────────
  /// 拉取家务列表。[done] 为空取全部，false 取未完成，true 取已完成。
  Future<List<Chore>> chores(String familyId, {bool? done}) async {
    final data = await _client.get(
      '/families/$familyId/plugins/chore/chores',
      query: done != null ? {'done': done} : null,
    ) as List;
    return data.map((e) => Chore.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Chore> createChore(
    String familyId, {
    required String title,
    required String emoji,
    String? note,
    String? assignedTo,
    bool recurring = false,
  }) async {
    final data = await _client.post(
      '/families/$familyId/plugins/chore/chores',
      body: {
        'title': title,
        'emoji': emoji,
        'recurring': recurring,
        if (note != null && note.isNotEmpty) 'note': note,
        if (assignedTo != null && assignedTo.isNotEmpty)
          'assigned_to': assignedTo,
      },
    );
    return Chore.fromJson(data as Map<String, dynamic>);
  }

  /// 更新家务本体（标题/emoji/备注/负责人）。编辑页一次性提交完整状态，
  /// [assignedTo] 为空表示清除指派。完成状态用 complete/reopen 接口单独切换。
  Future<Chore> updateChore(
    String familyId,
    String id, {
    required String title,
    required String emoji,
    String? note,
    String? assignedTo,
    bool? recurring,
  }) async {
    final data = await _client.put(
      '/families/$familyId/plugins/chore/chores/$id',
      body: {
        'title': title,
        'emoji': emoji,
        'note': note,
        'assigned_to':
            (assignedTo != null && assignedTo.isNotEmpty) ? assignedTo : null,
        if (recurring != null) 'recurring': recurring,
      },
    );
    return Chore.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteChore(String familyId, String id) =>
      _client.delete('/families/$familyId/plugins/chore/chores/$id');

  Future<Chore> completeChore(String familyId, String id) async {
    final data = await _client
        .post('/families/$familyId/plugins/chore/chores/$id/complete');
    return Chore.fromJson(data as Map<String, dynamic>);
  }

  Future<Chore> reopenChore(String familyId, String id) async {
    final data = await _client
        .post('/families/$familyId/plugins/chore/chores/$id/reopen');
    return Chore.fromJson(data as Map<String, dynamic>);
  }

  /// 手动提醒负责人（给 TA 发一条通知）。家务须已指派且未完成。
  Future<void> remindChore(String familyId, String id) =>
      _client.post('/families/$familyId/plugins/chore/chores/$id/remind');

  /// 一键重新匹配：把所有「每周重复」且已完成的家务重置为待做，负责人不变。
  /// 返回被重置的数量。
  Future<int> resetRecurringChores(String familyId) async {
    final data = await _client
        .post('/families/$familyId/plugins/chore/chores/reset-recurring');
    return (data as Map<String, dynamic>)['reset'] as int? ?? 0;
  }

  // ── 囤货铺插件 · 囤货库存 ──────────────────────────────────────
  /// 拉取囤货列表。[low] 为 true 时只取告急（数量见底）的项。
  Future<List<StockItem>> stockItems(String familyId, {bool? low}) async {
    final data = await _client.get(
      '/families/$familyId/plugins/stock/items',
      query: low != null ? {'low': low} : null,
    ) as List;
    return data
        .map((e) => StockItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<StockItem> createStockItem(
    String familyId, {
    required String name,
    required String emoji,
    required int qty,
    String? unit,
    int? lowAt,
    String? note,
  }) async {
    final data = await _client.post(
      '/families/$familyId/plugins/stock/items',
      body: {
        'name': name,
        'emoji': emoji,
        'qty': qty,
        if (unit != null && unit.isNotEmpty) 'unit': unit,
        if (lowAt != null) 'low_at': lowAt,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
    return StockItem.fromJson(data as Map<String, dynamic>);
  }

  /// 更新囤货项。编辑页一次性提交完整状态，[unit]/[lowAt]/[note] 传 null 即清除。
  Future<StockItem> updateStockItem(
    String familyId,
    String id, {
    required String name,
    required String emoji,
    required int qty,
    String? unit,
    int? lowAt,
    String? note,
  }) async {
    final data = await _client.put(
      '/families/$familyId/plugins/stock/items/$id',
      body: {
        'name': name,
        'emoji': emoji,
        'qty': qty,
        'unit': (unit != null && unit.isNotEmpty) ? unit : null,
        'low_at': lowAt,
        'note': (note != null && note.isNotEmpty) ? note : null,
      },
    );
    return StockItem.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteStockItem(String familyId, String id) =>
      _client.delete('/families/$familyId/plugins/stock/items/$id');

  /// 把一个囤货项加进采买清单（关联回该项）；已有未买的同项时返回那一条。
  Future<BuyItem> stockItemToBuy(String familyId, String id) async {
    final data =
        await _client.post('/families/$familyId/plugins/stock/items/$id/to-buy');
    return BuyItem.fromJson(data as Map<String, dynamic>);
  }

  // ── 囤货铺插件 · 采买待买清单 ──────────────────────────────────
  /// 拉取采买清单。[bought] 为空取全部，false 取待买，true 取已买。
  Future<List<BuyItem>> buyItems(String familyId, {bool? bought}) async {
    final data = await _client.get(
      '/families/$familyId/plugins/stock/buys',
      query: bought != null ? {'bought': bought} : null,
    ) as List;
    return data.map((e) => BuyItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<BuyItem> createBuyItem(
    String familyId, {
    required String name,
    required String emoji,
    String? wantQty,
    String? note,
  }) async {
    final data = await _client.post(
      '/families/$familyId/plugins/stock/buys',
      body: {
        'name': name,
        'emoji': emoji,
        if (wantQty != null && wantQty.isNotEmpty) 'want_qty': wantQty,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
    return BuyItem.fromJson(data as Map<String, dynamic>);
  }

  Future<BuyItem> updateBuyItem(
    String familyId,
    String id, {
    required String name,
    required String emoji,
    String? wantQty,
    String? note,
  }) async {
    final data = await _client.put(
      '/families/$familyId/plugins/stock/buys/$id',
      body: {
        'name': name,
        'emoji': emoji,
        'want_qty': (wantQty != null && wantQty.isNotEmpty) ? wantQty : null,
        'note': (note != null && note.isNotEmpty) ? note : null,
      },
    );
    return BuyItem.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteBuyItem(String familyId, String id) =>
      _client.delete('/families/$familyId/plugins/stock/buys/$id');

  /// 标记买到。[intoStockQty] 非空时把这些数量入库：关联项直接累加，
  /// 未关联则以这条待买新建一个囤货项。只在第一次确认时传数量。
  Future<BuyItem> markBuyBought(
    String familyId,
    String id, {
    int? intoStockQty,
  }) async {
    final data = await _client.post(
      '/families/$familyId/plugins/stock/buys/$id/bought',
      body: intoStockQty != null ? {'into_stock_qty': intoStockQty} : null,
    );
    return BuyItem.fromJson(data as Map<String, dynamic>);
  }

  Future<BuyItem> reopenBuyItem(String familyId, String id) async {
    final data =
        await _client.post('/families/$familyId/plugins/stock/buys/$id/reopen');
    return BuyItem.fromJson(data as Map<String, dynamic>);
  }

  // ── 记账插件 ────────────────────────────────────────────────
  Future<List<Expense>> expenses(
    String familyId, {
    int? year,
    int? month,
  }) async {
    final q = (year != null && month != null) ? '?year=$year&month=$month' : '';
    final data = await _client
        .get('/families/$familyId/plugins/accounting/transactions$q') as List;
    return data.map((e) => Expense.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Expense> createExpense(
    String familyId, {
    required double amount,
    required String category,
    String? note,
  }) async {
    final data = await _client.post(
      '/families/$familyId/plugins/accounting/transactions',
      body: {
        'amount': amount,
        'category': category,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
    return Expense.fromJson(data as Map<String, dynamic>);
  }

  Future<Expense> updateExpense(
    String familyId,
    String id, {
    required double amount,
    required String category,
    String? note,
  }) async {
    final data = await _client.put(
      '/families/$familyId/plugins/accounting/transactions/$id',
      body: {
        'amount': amount,
        'category': category,
        'note': note,
      },
    );
    return Expense.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteExpense(String familyId, String id) =>
      _client.delete('/families/$familyId/plugins/accounting/transactions/$id');

  Future<AccountingSummary> accountingSummary(
    String familyId, {
    int? year,
    int? month,
  }) async {
    final q = (year != null && month != null) ? '?year=$year&month=$month' : '';
    final data = await _client
        .get('/families/$familyId/plugins/accounting/summary$q');
    return AccountingSummary.fromJson(data as Map<String, dynamic>);
  }

  Future<double?> getBudget(String familyId) async {
    final data = await _client
        .get('/families/$familyId/plugins/accounting/budget')
        as Map<String, dynamic>;
    final raw = data['monthly_amount'];
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw.toString());
  }

  Future<void> setBudget(String familyId, double amount) => _client.put(
        '/families/$familyId/plugins/accounting/budget',
        body: {'monthly_amount': amount},
      );

  // ── 回忆插件 ────────────────────────────────────────────────
  /// 时间线列表（按 event_date 倒序，含每条的媒体与留言数）。
  Future<List<Memory>> memories(String familyId) async {
    final data = await _client
        .get('/families/$familyId/plugins/memory/memories') as List;
    return data
        .map((e) => Memory.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 单条回忆详情（含媒体与全部留言）。
  Future<Memory> memory(String familyId, String id) async {
    final data =
        await _client.get('/families/$familyId/plugins/memory/memories/$id');
    return Memory.fromJson(data as Map<String, dynamic>);
  }

  Future<Memory> createMemory(
    String familyId, {
    required String title,
    String? body,
    String? mood,
    String? location,
    String visibility = 'family',
    required DateTime eventDate,
  }) async {
    final data = await _client.post(
      '/families/$familyId/plugins/memory/memories',
      body: {
        'title': title,
        if (body != null && body.isNotEmpty) 'body': body,
        if (mood != null && mood.isNotEmpty) 'mood': mood,
        if (location != null && location.isNotEmpty) 'location': location,
        'visibility': visibility,
        'event_date': _formatDate(eventDate),
      },
    );
    return Memory.fromJson(data as Map<String, dynamic>);
  }

  /// 更新回忆本体。可空字段传 null 表示清除（后端按 exclude_unset 处理，
  /// 这里所有键都显式带上，所以 null 会真正清掉旧值）。
  Future<Memory> updateMemory(
    String familyId,
    String id, {
    required String title,
    String? body,
    String? mood,
    String? location,
    required String visibility,
    required DateTime eventDate,
  }) async {
    final data = await _client.put(
      '/families/$familyId/plugins/memory/memories/$id',
      body: {
        'title': title,
        'body': (body != null && body.isNotEmpty) ? body : null,
        'mood': (mood != null && mood.isNotEmpty) ? mood : null,
        'location': (location != null && location.isNotEmpty) ? location : null,
        'visibility': visibility,
        'event_date': _formatDate(eventDate),
      },
    );
    return Memory.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteMemory(String familyId, String id) =>
      _client.delete('/families/$familyId/plugins/memory/memories/$id');

  /// 给回忆挂一张照片或一段视频。[durationMs] 仅视频需要。
  Future<MemoryMedia> uploadMemoryMedia(
    String familyId,
    String memoryId, {
    required List<int> bytes,
    required String filename,
    int? durationMs,
  }) async {
    final data = await _client.uploadFile(
      '/families/$familyId/plugins/memory/memories/$memoryId/media',
      bytes: bytes,
      filename: filename,
      fields: durationMs != null ? {'duration_ms': '$durationMs'} : null,
    );
    return MemoryMedia.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteMemoryMedia(
    String familyId,
    String memoryId,
    String mediaId,
  ) =>
      _client.delete(
        '/families/$familyId/plugins/memory/memories/$memoryId/media/$mediaId',
      );

  Future<MemoryComment> addMemoryComment(
    String familyId,
    String memoryId,
    String body,
  ) async {
    final data = await _client.post(
      '/families/$familyId/plugins/memory/memories/$memoryId/comments',
      body: {'body': body},
    );
    return MemoryComment.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteMemoryComment(
    String familyId,
    String memoryId,
    String commentId,
  ) =>
      _client.delete(
        '/families/$familyId/plugins/memory/memories/$memoryId/comments/$commentId',
      );

  /// 回忆媒体原图/视频的完整地址（含 host）。
  String memoryMediaUrl(MemoryMedia m) => '${_client.baseUrl}${m.url}';

  static String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
