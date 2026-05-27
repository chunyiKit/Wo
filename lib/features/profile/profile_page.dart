import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/image_pick.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';

/// 我的：当前用户 + 我加入的家庭（来自 bootstrap），支持切换家庭。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _switching = false;
  bool _avatarBusy = false;

  @override
  void initState() {
    super.initState();
    // 直接进入「我的」（深链）而 bootstrap 还没拉时，补一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = WoScope.of(context);
      if (session.user == null && !session.loading) session.load();
    });
  }

  Future<void> _switch(String familyId) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      await WoScope.of(context).switchFamily(familyId);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _editName(WoUser user) async {
    final controller = TextEditingController(text: user.displayName);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) {
        void submit() {
          final v = controller.text.trim();
          if (v.isNotEmpty) Navigator.of(ctx).pop(v);
        }

        return AlertDialog(
          title: const Text('修改昵称'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 24,
            decoration: const InputDecoration(hintText: '昵称'),
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
    if (next == null || next == user.displayName || !mounted) return;

    final session = WoScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await session.api.updateMe(displayName: next);
      await session.refresh();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('保存失败，请稍后再试')));
    }
  }

  Future<void> _editAvatar(WoUser user) async {
    if (_avatarBusy) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.of(ctx).pop('pick'),
            ),
            if (user.hasAvatar)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('移除头像', style: TextStyle(color: Colors.redAccent)),
                onTap: () => Navigator.of(ctx).pop('remove'),
              ),
          ],
        ),
      ),
    );
    if (action == 'pick') {
      await _uploadAvatar();
    } else if (action == 'remove') {
      await _removeAvatar();
    }
  }

  Future<void> _uploadAvatar() async {
    final session = WoScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _avatarBusy = true);
    try {
      final bytes = await pickAndCompressImage(maxEdge: 640);
      if (bytes == null) return; // 用户取消
      await session.api.uploadMyAvatar(bytes: bytes);
      await session.refresh();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('头像上传失败，请稍后再试')));
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _removeAvatar() async {
    final session = WoScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _avatarBusy = true);
    try {
      await session.api.deleteMyAvatar();
      await session.refresh();
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('移除失败，请稍后再试')));
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _logout() async {
    final session = WoScope.of(context);
    final router = GoRouter.of(context);
    await session.logout();
    router.go(WoRoutes.login);
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final session = WoScope.of(context);
    final user = session.user;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('我的')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final families = session.families;
    final currentId = session.currentFamilyId;

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(WoTokens.space5),
          children: [
            WoCard(
              color: wo.accentSoft,
              padding: const EdgeInsets.all(WoTokens.space6),
              child: Row(
                children: [
                  _avatar(context, user),
                  const SizedBox(width: WoTokens.space4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.displayName, style: t.titleLarge),
                        Text(
                          'ID · ${user.username}',
                          style: t.bodySmall?.copyWith(color: wo.fgMid),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: '修改昵称',
                    onPressed: () => _editName(user),
                  ),
                ],
              ),
            ),
            const SizedBox(height: WoTokens.space5),
            Text('我加入的家庭', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            if (families.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: WoTokens.space3),
                child: Text(
                  '还没有加入任何家庭',
                  style: t.bodyMedium?.copyWith(color: wo.fgMid),
                ),
              )
            else
              for (final f in families)
                _family(context, f, current: f.id == currentId),
            const SizedBox(height: WoTokens.space2),
            TextButton(
              onPressed: () => context.push(WoRoutes.joinLanding),
              child: const Text('+ 加入或创建新家'),
            ),
            const SizedBox(height: WoTokens.space5),
            WoCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('设置'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(WoRoutes.settings),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  const ListTile(
                    leading: Icon(Icons.help_outline),
                    title: Text('帮助与反馈'),
                    trailing: Icon(Icons.chevron_right),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('关于「窝」'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push(WoRoutes.about),
                  ),
                ],
              ),
            ),
            const SizedBox(height: WoTokens.space5),
            Center(
              child: TextButton(
                onPressed: _logout,
                style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                child: const Text('退出登录'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _avatar(BuildContext context, WoUser user) {
    final wo = context.wo;
    final api = WoScope.api(context);

    Widget content;
    final url = api.userAvatarUrl(user);
    if (url != null) {
      content = CachedNetworkImage(
        imageUrl: url,
        httpHeaders: api.imageHeaders,
        fit: BoxFit.cover,
        width: 64,
        height: 64,
        // 完整 URL（含 ?v=）即缓存键，无需自定义 cacheKey。
        placeholder: (_, __) => _emojiAvatar(user, wo.bgElev),
        errorWidget: (_, __, ___) => _emojiAvatar(user, wo.bgElev),
      );
    } else {
      content = _emojiAvatar(user, wo.bgElev);
    }

    return GestureDetector(
      onTap: _avatarBusy ? null : () => _editAvatar(user),
      child: Stack(
        children: [
          ClipOval(child: SizedBox(width: 64, height: 64, child: content)),
          if (_avatarBusy)
            Positioned.fill(
              child: ClipOval(
                child: ColoredBox(
                  color: Colors.black26,
                  child: const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: wo.accent,
                shape: BoxShape.circle,
                border: Border.all(color: wo.bgElev, width: 1.5),
              ),
              child: const Icon(Icons.camera_alt, size: 12, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emojiAvatar(WoUser user, Color bg) {
    return Container(
      width: 64,
      height: 64,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(user.avatarEmoji, style: const TextStyle(fontSize: 32)),
    );
  }

  Widget _family(BuildContext context, Family f, {required bool current}) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: WoTokens.space2),
      child: WoCard(
        color: current ? wo.accentSoft : null,
        padding: const EdgeInsets.symmetric(
          horizontal: WoTokens.space4,
          vertical: WoTokens.space3,
        ),
        child: Row(
          children: [
            Text(f.emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: WoTokens.space3),
            Expanded(
              child: Text(
                f.name,
                style: t.titleMedium?.copyWith(
                  color: current ? wo.accentDeep : wo.fg,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (current)
              Icon(Icons.check_circle, color: wo.accent)
            else
              TextButton(
                onPressed: _switching ? null : () => _switch(f.id),
                child: const Text('切换'),
              ),
          ],
        ),
      ),
    );
  }
}
