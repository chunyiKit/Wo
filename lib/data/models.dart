/// 与后端 schema 一一对应的客户端模型（见 docs/backend-contract.md 与
/// app/plugins/views.py / app/models/*）。全部不可变 + fromJson。
library;

DateTime? _parseDate(Object? v) =>
    v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

/// 后端 Decimal 字段会被序列化成 JSON 字符串（如 "12.50"），也可能是数字。
/// 统一安全解析：数字 / 字符串都接受，无法解析返回 null。
double? _parseNumOrNull(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

double _parseNum(Object? v) => _parseNumOrNull(v) ?? 0;

class WoUser {
  const WoUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.avatarEmoji,
    required this.level,
    this.createdAt,
    this.avatarVersion = 0,
    this.avatarUrl,
  });

  final String id;
  final String username;
  final String displayName;
  final String avatarEmoji;
  final int level;
  final DateTime? createdAt;

  /// 头像图片：版本号（0=未设置）+ 带 `?v=` 缓存键的相对地址。
  /// [avatarUrl] 为 null 时回退到 [avatarEmoji]。
  final int avatarVersion;
  final String? avatarUrl;

  bool get hasAvatar => avatarUrl != null;

  factory WoUser.fromJson(Map<String, dynamic> j) => WoUser(
        id: j['id'] as String,
        username: j['username'] as String? ?? '',
        displayName: j['display_name'] as String? ?? '',
        avatarEmoji: j['avatar_emoji'] as String? ?? '👤',
        level: (j['level'] as num?)?.toInt() ?? 1,
        createdAt: _parseDate(j['created_at']),
        avatarVersion: (j['avatar_version'] as num?)?.toInt() ?? 0,
        avatarUrl: j['avatar_url'] as String?,
      );
}

class AuthResult {
  const AuthResult({
    required this.user,
    required this.token,
    required this.isNew,
  });

  final WoUser user;
  final String token; // 当前即 user.id，后端接真实 JWT 后只换值不换契约
  final bool isNew; // true = 该手机号首次注册

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        user: WoUser.fromJson(j['user'] as Map<String, dynamic>),
        token: j['token'] as String,
        isNew: j['is_new'] as bool? ?? false,
      );
}

class Stats {
  const Stats({
    required this.familiesJoined,
    required this.pluginsUsed,
    required this.daysActive,
  });

  final int familiesJoined;
  final int pluginsUsed;
  final int daysActive;

  factory Stats.fromJson(Map<String, dynamic> j) => Stats(
        familiesJoined: (j['families_joined'] as num?)?.toInt() ?? 0,
        pluginsUsed: (j['plugins_used'] as num?)?.toInt() ?? 0,
        daysActive: (j['days_active'] as num?)?.toInt() ?? 0,
      );
}

class Family {
  const Family({
    required this.id,
    required this.name,
    this.slogan,
    required this.emoji,
    this.createdAt,
    required this.memberCount,
    required this.myRole,
    required this.myUnreadCount,
  });

  final String id;
  final String name;
  final String? slogan;
  final String emoji;
  final DateTime? createdAt;
  final int memberCount;
  final String myRole; // owner | admin | member | child | pet
  final int myUnreadCount;

  factory Family.fromJson(Map<String, dynamic> j) => Family(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        slogan: j['slogan'] as String?,
        emoji: j['emoji'] as String? ?? '🏡',
        createdAt: _parseDate(j['created_at']),
        memberCount: (j['member_count'] as num?)?.toInt() ?? 0,
        myRole: j['my_role'] as String? ?? 'member',
        myUnreadCount: (j['my_unread_count'] as num?)?.toInt() ?? 0,
      );
}

class Member {
  const Member({
    required this.userId,
    required this.familyId,
    required this.role,
    required this.displayName,
    required this.avatarEmoji,
    this.avatarUrl,
    this.joinedAt,
    required this.status,
  });

  final String userId;
  final String familyId;
  final String role;
  final String displayName;
  final String avatarEmoji;

  /// 成员真实头像的相对地址（已含 /api/v1，带 ?v=）；为空时回退到 [avatarEmoji]。
  final String? avatarUrl;
  final DateTime? joinedAt;
  final String status; // active | pending

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        userId: j['user_id'] as String,
        familyId: j['family_id'] as String? ?? '',
        role: j['role'] as String? ?? 'member',
        displayName: j['display_name'] as String? ?? '',
        avatarEmoji: j['avatar_emoji'] as String? ?? '👤',
        avatarUrl: j['avatar_url'] as String?,
        joinedAt: _parseDate(j['joined_at']),
        status: j['status'] as String? ?? 'active',
      );
}

class Permission {
  const Permission({required this.code, required this.label});
  final String code;
  final String label;

  factory Permission.fromJson(Map<String, dynamic> j) => Permission(
        code: j['code'] as String? ?? '',
        label: j['label'] as String? ?? '',
      );
}

class Plugin {
  const Plugin({
    required this.id,
    required this.name,
    required this.descriptionShort,
    required this.descriptionLong,
    required this.emoji,
    required this.category,
    required this.colorToken,
    required this.version,
    required this.publisher,
    required this.permissions,
    required this.screenshots,
    required this.sizeKb,
    required this.rating,
    required this.installCount,
    this.multiInstance = false,
  });

  final String id;
  final String name;
  final String descriptionShort;
  final String descriptionLong;
  final String emoji;
  final String category; // life | finance | health | education | entertainment
  final String colorToken; // photo | money | anniv | chore | pet | accent
  final String version;
  final String publisher;
  final List<Permission> permissions;
  final List<String> screenshots;
  final int sizeKb;
  final double rating;
  final int installCount;

  /// 是否允许一个家庭安装多张（每张卡可独立配置，如纪念日绑定不同日子）。
  final bool multiInstance;

  factory Plugin.fromJson(Map<String, dynamic> j) => Plugin(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        descriptionShort: j['description_short'] as String? ?? '',
        descriptionLong: j['description_long'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '🧩',
        category: j['category'] as String? ?? 'life',
        colorToken: j['color_token'] as String? ?? 'accent',
        version: j['version'] as String? ?? '',
        publisher: j['publisher'] as String? ?? '',
        permissions: ((j['permissions'] as List?) ?? [])
            .map((e) => Permission.fromJson(e as Map<String, dynamic>))
            .toList(),
        screenshots: ((j['screenshots'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
        sizeKb: (j['size_kb'] as num?)?.toInt() ?? 0,
        rating: (j['rating'] as num?)?.toDouble() ?? 0,
        installCount: (j['install_count'] as num?)?.toInt() ?? 0,
        multiInstance: j['multi_instance'] as bool? ?? false,
      );
}

class PluginLayout {
  const PluginLayout({
    required this.col,
    required this.row,
    required this.cw,
    required this.ch,
  });

  final int col;
  final int row;
  final int cw;
  final int ch;

  factory PluginLayout.fromJson(Map<String, dynamic> j) => PluginLayout(
        col: (j['col'] as num?)?.toInt() ?? 0,
        row: (j['row'] as num?)?.toInt() ?? 0,
        cw: (j['cw'] as num?)?.toInt() ?? 2,
        ch: (j['ch'] as num?)?.toInt() ?? 2,
      );

  PluginLayout copyWith({int? col, int? row, int? cw, int? ch}) => PluginLayout(
        col: col ?? this.col,
        row: row ?? this.row,
        cw: cw ?? this.cw,
        ch: ch ?? this.ch,
      );
}

class PluginPreview {
  const PluginPreview({
    required this.primary,
    this.secondary,
    this.badge,
    required this.colorToken,
    this.emoji,
    this.secondaryTone,
    this.imageUrls = const [],
  });

  final String primary;
  final String? secondary;
  final String? badge;
  final String colorToken;

  /// 卡片主图标。为空时回退到插件 manifest 的 emoji（让卡片能显示内容自身的
  /// emoji，如所选纪念日的 emoji 而非插件的 🎂）。
  final String? emoji;

  /// secondary 文字的强调色（warning / danger），为空表示正常色。
  /// 见 theme/color_token.dart 的 colorForTone。
  final String? secondaryTone;

  /// 卡片右侧轮播缩略图（host 相对路径，加载时拼 baseUrl + 图片鉴权头）。
  /// 4×2 大卡才会用上；为空表示不展示轮播。
  final List<String> imageUrls;

  factory PluginPreview.fromJson(Map<String, dynamic> j) => PluginPreview(
        primary: j['primary'] as String? ?? '',
        secondary: j['secondary'] as String?,
        badge: j['badge'] as String?,
        colorToken: j['color_token'] as String? ?? 'accent',
        emoji: j['emoji'] as String?,
        secondaryTone: j['secondary_tone'] as String?,
        imageUrls: (j['image_urls'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const [],
      );
}

class InstalledPlugin {
  const InstalledPlugin({
    required this.id,
    required this.familyId,
    required this.pluginId,
    required this.plugin,
    required this.enabled,
    required this.layout,
    required this.preview,
    this.config = const {},
  });

  final String id;
  final String familyId;
  final String pluginId;
  final Plugin plugin;
  final bool enabled;
  final PluginLayout layout;
  final PluginPreview preview;

  /// 单卡配置（如纪念日 `{"anniversary_id": "..."}`）。空 = 总览/未绑定。
  final Map<String, dynamic> config;

  factory InstalledPlugin.fromJson(Map<String, dynamic> j) => InstalledPlugin(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        pluginId: j['plugin_id'] as String? ?? '',
        plugin: Plugin.fromJson(j['plugin'] as Map<String, dynamic>),
        enabled: j['enabled'] as bool? ?? true,
        layout: PluginLayout.fromJson(j['layout'] as Map<String, dynamic>),
        preview: PluginPreview.fromJson(j['preview'] as Map<String, dynamic>),
        config: (j['config'] as Map<String, dynamic>?) ?? const {},
      );

  InstalledPlugin copyWith({
    PluginLayout? layout,
    Map<String, dynamic>? config,
  }) =>
      InstalledPlugin(
        id: id,
        familyId: familyId,
        pluginId: pluginId,
        plugin: plugin,
        enabled: enabled,
        layout: layout ?? this.layout,
        preview: preview,
        config: config ?? this.config,
      );
}

class Bootstrap {
  const Bootstrap({
    required this.user,
    this.currentFamily,
    required this.families,
    required this.installedPlugins,
    required this.unreadCount,
  });

  final WoUser user;
  final Family? currentFamily;
  final List<Family> families;
  final List<InstalledPlugin> installedPlugins;
  final int unreadCount;

  factory Bootstrap.fromJson(Map<String, dynamic> j) => Bootstrap(
        user: WoUser.fromJson(j['user'] as Map<String, dynamic>),
        currentFamily: j['current_family'] == null
            ? null
            : Family.fromJson(j['current_family'] as Map<String, dynamic>),
        families: ((j['families'] as List?) ?? [])
            .map((e) => Family.fromJson(e as Map<String, dynamic>))
            .toList(),
        installedPlugins: ((j['installed_plugins'] as List?) ?? [])
            .map((e) => InstalledPlugin.fromJson(e as Map<String, dynamic>))
            .toList(),
        unreadCount: (j['unread_count'] as num?)?.toInt() ?? 0,
      );
}

class Me {
  const Me({required this.user, this.currentFamily, required this.stats});

  final WoUser user;
  final Family? currentFamily;
  final Stats stats;

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        user: WoUser.fromJson(j['user'] as Map<String, dynamic>),
        currentFamily: j['current_family'] == null
            ? null
            : Family.fromJson(j['current_family'] as Map<String, dynamic>),
        stats: Stats.fromJson(j['stats'] as Map<String, dynamic>),
      );
}

class WoNotification {
  const WoNotification({
    required this.id,
    required this.type,
    this.familyId,
    required this.title,
    required this.body,
    required this.iconEmoji,
    this.deeplink,
    this.readAt,
    this.createdAt,
  });

  final String id;
  final String type;
  final String? familyId;
  final String title;
  final String body;
  final String iconEmoji;
  final String? deeplink;
  final DateTime? readAt;
  final DateTime? createdAt;

  bool get isRead => readAt != null;

  factory WoNotification.fromJson(Map<String, dynamic> j) => WoNotification(
        id: j['id'] as String,
        type: j['type'] as String? ?? '',
        familyId: j['family_id'] as String?,
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        iconEmoji: j['icon_emoji'] as String? ?? '🔔',
        deeplink: j['deeplink'] as String?,
        readAt: _parseDate(j['read_at']),
        createdAt: _parseDate(j['created_at']),
      );
}

class InvitationResult {
  const InvitationResult({
    required this.code,
    required this.link,
    required this.qrPayload,
    this.expiresAt,
  });

  final String code;
  final String link;
  final String qrPayload;
  final DateTime? expiresAt;

  factory InvitationResult.fromJson(Map<String, dynamic> j) => InvitationResult(
        code: j['code'] as String? ?? '',
        link: j['link'] as String? ?? '',
        qrPayload: j['qr_payload'] as String? ?? '',
        expiresAt: _parseDate(j['expires_at']),
      );
}

/// 纪念日插件的一条记录（对应后端 anniv_dates 表 / AnniversaryRead）。
class Anniversary {
  const Anniversary({
    required this.id,
    required this.familyId,
    required this.name,
    required this.eventDate,
    required this.emoji,
    required this.isLunar,
    this.note,
    this.createdAt,
    required this.daysUntil,
    this.notifyEnabled = false,
    this.notifyDaysBefore = 0,
  });

  final String id;
  final String familyId;
  final String name;
  final DateTime eventDate;
  final String emoji;
  final bool isLunar;
  final String? note;
  final DateTime? createdAt;

  /// 距离下一次发生还有多少天（后端计算，农历会按农历周年推算）。
  final int daysUntil;

  /// 到期提醒开关，以及提前几天提醒（0 = 当天）。
  final bool notifyEnabled;
  final int notifyDaysBefore;

  factory Anniversary.fromJson(Map<String, dynamic> j) => Anniversary(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        eventDate: _parseDate(j['event_date']) ?? DateTime.now(),
        emoji: j['emoji'] as String? ?? '💞',
        isLunar: j['is_lunar'] as bool? ?? false,
        note: j['note'] as String?,
        createdAt: _parseDate(j['created_at']),
        daysUntil: (j['days_until'] as num?)?.toInt() ?? 0,
        notifyEnabled: j['notify_enabled'] as bool? ?? false,
        notifyDaysBefore: (j['notify_days_before'] as num?)?.toInt() ?? 0,
      );
}

class Expense {
  const Expense({
    required this.id,
    required this.familyId,
    required this.amount,
    required this.category,
    this.note,
    this.createdBy,
    this.creatorName,
    this.creatorEmoji,
    this.creatorAvatarUrl,
    this.createdAt,
  });

  final String id;
  final String familyId;
  final double amount;
  final String category; // dining | shopping | utilities | car
  final String? note;
  final String? createdBy;
  final String? creatorName;
  final String? creatorEmoji;

  /// 记录人真实头像的相对地址（已含 /api/v1，带 ?v=）；为空时回退到 [creatorEmoji]。
  final String? creatorAvatarUrl;
  final DateTime? createdAt;

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        amount: _parseNum(j['amount']),
        category: j['category'] as String? ?? '',
        note: j['note'] as String?,
        createdBy: j['created_by'] as String?,
        creatorName: j['creator_name'] as String?,
        creatorEmoji: j['creator_emoji'] as String?,
        creatorAvatarUrl: j['creator_avatar_url'] as String?,
        createdAt: _parseDate(j['created_at']),
      );
}

class AccountingSummary {
  const AccountingSummary({
    required this.monthTotal,
    this.budget,
    this.remaining,
  });

  final double monthTotal;
  final double? budget;
  final double? remaining;

  factory AccountingSummary.fromJson(Map<String, dynamic> j) =>
      AccountingSummary(
        monthTotal: _parseNum(j['month_total']),
        budget: _parseNumOrNull(j['budget']),
        remaining: _parseNumOrNull(j['remaining']),
      );
}

/// 菜谱里的一条食材，如 {name: 番茄, amount: 2个}。
class RecipeIngredient {
  const RecipeIngredient({required this.name, this.amount = ''});

  final String name;
  final String amount;

  factory RecipeIngredient.fromJson(Map<String, dynamic> j) => RecipeIngredient(
        name: j['name'] as String? ?? '',
        amount: j['amount'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'name': name, 'amount': amount};
}

class Recipe {
  const Recipe({
    required this.id,
    required this.familyId,
    required this.name,
    required this.emoji,
    required this.category,
    required this.minutes,
    required this.difficulty,
    this.servings,
    this.note,
    this.ingredients = const [],
    this.steps = const [],
    this.createdBy,
    this.creatorName,
    this.creatorEmoji,
    this.creatorAvatarUrl,
    this.createdAt,
    this.coverUrl,
    this.coverVersion = 0,
  });

  final String id;
  final String familyId;
  final String name;
  final String emoji;
  final String category;

  /// 烹饪时长（分钟）。
  final int minutes;

  /// 难度 1..3：简单 / 中等 / 有点难。
  final int difficulty;

  /// 几人份，可空。
  final int? servings;
  final String? note;
  final List<RecipeIngredient> ingredients;
  final List<String> steps;

  final String? createdBy;
  final String? creatorName;
  final String? creatorEmoji;

  /// 作者真实头像的相对地址（已含 /api/v1，带 ?v=）；为空时回退到 [creatorEmoji]。
  final String? creatorAvatarUrl;
  final DateTime? createdAt;

  /// 封面照片的相对地址（已含 /api/v1，带 ?v= 版本号）。为空表示没传过照片，用 emoji。
  final String? coverUrl;

  /// 封面版本号，每次上传 +1；URL 里的 ?v= 据此变化，从而刷新本地缓存。
  final int coverVersion;

  bool get hasCover => coverUrl != null && coverUrl!.isNotEmpty;

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '🍳',
        category: j['category'] as String? ?? '',
        minutes: (j['minutes'] as num?)?.toInt() ?? 0,
        difficulty: (j['difficulty'] as num?)?.toInt() ?? 1,
        servings: (j['servings'] as num?)?.toInt(),
        note: j['note'] as String?,
        ingredients: ((j['ingredients'] as List?) ?? const [])
            .map((e) => RecipeIngredient.fromJson(e as Map<String, dynamic>))
            .toList(),
        steps: ((j['steps'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        createdBy: j['created_by'] as String?,
        creatorName: j['creator_name'] as String?,
        creatorEmoji: j['creator_emoji'] as String?,
        creatorAvatarUrl: j['creator_avatar_url'] as String?,
        createdAt: _parseDate(j['created_at']),
        coverUrl: j['cover_url'] as String?,
        coverVersion: (j['cover_version'] as num?)?.toInt() ?? 0,
      );
}

/// 家务插件的一条待办（对应后端 chore_chores 表 / ChoreRead）。
class Chore {
  const Chore({
    required this.id,
    required this.familyId,
    required this.title,
    this.note,
    required this.emoji,
    this.assignedTo,
    required this.done,
    this.recurring = false,
    this.completedAt,
    this.createdAt,
    this.createdBy,
    this.assigneeName,
    this.assigneeEmoji,
    this.assigneeAvatarUrl,
  });

  final String id;
  final String familyId;
  final String title;
  final String? note;
  final String emoji;

  /// 负责人 user id，可空（未指派）。
  final String? assignedTo;
  final bool done;

  /// 是否每周重复。重复家务可被「一键重新匹配」批量重置为待做。
  final bool recurring;
  final DateTime? completedAt;
  final DateTime? createdAt;
  final String? createdBy;

  /// 负责人展示信息，后端注入；未指派或该成员已离开时为空。
  final String? assigneeName;
  final String? assigneeEmoji;

  /// 负责人真实头像的相对地址（已含 /api/v1，带 ?v=）；为空时回退到 [assigneeEmoji]。
  final String? assigneeAvatarUrl;

  bool get isAssigned => assignedTo != null && assignedTo!.isNotEmpty;

  factory Chore.fromJson(Map<String, dynamic> j) => Chore(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        note: j['note'] as String?,
        emoji: j['emoji'] as String? ?? '🧹',
        assignedTo: j['assigned_to'] as String?,
        done: j['done'] as bool? ?? false,
        recurring: j['recurring'] as bool? ?? false,
        completedAt: _parseDate(j['completed_at']),
        createdAt: _parseDate(j['created_at']),
        createdBy: j['created_by'] as String?,
        assigneeName: j['assignee_name'] as String?,
        assigneeEmoji: j['assignee_emoji'] as String?,
        assigneeAvatarUrl: j['assignee_avatar_url'] as String?,
      );
}

/// 囤货铺插件 · 一条家庭囤货（对应后端 stock_items 表 / StockItemRead）。
class StockItem {
  const StockItem({
    required this.id,
    required this.familyId,
    required this.name,
    required this.emoji,
    required this.qty,
    this.unit,
    this.lowAt,
    this.note,
    required this.isLow,
    this.createdAt,
    this.createdBy,
  });

  final String id;
  final String familyId;
  final String name;
  final String emoji;
  final int qty;

  /// 单位，可空（如「瓶」「卷」）。
  final String? unit;

  /// 低量阈值，可空；为空表示永不告急。
  final int? lowAt;
  final String? note;

  /// 后端算好的「告急」标记：设了阈值且 qty <= lowAt。
  final bool isLow;
  final DateTime? createdAt;
  final String? createdBy;

  factory StockItem.fromJson(Map<String, dynamic> j) => StockItem(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '📦',
        qty: (j['qty'] as num?)?.toInt() ?? 0,
        unit: j['unit'] as String?,
        lowAt: (j['low_at'] as num?)?.toInt(),
        note: j['note'] as String?,
        isLow: j['is_low'] as bool? ?? false,
        createdAt: _parseDate(j['created_at']),
        createdBy: j['created_by'] as String?,
      );
}

/// 囤货铺插件 · 一条采买待买（对应后端 stock_buys 表 / BuyItemRead）。
class BuyItem {
  const BuyItem({
    required this.id,
    required this.familyId,
    required this.name,
    required this.emoji,
    this.wantQty,
    this.note,
    this.stockItemId,
    required this.bought,
    this.boughtAt,
    this.createdAt,
    this.createdBy,
  });

  final String id;
  final String familyId;
  final String name;
  final String emoji;

  /// 想买多少，自由文本（如「2 瓶」「一大袋」），可空。
  final String? wantQty;
  final String? note;

  /// 这条待买关联的囤货项 id，可空（手动添加的零散待买无关联）。
  final String? stockItemId;
  final bool bought;
  final DateTime? boughtAt;
  final DateTime? createdAt;
  final String? createdBy;

  factory BuyItem.fromJson(Map<String, dynamic> j) => BuyItem(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '🛒',
        wantQty: j['want_qty'] as String?,
        note: j['note'] as String?,
        stockItemId: j['stock_item_id'] as String?,
        bought: j['bought'] as bool? ?? false,
        boughtAt: _parseDate(j['bought_at']),
        createdAt: _parseDate(j['created_at']),
        createdBy: j['created_by'] as String?,
      );
}

class InvitationPreview {
  const InvitationPreview({
    required this.familyName,
    required this.familyEmoji,
    required this.memberCount,
    this.inviterName,
    required this.role,
    this.expiresAt,
  });

  final String familyName;
  final String familyEmoji;
  final int memberCount;
  final String? inviterName;
  final String role;
  final DateTime? expiresAt;

  factory InvitationPreview.fromJson(Map<String, dynamic> j) {
    final fam = (j['family'] as Map<String, dynamic>?) ?? const {};
    final inviter = j['inviter'] as Map<String, dynamic>?;
    return InvitationPreview(
      familyName: fam['name'] as String? ?? '',
      familyEmoji: fam['emoji'] as String? ?? '🏡',
      memberCount: (fam['member_count'] as num?)?.toInt() ?? 0,
      inviterName: inviter?['display_name'] as String?,
      role: j['role'] as String? ?? 'member',
      expiresAt: _parseDate(j['expires_at']),
    );
  }
}

/// 单个可开关的通知来源（家庭动态 / 某个有通知机制的插件）。
class NotificationSource {
  const NotificationSource({
    required this.key,
    required this.label,
    required this.emoji,
    required this.enabled,
  });

  final String key;
  final String label;
  final String emoji;
  final bool enabled;

  NotificationSource copyWith({bool? enabled}) => NotificationSource(
        key: key,
        label: label,
        emoji: emoji,
        enabled: enabled ?? this.enabled,
      );

  factory NotificationSource.fromJson(Map<String, dynamic> j) =>
      NotificationSource(
        key: j['key'] as String,
        label: j['label'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '🔔',
        enabled: j['enabled'] as bool? ?? true,
      );
}

/// 通知偏好：总推送开关 + 各来源开关。仅影响是否推送到手机系统通知栏。
class NotificationPreferences {
  const NotificationPreferences({
    required this.pushEnabled,
    required this.sources,
  });

  final bool pushEnabled;
  final List<NotificationSource> sources;

  factory NotificationPreferences.fromJson(Map<String, dynamic> j) =>
      NotificationPreferences(
        pushEnabled: j['push_enabled'] as bool? ?? true,
        sources: ((j['sources'] as List?) ?? const [])
            .map((e) => NotificationSource.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ── 回忆插件 ──────────────────────────────────────────────────────────────

/// 一段回忆挂的一张照片或一段视频。`url` 已含 /api/v1，加载时拼上 host + 鉴权头。
class MemoryMedia {
  const MemoryMedia({
    required this.id,
    required this.memoryId,
    required this.kind,
    required this.url,
    required this.contentType,
    required this.sizeBytes,
    this.width,
    this.height,
    this.durationMs,
    this.sortOrder = 0,
  });

  final String id;
  final String memoryId;
  final String kind; // photo | video
  final String url;
  final String contentType;
  final int sizeBytes;
  final int? width;
  final int? height;
  final int? durationMs;
  final int sortOrder;

  bool get isVideo => kind == 'video';

  /// 视频时长格式化成 m:ss（用于角标）；非视频或缺时长返回 null。
  String? get durationLabel {
    if (durationMs == null || durationMs! <= 0) return null;
    final totalSec = (durationMs! / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  factory MemoryMedia.fromJson(Map<String, dynamic> j) => MemoryMedia(
        id: j['id'] as String,
        memoryId: j['memory_id'] as String? ?? '',
        kind: j['kind'] as String? ?? 'photo',
        url: j['url'] as String? ?? '',
        contentType: j['content_type'] as String? ?? '',
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
        durationMs: (j['duration_ms'] as num?)?.toInt(),
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      );
}

/// 另一半在回忆下的一条留言。
class MemoryComment {
  const MemoryComment({
    required this.id,
    required this.body,
    this.authorId,
    this.authorName,
    this.authorEmoji,
    this.authorAvatarUrl,
    this.createdAt,
  });

  final String id;
  final String body;
  final String? authorId;
  final String? authorName;
  final String? authorEmoji;

  /// 作者真实头像的相对地址（已含 /api/v1，带 ?v=）；为空时回退到 [authorEmoji]。
  final String? authorAvatarUrl;
  final DateTime? createdAt;

  factory MemoryComment.fromJson(Map<String, dynamic> j) => MemoryComment(
        id: j['id'] as String,
        body: j['body'] as String? ?? '',
        authorId: j['author_id'] as String?,
        authorName: j['author_name'] as String?,
        authorEmoji: j['author_emoji'] as String?,
        authorAvatarUrl: j['author_avatar_url'] as String?,
        createdAt: _parseDate(j['created_at']),
      );
}

/// 时间线上的一段回忆：标题 + 文案 + 媒体 + 元信息 + 留言。
class Memory {
  const Memory({
    required this.id,
    required this.familyId,
    required this.title,
    this.body,
    this.mood,
    this.location,
    this.visibility = 'family',
    required this.eventDate,
    this.createdBy,
    this.authorName,
    this.authorEmoji,
    this.authorAvatarUrl,
    this.createdAt,
    this.media = const [],
    this.commentCount = 0,
    this.comments = const [],
  });

  final String id;
  final String familyId;
  final String title;
  final String? body;
  final String? mood;
  final String? location;
  final String visibility; // family | couple | private
  final DateTime eventDate;
  final String? createdBy;
  final String? authorName;
  final String? authorEmoji;

  /// 创建者真实头像的相对地址（已含 /api/v1，带 ?v=）；为空时回退到 [authorEmoji]。
  final String? authorAvatarUrl;
  final DateTime? createdAt;
  final List<MemoryMedia> media;
  final int commentCount;
  final List<MemoryComment> comments;

  bool get hasMedia => media.isNotEmpty;

  factory Memory.fromJson(Map<String, dynamic> j) => Memory(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        body: j['body'] as String?,
        mood: j['mood'] as String?,
        location: j['location'] as String?,
        visibility: j['visibility'] as String? ?? 'family',
        eventDate: _parseDate(j['event_date']) ?? DateTime.now(),
        createdBy: j['created_by'] as String?,
        authorName: j['author_name'] as String?,
        authorEmoji: j['author_emoji'] as String?,
        authorAvatarUrl: j['author_avatar_url'] as String?,
        createdAt: _parseDate(j['created_at']),
        media: ((j['media'] as List?) ?? const [])
            .map((e) => MemoryMedia.fromJson(e as Map<String, dynamic>))
            .toList(),
        commentCount: (j['comment_count'] as num?)?.toInt() ?? 0,
        comments: ((j['comments'] as List?) ?? const [])
            .map((e) => MemoryComment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ── 看电影插件 ────────────────────────────────────────────────────────────

/// 一部想看 / 看过的电影。
class Movie {
  const Movie({
    required this.id,
    required this.familyId,
    required this.title,
    this.note,
    this.watched = false,
    this.watchedAt,
    this.createdAt,
    this.createdBy,
    this.intro,
    this.doubanRating,
    this.posterUrl,
    this.aiStatus = 'none',
  });

  final String id;
  final String familyId;
  final String title;
  final String? note;
  final bool watched;
  final DateTime? watchedAt;
  final DateTime? createdAt;
  final String? createdBy;

  /// AI 自动补充的剧情简介（100-150 字），未补充时为空。
  final String? intro;

  /// AI 给出的豆瓣评分（近似值），未知为空。
  final double? doubanRating;

  /// 海报相对地址（已含 /api/v1，带 ?v= 缓存键）；为空表示没有海报。
  final String? posterUrl;

  /// AI 补充状态：none / pending（补充中）/ ready / failed。
  final String aiStatus;

  bool get aiPending => aiStatus == 'pending';
  bool get aiFailed => aiStatus == 'failed';

  factory Movie.fromJson(Map<String, dynamic> j) => Movie(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        note: j['note'] as String?,
        watched: j['watched'] as bool? ?? false,
        watchedAt: _parseDate(j['watched_at']),
        createdAt: _parseDate(j['created_at']),
        createdBy: j['created_by'] as String?,
        intro: j['intro'] as String?,
        doubanRating: _parseNumOrNull(j['douban_rating']),
        posterUrl: j['poster_url'] as String?,
        aiStatus: j['ai_status'] as String? ?? 'none',
      );
}

/// 解析后端的纯日期字段（"YYYY-MM-DD"），返回当地午夜的 [DateTime]，不做时区换算。
DateTime? _parseDateOnly(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  final d = DateTime.tryParse(s);
  if (d == null) return null;
  return DateTime(d.year, d.month, d.day);
}

/// 家历插件 · 一条日程 / 待办（对应后端 calendar_items 表 / CalendarItemRead）。
///
/// 统一模型：[eventDate] 非空 = 排到某天的日程；为空 = 没有日期的待办。
/// [allDay] 为 false 且 [startMinute] 非空时是定时日程。[repeat] 为
/// none/daily/weekly/monthly。重复项「完成」时后端把 [eventDate] 前移到下次发生。
class CalendarItem {
  const CalendarItem({
    required this.id,
    required this.familyId,
    required this.title,
    this.note,
    required this.emoji,
    this.eventDate,
    this.allDay = true,
    this.startMinute,
    this.repeat = 'none',
    this.assignedTo,
    required this.done,
    this.completedAt,
    this.notifyEnabled = false,
    this.notifyDaysBefore = 0,
    this.nextDate,
    this.daysUntil,
    this.createdAt,
    this.createdBy,
    this.assigneeName,
    this.assigneeEmoji,
    this.assigneeAvatarUrl,
  });

  final String id;
  final String familyId;
  final String title;
  final String? note;
  final String emoji;

  /// 日程发生 / 待办到期的日期；为空表示没有日期的待办。
  final DateTime? eventDate;
  final bool allDay;

  /// 一天中的分钟数（0..1439），定时日程才有；全天为空。
  final int? startMinute;

  /// 重复规则：none / daily / weekly / monthly。
  final String repeat;

  /// 负责人 user id，可空（未指派）。
  final String? assignedTo;
  final bool done;
  final DateTime? completedAt;

  final bool notifyEnabled;
  final int notifyDaysBefore;

  /// 后端算好的下次发生日期（重复项已前移过今天）；无日期待办为空。
  final DateTime? nextDate;

  /// 距 [nextDate] 还有几天（负数=已过期）；无日期待办为空。
  final int? daysUntil;

  final DateTime? createdAt;
  final String? createdBy;

  /// 负责人展示信息，后端注入；未指派或该成员已离开时为空。
  final String? assigneeName;
  final String? assigneeEmoji;

  /// 负责人真实头像的相对地址（已含 /api/v1，带 ?v=）；为空时回退到 [assigneeEmoji]。
  final String? assigneeAvatarUrl;

  bool get isAssigned => assignedTo != null && assignedTo!.isNotEmpty;
  bool get isTodo => eventDate == null;
  bool get isRecurring => repeat != 'none';

  /// 定时日程的「HH:mm」；全天 / 无日期返回空串。
  String get timeLabel {
    final m = startMinute;
    if (allDay || m == null) return '';
    final h = (m ~/ 60).toString().padLeft(2, '0');
    final mm = (m % 60).toString().padLeft(2, '0');
    return '$h:$mm';
  }

  factory CalendarItem.fromJson(Map<String, dynamic> j) => CalendarItem(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        note: j['note'] as String?,
        emoji: j['emoji'] as String? ?? '📅',
        eventDate: _parseDateOnly(j['event_date']),
        allDay: j['all_day'] as bool? ?? true,
        startMinute: (j['start_minute'] as num?)?.toInt(),
        repeat: j['repeat'] as String? ?? 'none',
        assignedTo: j['assigned_to'] as String?,
        done: j['done'] as bool? ?? false,
        completedAt: _parseDate(j['completed_at']),
        notifyEnabled: j['notify_enabled'] as bool? ?? false,
        notifyDaysBefore: (j['notify_days_before'] as num?)?.toInt() ?? 0,
        nextDate: _parseDateOnly(j['next_date']),
        daysUntil: (j['days_until'] as num?)?.toInt(),
        createdAt: _parseDate(j['created_at']),
        createdBy: j['created_by'] as String?,
        assigneeName: j['assignee_name'] as String?,
        assigneeEmoji: j['assignee_emoji'] as String?,
        assigneeAvatarUrl: j['assignee_avatar_url'] as String?,
      );
}

/// 订阅管家插件 · 一条订阅 / 定期账单（对应后端 subscription_items / SubscriptionRead）。
///
/// [cycle] 为 monthly / yearly。到期时若 [autoRecord] 且家庭装了记账，后端会自动把这笔
/// 扣费记进账本（订阅分类）并把 [nextDue] 顺延一个周期。[daysUntil] 由后端算好。
class Subscription {
  const Subscription({
    required this.id,
    required this.familyId,
    required this.name,
    required this.emoji,
    required this.amount,
    required this.cycle,
    required this.nextDue,
    this.note,
    this.notifyEnabled = true,
    this.notifyDaysBefore = 3,
    this.autoRecord = true,
    this.active = true,
    this.daysUntil = 0,
    this.createdAt,
    this.createdBy,
  });

  final String id;
  final String familyId;
  final String name;
  final String emoji;
  final double amount;

  /// 计费周期：monthly（按月）/ yearly（按年）。
  final String cycle;

  /// 下次扣费日期。
  final DateTime nextDue;
  final String? note;
  final bool notifyEnabled;
  final int notifyDaysBefore;

  /// 到期是否自动记入「记账」（仅当家庭装了记账才会真正写入）。
  final bool autoRecord;

  /// 是否启用；暂停的订阅不提醒也不扣费。
  final bool active;

  /// 距 [nextDue] 还有几天（负数=已过期）。
  final int daysUntil;
  final DateTime? createdAt;
  final String? createdBy;

  bool get isYearly => cycle == 'yearly';

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '💳',
        amount: _parseNum(j['amount']),
        cycle: j['cycle'] as String? ?? 'monthly',
        nextDue: _parseDateOnly(j['next_due']) ?? DateTime.now(),
        note: j['note'] as String?,
        notifyEnabled: j['notify_enabled'] as bool? ?? true,
        notifyDaysBefore: (j['notify_days_before'] as num?)?.toInt() ?? 3,
        autoRecord: j['auto_record'] as bool? ?? true,
        active: j['active'] as bool? ?? true,
        daysUntil: (j['days_until'] as num?)?.toInt() ?? 0,
        createdAt: _parseDate(j['created_at']),
        createdBy: j['created_by'] as String?,
      );
}

/// 植物日记 —— 一株植物的档案。
class Plant {
  const Plant({
    required this.id,
    required this.familyId,
    required this.name,
    this.emoji = '🌿',
    this.species,
    this.placement = '室内',
    this.waterIntervalDays,
    this.fertIntervalDays,
    this.nextWaterDue,
    this.nextFertDue,
    this.coverUrl,
  });

  final String id;
  final String familyId;
  final String name;
  final String emoji;
  final String? species;

  /// 摆放位置（室内 / 阳台 / 朝南窗…），决定真实光照。
  final String placement;

  /// 用户设定的浇水/施肥周期（天）；为空表示尚未设定、未开启提醒。
  final int? waterIntervalDays;
  final int? fertIntervalDays;

  /// 下次浇水/施肥到期日（提醒据此触发）。
  final DateTime? nextWaterDue;
  final DateTime? nextFertDue;

  /// 封面相对地址（已含 /api/v1，带 ?v= 缓存键）；为空表示无封面。
  final String? coverUrl;

  factory Plant.fromJson(Map<String, dynamic> j) => Plant(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '🌿',
        species: j['species'] as String?,
        placement: j['placement'] as String? ?? '室内',
        waterIntervalDays: (j['water_interval_days'] as num?)?.toInt(),
        fertIntervalDays: (j['fert_interval_days'] as num?)?.toInt(),
        nextWaterDue: _parseDateOnly(j['next_water_due']),
        nextFertDue: _parseDateOnly(j['next_fert_due']),
        coverUrl: j['cover_url'] as String?,
      );
}

/// 植物日记 —— 一条养护记录（照片 + AI 分析）。
class PlantLog {
  const PlantLog({
    required this.id,
    required this.plantId,
    required this.familyId,
    this.createdAt,
    this.note,
    this.envSnapshot,
    this.aiStatus = 'pending',
    this.aiAssessment,
    this.aiAdvice,
    this.aiSuggestedWaterDays,
    this.aiSuggestedFertDays,
    this.photoUrl,
  });

  final String id;
  final String plantId;
  final String familyId;
  final DateTime? createdAt;
  final String? note;

  /// 记录时的环境快照（天气 + 摆放），结构化展示用。
  final Map<String, dynamic>? envSnapshot;

  /// AI 分析状态：pending（分析中）/ ready / failed。
  final String aiStatus;
  final String? aiAssessment;

  /// 结构化建议 {watering, fertilizing, pruning}。
  final Map<String, dynamic>? aiAdvice;

  /// AI 建议的浇水/施肥周期（天），供用户一键采纳。
  final int? aiSuggestedWaterDays;
  final int? aiSuggestedFertDays;

  /// 照片相对地址（已含 /api/v1，带 ?v= 缓存键）。
  final String? photoUrl;

  bool get aiPending => aiStatus == 'pending';
  bool get aiFailed => aiStatus == 'failed';

  factory PlantLog.fromJson(Map<String, dynamic> j) => PlantLog(
        id: j['id'] as String,
        plantId: j['plant_id'] as String? ?? '',
        familyId: j['family_id'] as String? ?? '',
        createdAt: _parseDate(j['created_at']),
        note: j['note'] as String?,
        envSnapshot: (j['env_snapshot'] as Map?)?.cast<String, dynamic>(),
        aiStatus: j['ai_status'] as String? ?? 'pending',
        aiAssessment: j['ai_assessment'] as String?,
        aiAdvice: (j['ai_advice'] as Map?)?.cast<String, dynamic>(),
        aiSuggestedWaterDays: (j['ai_suggested_water_days'] as num?)?.toInt(),
        aiSuggestedFertDays: (j['ai_suggested_fert_days'] as num?)?.toInt(),
        photoUrl: j['photo_url'] as String?,
      );
}

/// 植物日记 —— 家庭级默认环境（定位）。
class PlantFamilySettings {
  const PlantFamilySettings({
    this.latitude,
    this.longitude,
    this.locationLabel,
  });

  final double? latitude;
  final double? longitude;
  final String? locationLabel;

  bool get hasLocation => latitude != null && longitude != null;

  factory PlantFamilySettings.fromJson(Map<String, dynamic> j) =>
      PlantFamilySettings(
        latitude: _parseNumOrNull(j['latitude']),
        longitude: _parseNumOrNull(j['longitude']),
        locationLabel: j['location_label'] as String?,
      );
}
