import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
                  Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: wo.bgElev,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      user.avatarEmoji,
                      style: const TextStyle(fontSize: 32),
                    ),
                  ),
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
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('关于「窝」'),
                    trailing: Icon(Icons.chevron_right),
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
