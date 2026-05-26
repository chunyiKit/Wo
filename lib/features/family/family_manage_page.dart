import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/async_view.dart';
import '../../widgets/wo_card.dart';

/// 家庭管理：GET /families/{id} + /families/{id}/members。
class FamilyManagePage extends StatefulWidget {
  const FamilyManagePage({super.key});

  @override
  State<FamilyManagePage> createState() => _FamilyManagePageState();
}

class _FamilyManagePageState extends State<FamilyManagePage> {
  Future<(Family, List<Member>)>? _future;
  String? _familyId;

  Future<(Family, List<Member>)> _load(String familyId) async {
    final api = WoScope.api(context);
    final results = await Future.wait([
      api.getFamily(familyId),
      api.members(familyId),
    ]);
    return (results[0] as Family, results[1] as List<Member>);
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final familyId = WoScope.of(context).currentFamilyId;

    if (familyId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('家庭管理')),
        body: Center(
          child: Text('还没有家庭', style: t.titleMedium?.copyWith(color: wo.fgMid)),
        ),
      );
    }

    // 当前家庭变化（切换家庭）时重建 future。
    if (_familyId != familyId) {
      _familyId = familyId;
      _future = _load(familyId);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('家庭管理')),
      body: SafeArea(
        top: false,
        child: AsyncView<(Family, List<Member>)>(
          future: _future!,
          onRetry: () => setState(() => _future = _load(familyId)),
          builder: (context, data) {
            final family = data.$1;
            final members = data.$2;
            final canEdit =
                family.myRole == 'owner' || family.myRole == 'admin';
            return ListView(
              padding: const EdgeInsets.all(WoTokens.space5),
              children: [
                WoCard(
                  color: wo.accentSoft,
                  padding: const EdgeInsets.all(WoTokens.space6),
                  child: Row(
                    children: [
                      Text(family.emoji, style: const TextStyle(fontSize: 40)),
                      const SizedBox(width: WoTokens.space4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(family.name, style: t.titleLarge),
                            Text(
                              [
                                if (family.slogan != null &&
                                    family.slogan!.isNotEmpty)
                                  family.slogan!,
                                if (family.createdAt != null)
                                  '创建于 ${_ymd(family.createdAt!)}',
                              ].join(' · '),
                              style: t.bodySmall?.copyWith(color: wo.fgMid),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: WoTokens.space5),
                Row(
                  children: [
                    Text('成员 · ${family.memberCount}', style: t.titleMedium),
                    const Spacer(),
                    if (family.myRole == 'owner' || family.myRole == 'admin')
                      FilledButton.tonal(
                        onPressed: () => context.push(WoRoutes.familyInvite),
                        child: const Text('+ 邀请'),
                      ),
                  ],
                ),
                const SizedBox(height: WoTokens.space2),
                for (final m in members) _member(context, family, m),
                const SizedBox(height: WoTokens.space5),
                Text('设置', style: t.titleMedium),
                const SizedBox(height: WoTokens.space2),
                WoCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('家庭名称'),
                        subtitle: Text(family.name),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: canEdit ? () => _editName(family) : null,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        title: const Text('家庭标语'),
                        subtitle: Text(
                          (family.slogan == null || family.slogan!.isEmpty)
                              ? '未设置'
                              : family.slogan!,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: canEdit ? () => _editSlogan(family) : null,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        title: const Text('家庭 emoji'),
                        trailing: Text(
                          family.emoji,
                          style: const TextStyle(fontSize: 24),
                        ),
                        onTap: canEdit ? () => _editEmoji(family) : null,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      const ListTile(
                        title: Text('家庭通知'),
                        trailing: Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: WoTokens.space5),
                if (family.myRole != 'owner')
                  TextButton(
                    onPressed: () => _leave(family),
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.redAccent),
                    child: const Text('离开家庭'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  static const _emojiPalette = [
    '🏡', '🌿', '🌸', '☕️', '🐱', '🐶', //
    '🎈', '🌙', '🍊', '🍞', '📚', '🎨',
  ];

  Future<void> _editName(Family family) async {
    final v = await _promptText(
      title: '修改家庭名称',
      initial: family.name,
      maxLength: 16,
      hint: '家庭名称',
      allowEmpty: false,
    );
    if (v == null || v == family.name) return;
    await _save(family, name: v);
  }

  Future<void> _editSlogan(Family family) async {
    final v = await _promptText(
      title: '修改家庭标语',
      initial: family.slogan ?? '',
      maxLength: 24,
      hint: '一句话形容你们的窝',
      allowEmpty: true,
    );
    if (v == null || v == (family.slogan ?? '')) return;
    await _save(family, slogan: v);
  }

  Future<void> _editEmoji(Family family) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final wo = ctx.wo;
        return AlertDialog(
          title: const Text('选择家庭 emoji'),
          content: SizedBox(
            width: double.maxFinite,
            child: GridView.count(
              crossAxisCount: 6,
              shrinkWrap: true,
              mainAxisSpacing: WoTokens.space2,
              crossAxisSpacing: WoTokens.space2,
              children: [
                for (final e in _emojiPalette)
                  GestureDetector(
                    onTap: () => Navigator.of(ctx).pop(e),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: e == family.emoji ? wo.accentSoft : wo.bgTint,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: e == family.emoji
                              ? wo.accent
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 24)),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null || picked == family.emoji) return;
    await _save(family, emoji: picked);
  }

  /// 通用单行文本输入弹窗。取消返回 null；确认返回去空格后的文本（[allowEmpty] 时允许空串）。
  Future<String?> _promptText({
    required String title,
    required String initial,
    required int maxLength,
    required String hint,
    required bool allowEmpty,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        void submit() {
          final v = controller.text.trim();
          if (allowEmpty || v.isNotEmpty) Navigator.of(ctx).pop(v);
        }

        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: maxLength,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: submit, child: const Text('保存')),
          ],
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<void> _leave(Family family) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('离开家庭'),
        content: Text('确定要离开「${family.name}」吗？离开后将看不到这个家的内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('离开'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final session = WoScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await session.api.leaveFamily(family.id);
      await session.refresh(); // 重新拉 bootstrap：当前家庭/家庭列表随之更新
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('已离开「${family.name}」')));
      // 还有其他家庭去首页，否则回到加入/创建入口。
      router.go(
        session.currentFamilyId == null ? WoRoutes.joinLanding : WoRoutes.home,
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(e is ApiException ? e.message : '离开失败')),
        );
      }
    }
  }

  Future<void> _openMemberActions(Family family, Member m) async {
    final isOwner = family.myRole == 'owner';
    final isSelf = WoScope.of(context).user?.id == m.userId;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final t = Theme.of(ctx).textTheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(WoTokens.space4),
                child: Row(
                  children: [
                    Text(m.avatarEmoji, style: const TextStyle(fontSize: 24)),
                    const SizedBox(width: WoTokens.space2),
                    Expanded(child: Text(m.displayName, style: t.titleMedium)),
                  ],
                ),
              ),
              const Divider(height: 1),
              for (final r in _assignableRoles)
                ListTile(
                  title: Text('设为${r.$2}'),
                  trailing:
                      m.role == r.$1 ? const Icon(Icons.check) : null,
                  onTap: m.role == r.$1
                      ? null
                      : () {
                          Navigator.of(ctx).pop();
                          _changeRole(family, m, r.$1);
                        },
                ),
              if (isOwner && !isSelf) ...[
                const Divider(height: 1),
                ListTile(
                  leading: const Text('👑', style: TextStyle(fontSize: 20)),
                  title: const Text('转为主理人'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _transfer(family, m);
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Future<void> _changeRole(Family family, Member m, String role) async {
    final session = WoScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await session.api.updateMemberRole(family.id, m.userId, role);
      await session.refresh();
      if (mounted) setState(() => _future = _load(family.id));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is ApiException ? e.message : '修改失败')),
      );
    }
  }

  Future<void> _transfer(Family family, Member m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转让主理人'),
        content: Text('确定把「${family.name}」的主理人转给${m.displayName}吗？转让后你将变为管理员。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('转让'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final session = WoScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await session.api.transferOwnership(family.id, m.userId);
      await session.refresh();
      if (mounted) {
        setState(() => _future = _load(family.id));
        messenger.showSnackBar(
          SnackBar(content: Text('已把主理人转给${m.displayName}')),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is ApiException ? e.message : '转让失败')),
      );
    }
  }

  Future<void> _save(
    Family family, {
    String? name,
    String? slogan,
    String? emoji,
  }) async {
    if (!mounted) return;
    final session = WoScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await session.api.updateFamily(
        family.id,
        name: name,
        slogan: slogan,
        emoji: emoji,
      );
      await session.refresh(); // 让首页家庭名/emoji/切换器同步更新
      if (mounted) setState(() => _future = _load(family.id));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is ApiException ? e.message : '修改失败')),
      );
    }
  }

  static const _assignableRoles = <(String, String)>[
    ('member', '家人'),
    ('admin', '管理员'),
    ('child', '孩子'),
    ('pet', '宠物'),
  ];

  Widget _member(BuildContext context, Family family, Member m) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final pending = m.status == 'pending';
    // owner/admin 可管理；但不能改主理人那一行（主理人变更走转让）。
    final canManage = family.myRole == 'owner' || family.myRole == 'admin';
    final tappable = canManage && m.role != 'owner';
    return Padding(
      padding: const EdgeInsets.only(bottom: WoTokens.space2),
      child: WoCard(
        onTap: tappable ? () => _openMemberActions(family, m) : null,
        padding: const EdgeInsets.symmetric(
          horizontal: WoTokens.space4,
          vertical: WoTokens.space3,
        ),
        child: Row(
          children: [
            Text(m.avatarEmoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: WoTokens.space3),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      m.displayName,
                      style: t.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (pending) ...[
                    const SizedBox(width: 6),
                    Text(
                      '· 待接受',
                      style: t.bodySmall?.copyWith(color: wo.fgDim),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: WoTokens.space3,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: wo.bgTint,
                borderRadius: BorderRadius.circular(WoTokens.chipRadius),
              ),
              child: Text(_roleLabel(m.role), style: t.labelSmall),
            ),
          ],
        ),
      ),
    );
  }
}

String _roleLabel(String role) => switch (role) {
      'owner' => '主理人 👑',
      'admin' => '管理员',
      'child' => '孩子',
      'pet' => '宠物',
      _ => '家人',
    };

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
