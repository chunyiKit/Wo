import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/async_view.dart';
import '../../widgets/placeholder_screen.dart';
import '../../widgets/wo_card.dart';

/// 消息中心：GET /notifications。点一条标记已读，可一键全部已读。
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  late Future<List<WoNotification>> _future;
  WoSession? _session;

  @override
  void initState() {
    super.initState();
    _future = WoScope.api(context).notifications();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 订阅刷新信号：点「消息」Tab / App 恢复前台 / 收到推送时会触发重拉。
    final session = WoScope.of(context);
    if (!identical(session, _session)) {
      _session?.messagesRefreshSignal.removeListener(_onRefreshSignal);
      _session = session;
      session.messagesRefreshSignal.addListener(_onRefreshSignal);
    }
  }

  void _onRefreshSignal() {
    if (mounted) _reload();
  }

  @override
  void dispose() {
    _session?.messagesRefreshSignal.removeListener(_onRefreshSignal);
    super.dispose();
  }

  Future<void> _reload() async {
    final session = WoScope.of(context);
    setState(() => _future = session.api.notifications());
    await _future;
    // 通知数可能变化，刷新角标。
    await session.refresh();
  }

  Future<void> _markRead(WoNotification n) async {
    if (n.isRead) return;
    final session = WoScope.of(context);
    try {
      await session.api.markNotificationRead(n.id);
      await _reload();
    } catch (_) {/* 标记失败不阻断浏览 */}
  }

  Future<void> _markAll() async {
    final session = WoScope.of(context);
    try {
      await session.api.markAllNotificationsRead();
      await _reload();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: [
          TextButton(onPressed: _markAll, child: const Text('全部已读')),
        ],
      ),
      body: SafeArea(
        top: false,
        child: AsyncView<List<WoNotification>>(
          future: _future,
          onRetry: _reload,
          builder: (context, items) {
            if (items.isEmpty) {
              return const PlaceholderScreen(
                emoji: '💬',
                title: '消息中心',
                description: '家庭成员动态、插件通知、邀请消息都会在这里出现。',
              );
            }
            return RefreshIndicator(
              onRefresh: _reload,
              child: ListView.separated(
                padding: const EdgeInsets.all(WoTokens.space5),
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: WoTokens.space3),
                itemBuilder: (_, i) => _tile(context, items[i]),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, WoNotification n) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return WoCard(
      color: n.isRead ? null : wo.accentSoft,
      onTap: () => _markRead(n),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(n.iconEmoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(n.title, style: t.titleMedium)),
                    if (!n.isRead)
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(left: 6, top: 6),
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
                if (n.body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(n.body, style: t.bodyMedium?.copyWith(color: wo.fgMid)),
                ],
                if (n.createdAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _ago(n.createdAt!),
                    style: t.bodySmall?.copyWith(color: wo.fgDim),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _ago(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
