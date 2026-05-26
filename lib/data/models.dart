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
  });

  final String id;
  final String username;
  final String displayName;
  final String avatarEmoji;
  final int level;
  final DateTime? createdAt;

  factory WoUser.fromJson(Map<String, dynamic> j) => WoUser(
        id: j['id'] as String,
        username: j['username'] as String? ?? '',
        displayName: j['display_name'] as String? ?? '',
        avatarEmoji: j['avatar_emoji'] as String? ?? '👤',
        level: (j['level'] as num?)?.toInt() ?? 1,
        createdAt: _parseDate(j['created_at']),
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
    this.joinedAt,
    required this.status,
  });

  final String userId;
  final String familyId;
  final String role;
  final String displayName;
  final String avatarEmoji;
  final DateTime? joinedAt;
  final String status; // active | pending

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        userId: j['user_id'] as String,
        familyId: j['family_id'] as String? ?? '',
        role: j['role'] as String? ?? 'member',
        displayName: j['display_name'] as String? ?? '',
        avatarEmoji: j['avatar_emoji'] as String? ?? '👤',
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

  factory PluginPreview.fromJson(Map<String, dynamic> j) => PluginPreview(
        primary: j['primary'] as String? ?? '',
        secondary: j['secondary'] as String?,
        badge: j['badge'] as String?,
        colorToken: j['color_token'] as String? ?? 'accent',
        emoji: j['emoji'] as String?,
        secondaryTone: j['secondary_tone'] as String?,
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

  factory AccountingSummary.fromJson(Map<String, dynamic> j) => AccountingSummary(
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
        createdAt: _parseDate(j['created_at']),
        coverUrl: j['cover_url'] as String?,
        coverVersion: (j['cover_version'] as num?)?.toInt() ?? 0,
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
