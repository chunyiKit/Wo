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

/// 拍小票识别出的一笔「草稿」支出。后端不落库、不存图，仅用于预填「记一笔」
/// 表单，由用户确认后再正式记账。[amount] 为空表示没认出金额（让用户手填）。
class ReceiptDraft {
  const ReceiptDraft(
      {this.amount, required this.category, this.merchant, this.note});

  final double? amount;
  final String category;
  final String? merchant;
  final String? note;

  factory ReceiptDraft.fromJson(Map<String, dynamic> j) => ReceiptDraft(
        amount: _parseNumOrNull(j['amount']),
        category: j['category'] as String? ?? 'shopping',
        merchant: j['merchant'] as String?,
        note: j['note'] as String?,
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

  /// 本地缓存用：键名与 [fromJson] 对称，可直接回灌。
  Map<String, dynamic> toJson() => {
        'id': id,
        'memory_id': memoryId,
        'kind': kind,
        'url': url,
        'content_type': contentType,
        'size_bytes': sizeBytes,
        'width': width,
        'height': height,
        'duration_ms': durationMs,
        'sort_order': sortOrder,
      };
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

  /// 本地缓存用：键名与 [fromJson] 对称。留言不入缓存（列表不展示，详情页会自己拉），
  /// 缓存体积更小。
  Map<String, dynamic> toJson() => {
        'id': id,
        'family_id': familyId,
        'title': title,
        'body': body,
        'mood': mood,
        'location': location,
        'visibility': visibility,
        'event_date': eventDate.toIso8601String(),
        'created_by': createdBy,
        'author_name': authorName,
        'author_emoji': authorEmoji,
        'author_avatar_url': authorAvatarUrl,
        'created_at': createdAt?.toIso8601String(),
        'media': media.map((m) => m.toJson()).toList(),
        'comment_count': commentCount,
      };
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
    this.tmdbRating,
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

  /// TMDB 社区评分（vote_average，0–10），未知为空。
  final double? tmdbRating;

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
        tmdbRating: _parseNumOrNull(j['tmdb_rating']),
        posterUrl: j['poster_url'] as String?,
        aiStatus: j['ai_status'] as String? ?? 'none',
      );
}

/// 片库筛选用的 TMDB 电影类型（id + 本地化名称）。
class MovieGenre {
  const MovieGenre({required this.id, required this.name});

  final int id;
  final String name;

  factory MovieGenre.fromJson(Map<String, dynamic> j) => MovieGenre(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? '',
      );
}

/// 片库（TMDB discover）里的一条结果。还没存进片单，所以用 [tmdbId] 标识。
///
/// [posterUrl] 是 TMDB 图床（或配置的反代）的完整地址，浏览网格直接加载；
/// [alreadyAdded] 表示这部已经在本家庭的片单里，用于显示「已在片单」。
class DiscoverMovie {
  const DiscoverMovie({
    required this.tmdbId,
    required this.title,
    this.overview,
    this.releaseDate,
    this.rating,
    this.posterUrl,
    this.alreadyAdded = false,
  });

  final int tmdbId;
  final String title;
  final String? overview;
  final String? releaseDate;
  final double? rating;
  final String? posterUrl;
  final bool alreadyAdded;

  /// 上映年份（取 "YYYY-MM-DD" 前 4 位），无则空。
  String? get year => (releaseDate != null && releaseDate!.length >= 4)
      ? releaseDate!.substring(0, 4)
      : null;

  DiscoverMovie copyWith({bool? alreadyAdded}) => DiscoverMovie(
        tmdbId: tmdbId,
        title: title,
        overview: overview,
        releaseDate: releaseDate,
        rating: rating,
        posterUrl: posterUrl,
        alreadyAdded: alreadyAdded ?? this.alreadyAdded,
      );

  factory DiscoverMovie.fromJson(Map<String, dynamic> j) => DiscoverMovie(
        tmdbId: (j['tmdb_id'] as num).toInt(),
        title: j['title'] as String? ?? '',
        overview: j['overview'] as String?,
        releaseDate: j['release_date'] as String?,
        rating: _parseNumOrNull(j['tmdb_rating']),
        posterUrl: j['poster_url'] as String?,
        alreadyAdded: j['already_added'] as bool? ?? false,
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

/// 到期管家 —— 一项会到期的东西（证件 / 年检 / 保险 / 合同 …）。
class ExpiryItem {
  const ExpiryItem({
    required this.id,
    required this.familyId,
    required this.name,
    required this.emoji,
    required this.kind,
    required this.expireOn,
    this.note,
    this.notifyEnabled = true,
    this.notifyDaysBefore = 30,
    this.active = true,
    this.daysUntil = 0,
    this.createdAt,
    this.createdBy,
  });

  final String id;
  final String familyId;
  final String name;
  final String emoji;

  /// 类型代码：id_card / passport / visa / driver_license / vehicle_inspection /
  /// insurance / contract / membership / household / other。
  final String kind;

  /// 到期日期。
  final DateTime expireOn;
  final String? note;
  final bool notifyEnabled;

  /// 提前几天提醒（0 = 当天）。
  final int notifyDaysBefore;

  /// 是否启用；停用的项目不提醒、也不在首页卡片体现。
  final bool active;

  /// 距 [expireOn] 还有几天（负数=已过期）。
  final int daysUntil;
  final DateTime? createdAt;
  final String? createdBy;

  factory ExpiryItem.fromJson(Map<String, dynamic> j) => ExpiryItem(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        emoji: j['emoji'] as String? ?? '📄',
        kind: j['kind'] as String? ?? 'other',
        expireOn: _parseDateOnly(j['expire_on']) ?? DateTime.now(),
        note: j['note'] as String?,
        notifyEnabled: j['notify_enabled'] as bool? ?? true,
        notifyDaysBefore: (j['notify_days_before'] as num?)?.toInt() ?? 30,
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
    this.photoUrls = const [],
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

  /// 首图相对地址（时间线缩略；已含 /api/v1,带 ?v=)。
  final String? photoUrl;

  /// 全部照片的相对地址(详情可逐张展示)。
  final List<String> photoUrls;

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
        photoUrls: ((j['photo_urls'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// 植物日记 —— 家庭级默认环境（定位）+ 全家共享的摆放位置候选标签。
class PlantFamilySettings {
  const PlantFamilySettings({
    this.latitude,
    this.longitude,
    this.locationLabel,
    this.placements = const [],
  });

  final double? latitude;
  final double? longitude;
  final String? locationLabel;

  /// 摆放位置候选标签（全家共享）。后端在未自定义时回退到默认预设,所以非空。
  final List<String> placements;

  bool get hasLocation => latitude != null && longitude != null;

  factory PlantFamilySettings.fromJson(Map<String, dynamic> j) =>
      PlantFamilySettings(
        latitude: _parseNumOrNull(j['latitude']),
        longitude: _parseNumOrNull(j['longitude']),
        locationLabel: j['location_label'] as String?,
        placements: ((j['placements'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// 植物日记 —— 当前位置天气(和风 weather/now 全字段)。用于主页天气卡片。
class PlantWeather {
  const PlantWeather({
    this.available = false,
    this.reason,
    this.locationLabel,
    this.latitude,
    this.longitude,
    this.tempC,
    this.feelsLikeC,
    this.condition,
    this.icon,
    this.humidityPct,
    this.precipMm,
    this.pressureHpa,
    this.visibilityKm,
    this.cloudPct,
    this.dewPointC,
    this.windDir,
    this.windScale,
    this.windSpeedKmh,
    this.windDeg,
    this.uvIndex,
    this.observedAt,
  });

  /// 为 false 时 [reason] 说明原因(未设位置 / 未配置 / 获取失败),其余字段为空。
  final bool available;
  final String? reason;
  final String? locationLabel;
  final double? latitude;
  final double? longitude;

  final double? tempC;
  final double? feelsLikeC;
  final String? condition;
  final String? icon;
  final int? humidityPct;
  final double? precipMm;
  final double? pressureHpa;
  final double? visibilityKm;
  final int? cloudPct;
  final double? dewPointC;
  final String? windDir;
  final String? windScale;
  final double? windSpeedKmh;
  final double? windDeg;
  final double? uvIndex;
  final String? observedAt;

  factory PlantWeather.fromJson(Map<String, dynamic> j) => PlantWeather(
        available: j['available'] as bool? ?? false,
        reason: j['reason'] as String?,
        locationLabel: j['location_label'] as String?,
        latitude: _parseNumOrNull(j['latitude']),
        longitude: _parseNumOrNull(j['longitude']),
        tempC: _parseNumOrNull(j['temp_c']),
        feelsLikeC: _parseNumOrNull(j['feels_like_c']),
        condition: j['condition'] as String?,
        icon: j['icon'] as String?,
        humidityPct: (j['humidity_pct'] as num?)?.toInt(),
        precipMm: _parseNumOrNull(j['precip_mm']),
        pressureHpa: _parseNumOrNull(j['pressure_hpa']),
        visibilityKm: _parseNumOrNull(j['visibility_km']),
        cloudPct: (j['cloud_pct'] as num?)?.toInt(),
        dewPointC: _parseNumOrNull(j['dew_point_c']),
        windDir: j['wind_dir'] as String?,
        windScale: j['wind_scale'] as String?,
        windSpeedKmh: _parseNumOrNull(j['wind_speed_kmh']),
        windDeg: _parseNumOrNull(j['wind_deg']),
        uvIndex: _parseNumOrNull(j['uv_index']),
        observedAt: j['observed_at'] as String?,
      );
}

/// ── 退休倒计时插件 ──────────────────────────────────────────────────────────

/// 一个家庭资产账户（存款 deposit / 公积金 fund），可带每月固定收入与入账日。
class RetireAccount {
  const RetireAccount({
    required this.id,
    required this.familyId,
    required this.name,
    required this.kind,
    required this.emoji,
    required this.balance,
    this.monthlyIncome = 0,
    this.incomeDay = 1,
    this.createdAt,
    this.createdBy,
    this.creatorName,
    this.creatorEmoji,
    this.creatorAvatarUrl,
  });

  final String id;
  final String familyId;
  final String name;

  /// deposit（存款）/ fund（公积金）。
  final String kind;
  final String emoji;
  final double balance;

  /// 每月固定收入（0 = 无）；到 [incomeDay] 自动入账。
  final double monthlyIncome;

  /// 每月入账日（1-28）。
  final int incomeDay;
  final DateTime? createdAt;
  final String? createdBy;
  final String? creatorName;
  final String? creatorEmoji;
  final String? creatorAvatarUrl;

  bool get isDeposit => kind == 'deposit';
  bool get isFund => kind == 'fund';

  factory RetireAccount.fromJson(Map<String, dynamic> j) => RetireAccount(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        kind: j['kind'] as String? ?? 'deposit',
        emoji: j['emoji'] as String? ?? '🏦',
        balance: _parseNum(j['balance']),
        monthlyIncome: _parseNum(j['monthly_income']),
        incomeDay: (j['income_day'] as num?)?.toInt() ?? 1,
        createdAt: _parseDate(j['created_at']),
        createdBy: j['created_by'] as String?,
        creatorName: j['creator_name'] as String?,
        creatorEmoji: j['creator_emoji'] as String?,
        creatorAvatarUrl: j['creator_avatar_url'] as String?,
      );
}

/// 一笔家庭负债（房贷 mortgage / 车贷 car / 其他 other），定时从关联存款账户扣款。
class RetireDebt {
  const RetireDebt({
    required this.id,
    required this.familyId,
    required this.name,
    required this.kind,
    required this.emoji,
    required this.balance,
    required this.monthlyPayment,
    this.paymentDay = 1,
    this.fromAccountId,
    this.active = true,
    this.createdAt,
    this.createdBy,
    this.creatorName,
    this.creatorEmoji,
    this.creatorAvatarUrl,
  });

  final String id;
  final String familyId;
  final String name;

  /// mortgage（房贷）/ car（车贷）/ other（其他）。
  final String kind;
  final String emoji;

  /// 剩余欠款；每月 [paymentDay] 按 [monthlyPayment] 递减。
  final double balance;
  final double monthlyPayment;
  final int paymentDay;

  /// 从哪个存款账户扣款（null = 只记负债、不动账户）。
  final String? fromAccountId;
  final bool active;
  final DateTime? createdAt;
  final String? createdBy;
  final String? creatorName;
  final String? creatorEmoji;
  final String? creatorAvatarUrl;

  factory RetireDebt.fromJson(Map<String, dynamic> j) => RetireDebt(
        id: j['id'] as String,
        familyId: j['family_id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        kind: j['kind'] as String? ?? 'mortgage',
        emoji: j['emoji'] as String? ?? '🏠',
        balance: _parseNum(j['balance']),
        monthlyPayment: _parseNum(j['monthly_payment']),
        paymentDay: (j['payment_day'] as num?)?.toInt() ?? 1,
        fromAccountId: j['from_account_id'] as String?,
        active: j['active'] as bool? ?? true,
        createdAt: _parseDate(j['created_at']),
        createdBy: j['created_by'] as String?,
        creatorName: j['creator_name'] as String?,
        creatorEmoji: j['creator_emoji'] as String?,
        creatorAvatarUrl: j['creator_avatar_url'] as String?,
      );
}

/// 退休计划：退休日期、存款目标，以及两个计算口径配置项。
class RetirePlan {
  const RetirePlan({
    this.retireDate,
    this.savingsGoal,
    this.goalBasis = 'net_worth',
    this.surplusBasis = 'income_debt_expense',
  });

  final DateTime? retireDate;
  final double? savingsGoal;

  /// 目标进度口径：net_worth / total_assets / deposit_only。
  final String goalBasis;

  /// 月结余口径：income_debt_expense / income_debt / income_only。
  final String surplusBasis;

  factory RetirePlan.fromJson(Map<String, dynamic> j) => RetirePlan(
        retireDate: _parseDateOnly(j['retire_date']),
        savingsGoal: _parseNumOrNull(j['savings_goal']),
        goalBasis: j['goal_basis'] as String? ?? 'net_worth',
        surplusBasis: j['surplus_basis'] as String? ?? 'income_debt_expense',
      );
}

/// 退休总览（后端算好的资产/负债汇总 + 需求 6/7 的测算结果）。
class RetireDashboard {
  const RetireDashboard({
    required this.totalDeposit,
    required this.totalFund,
    required this.totalAssets,
    required this.totalDebt,
    required this.netWorth,
    required this.current,
    required this.monthlyIncome,
    required this.monthlyDebt,
    required this.monthlyExpense,
    required this.monthlySurplus,
    this.retireDate,
    this.savingsGoal,
    this.goalBasis = 'net_worth',
    this.surplusBasis = 'income_debt_expense',
    this.daysToRetire,
    this.monthsToRetire,
    this.goalReached = false,
    this.remaining,
    this.monthsToGoal,
    this.requiredMonthly,
    this.monthlyGap,
    this.accountingInstalled = false,
  });

  final double totalDeposit;
  final double totalFund;
  final double totalAssets;
  final double totalDebt;
  final double netWorth;

  /// 与目标比较的「现在已有」数（按 goalBasis 取值）。
  final double current;

  final double monthlyIncome;
  final double monthlyDebt;
  final double monthlyExpense;
  final double monthlySurplus;

  final DateTime? retireDate;
  final double? savingsGoal;
  final String goalBasis;
  final String surplusBasis;
  final int? daysToRetire;
  final int? monthsToRetire;
  final bool goalReached;
  final double? remaining;

  /// 需求 6：按当前结余还需几个月到目标；null = 当前结余无法达成。
  final int? monthsToGoal;

  /// 需求 7：要在退休日达标，每月所需净结余。
  final double? requiredMonthly;

  /// 需求 7：monthlySurplus − requiredMonthly。>0 盈余（+¥ 红）；<0 需提高（−¥ 绿）。
  final double? monthlyGap;
  final bool accountingInstalled;

  factory RetireDashboard.fromJson(Map<String, dynamic> j) => RetireDashboard(
        totalDeposit: _parseNum(j['total_deposit']),
        totalFund: _parseNum(j['total_fund']),
        totalAssets: _parseNum(j['total_assets']),
        totalDebt: _parseNum(j['total_debt']),
        netWorth: _parseNum(j['net_worth']),
        current: _parseNum(j['current']),
        monthlyIncome: _parseNum(j['monthly_income']),
        monthlyDebt: _parseNum(j['monthly_debt']),
        monthlyExpense: _parseNum(j['monthly_expense']),
        monthlySurplus: _parseNum(j['monthly_surplus']),
        retireDate: _parseDateOnly(j['retire_date']),
        savingsGoal: _parseNumOrNull(j['savings_goal']),
        goalBasis: j['goal_basis'] as String? ?? 'net_worth',
        surplusBasis: j['surplus_basis'] as String? ?? 'income_debt_expense',
        daysToRetire: (j['days_to_retire'] as num?)?.toInt(),
        monthsToRetire: (j['months_to_retire'] as num?)?.toInt(),
        goalReached: j['goal_reached'] as bool? ?? false,
        remaining: _parseNumOrNull(j['remaining']),
        monthsToGoal: (j['months_to_goal'] as num?)?.toInt(),
        requiredMonthly: _parseNumOrNull(j['required_monthly']),
        monthlyGap: _parseNumOrNull(j['monthly_gap']),
        accountingInstalled: j['accounting_installed'] as bool? ?? false,
      );
}

/// 一条自动事件流水（入账 income / 还款 debt_payment / 月结算 expense_settle）。
class RetireLedgerEntry {
  const RetireLedgerEntry({
    required this.id,
    required this.kind,
    required this.amount,
    required this.period,
    this.accountId,
    this.debtId,
    this.note,
    this.createdAt,
  });

  final String id;

  /// income / debt_payment / expense_settle。
  final String kind;
  final double amount;

  /// 所属月份 "YYYY-MM"。
  final String period;
  final String? accountId;
  final String? debtId;
  final String? note;
  final DateTime? createdAt;

  factory RetireLedgerEntry.fromJson(Map<String, dynamic> j) =>
      RetireLedgerEntry(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? '',
        amount: _parseNum(j['amount']),
        period: j['period'] as String? ?? '',
        accountId: j['account_id'] as String?,
        debtId: j['debt_id'] as String?,
        note: j['note'] as String?,
        createdAt: _parseDate(j['created_at']),
      );
}

/// 「AI 集成设置」里一个能力类型(多模态/文本/图片生成/视频生成)的配置。
///
/// API Key 永不下发明文,只有 [hasKey] + [keyHint](末 4 位)。[callable] 表示后端
/// 当前是否真的会调用这类(多模态/文本=true;图片/视频生成暂为占位)。
class AiModelConfig {
  const AiModelConfig({
    required this.aiType,
    required this.typeLabel,
    required this.callable,
    required this.configured,
    this.label,
    this.baseUrl,
    this.model,
    this.hasKey = false,
    this.keyHint = '',
    this.enabled = false,
    this.updatedAt,
  });

  final String aiType; // multimodal | text | image | video
  final String typeLabel; // 中文名
  final bool callable;
  final bool configured;
  final String? label;
  final String? baseUrl;
  final String? model;
  final bool hasKey;
  final String keyHint;
  final bool enabled;
  final DateTime? updatedAt;

  factory AiModelConfig.fromJson(Map<String, dynamic> j) => AiModelConfig(
        aiType: j['ai_type'] as String,
        typeLabel: j['type_label'] as String? ?? '',
        callable: j['callable'] as bool? ?? false,
        configured: j['configured'] as bool? ?? false,
        label: j['label'] as String?,
        baseUrl: j['base_url'] as String?,
        model: j['model'] as String?,
        hasKey: j['has_key'] as bool? ?? false,
        keyHint: j['key_hint'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? false,
        updatedAt: _parseDate(j['updated_at']),
      );
}

/// 「旅行」插件:钉在地图上的一段旅行(一座城市 + 可选具体地点 + 一张图)。
///
/// 用户传一张照片,后台用默认提示词(+具体地点)图生图、好了**替换**成生成图(原图不留)。
/// [imageUrl] 是这条记录的当前展示图(生成前是原图,生成后是 AI 图);[aiStatus] 表示
/// 后台生成进度:generating / ready / failed。URL 为 host 相对地址,展示时前缀 baseUrl + 鉴权头。
class TravelTrip {
  const TravelTrip({
    required this.id,
    required this.cityName,
    required this.cityLng,
    required this.cityLat,
    this.place,
    this.caption,
    required this.imageUrl,
    required this.aiStatus,
    this.createdAt,
    this.memoryId,
    this.memory,
  });

  final String id;
  final String cityName;
  final double cityLng;
  final double cityLat;
  final String? place;
  final String? caption;
  final String imageUrl;
  final String aiStatus; // generating | ready | failed
  final DateTime? createdAt;

  /// 1 对 1 关联的回忆 id(后端只在当前查看者可见该回忆时才返回;否则为 null)。
  final String? memoryId;

  /// 关联回忆的轻量摘要(标题 + 封面 + 日期),供「看图」页直接渲染关联卡。
  final LinkedMemory? memory;

  bool get isGenerating => aiStatus == 'generating';
  bool get isFailed => aiStatus == 'failed';

  factory TravelTrip.fromJson(Map<String, dynamic> j) => TravelTrip(
        id: j['id'] as String,
        cityName: j['city_name'] as String? ?? '',
        cityLng: (j['city_lng'] as num?)?.toDouble() ?? 0,
        cityLat: (j['city_lat'] as num?)?.toDouble() ?? 0,
        place: j['place'] as String?,
        caption: j['caption'] as String?,
        imageUrl: j['image_url'] as String? ?? '',
        aiStatus: j['ai_status'] as String? ?? 'ready',
        createdAt: _parseDate(j['created_at']),
        memoryId: j['memory_id'] as String?,
        memory: j['memory'] == null
            ? null
            : LinkedMemory.fromJson(j['memory'] as Map<String, dynamic>),
      );
}

/// 旅行所关联回忆的轻量摘要(后端 TripRead.memory)。仅用于在「看图」页展示
/// 关联卡(封面 + 标题 + 日期)并跳转;完整回忆通过 `api.memory(id)` 再拉。
class LinkedMemory {
  const LinkedMemory({
    required this.id,
    required this.title,
    this.eventDate,
    this.coverUrl,
  });

  final String id;
  final String title;
  final DateTime? eventDate;
  final String? coverUrl; // host 相对地址,展示时前缀 baseUrl + 鉴权头

  factory LinkedMemory.fromJson(Map<String, dynamic> j) => LinkedMemory(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        eventDate: _parseDate(j['event_date']),
        coverUrl: j['cover_url'] as String?,
      );
}

/// 一座城市 / 区县(来自 bundle 的 china_cities.json / china_districts.json),
/// 用于地图标注与添加记录的地点选择。`region` 为所属上级(如区县所属地级市),
/// 仅用于搜索结果里的消歧展示——同名区县很多(如「鼓楼区」分属多市)。
class TravelCity {
  const TravelCity({
    required this.name,
    required this.lng,
    required this.lat,
    this.region,
  });

  final String name;
  final double lng;
  final double lat;
  final String? region;

  factory TravelCity.fromJson(Map<String, dynamic> j) => TravelCity(
        name: j['name'] as String? ?? '',
        lng: (j['lng'] as num?)?.toDouble() ?? 0,
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        region: j['region'] as String?,
      );
}
