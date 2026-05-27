import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';

/// 通知偏好：总推送开关 + 各来源（家庭动态 / 有通知机制的插件）单独开关。
///
/// 这些开关只控制「是否推送到手机系统通知栏」；站内「消息」中心始终记录全部通知。
class NotificationPrefsPage extends StatefulWidget {
  const NotificationPrefsPage({super.key});

  @override
  State<NotificationPrefsPage> createState() => _NotificationPrefsPageState();
}

class _NotificationPrefsPageState extends State<NotificationPrefsPage> {
  NotificationPreferences? _prefs;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final prefs = await WoScope.api(context).notificationPreferences();
      if (mounted) setState(() => _prefs = prefs);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<void> _setPushEnabled(bool value) async {
    final prev = _prefs;
    if (prev == null) return;
    // 乐观更新：只改这一个开关，其它开关与总开关保持原样、不禁用。
    setState(() {
      _prefs = NotificationPreferences(pushEnabled: value, sources: prev.sources);
    });
    await _commit(
      () => WoScope.api(context)
          .updateNotificationPreferences(pushEnabled: value),
      rollback: () => _prefs = prev,
    );
  }

  Future<void> _setSource(NotificationSource source, bool value) async {
    final prev = _prefs;
    if (prev == null) return;
    setState(() {
      _prefs = NotificationPreferences(
        pushEnabled: prev.pushEnabled,
        sources: [
          for (final s in prev.sources)
            s.key == source.key ? s.copyWith(enabled: value) : s,
        ],
      );
    });
    await _commit(
      () => WoScope.api(context)
          .updateNotificationPreferences(sources: {source.key: value}),
      // 只回滚这一个来源，避免影响期间用户切换的其它开关。
      rollback: () {
        final cur = _prefs;
        if (cur == null) return;
        _prefs = NotificationPreferences(
          pushEnabled: cur.pushEnabled,
          sources: [
            for (final s in cur.sources)
              s.key == source.key ? s.copyWith(enabled: !value) : s,
          ],
        );
      },
    );
  }

  /// 后台提交这一次改动。成功不动本地状态（乐观值已与所发请求一致，无需重渲染，
  /// 也不会闪烁或覆盖期间的其它切换）；失败才回滚并提示。
  Future<void> _commit(
    Future<NotificationPreferences> Function() action, {
    required VoidCallback rollback,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(rollback);
      final msg = switch (e) {
        ApiException ex => ex.message,
        NetworkException ex => ex.message,
        _ => '保存失败，请稍后再试',
      };
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('通知偏好')),
      body: SafeArea(
        top: false,
        child: Builder(
          builder: (context) {
            if (_loadError != null) {
              return _ErrorRetry(onRetry: _load);
            }
            final prefs = _prefs;
            if (prefs == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              children: [
                const SizedBox(height: WoTokens.space2),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: const Text('推送到手机通知'),
                  subtitle: const Text('关闭后将不再收到系统通知栏推送'),
                  value: prefs.pushEnabled,
                  onChanged: _setPushEnabled,
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    WoTokens.space5,
                    WoTokens.space4,
                    WoTokens.space5,
                    WoTokens.space2,
                  ),
                  child: Text(
                    '按来源',
                    style: t.bodySmall?.copyWith(color: wo.fgMid),
                  ),
                ),
                for (final s in prefs.sources)
                  SwitchListTile(
                    secondary: Text(s.emoji, style: const TextStyle(fontSize: 22)),
                    title: Text(s.label),
                    // 总开关关掉时，各来源开关一并失效（变灰）。
                    value: prefs.pushEnabled && s.enabled,
                    onChanged:
                        prefs.pushEnabled ? (v) => _setSource(s, v) : null,
                  ),
                Padding(
                  padding: const EdgeInsets.all(WoTokens.space5),
                  child: Text(
                    '关闭某项后，相关通知仍会出现在「消息」里，只是不再推送到系统通知栏。',
                    style: t.bodySmall?.copyWith(color: wo.fgMid),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '请检查网络后重试。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
            ),
            const SizedBox(height: WoTokens.space4),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
