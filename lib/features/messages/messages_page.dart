import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/placeholder_screen.dart';
import '../../widgets/wo_card.dart';

/// 消息中心：GET /notifications。点一条标记已读，可一键全部已读，左滑删除单条。
///
/// 列表数据放在本地可变状态 [_items] 里（而非纯 Future 驱动），这样 [Dismissible]
/// 删除时能同步从数据源移除 —— 否则会触发「dismissed widget 仍在树上」断言。
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  List<WoNotification>? _items; // null = 首次加载未完成
  Object? _error;
  WoSession? _session;

  @override
  void initState() {
    super.initState();
    _firstLoad();
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

  @override
  void dispose() {
    _session?.messagesRefreshSignal.removeListener(_onRefreshSignal);
    super.dispose();
  }

  void _onRefreshSignal() {
    if (mounted) _reload();
  }

  /// 首次加载：失败则进入错误态（带重试）。
  Future<void> _firstLoad() async {
    try {
      final data = await WoScope.api(context).notifications();
      if (mounted) {
        setState(() {
          _items = data;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// 后台刷新：保留当前列表，拉到新数据再替换（不闪 loading）。顺带刷新角标。
  Future<void> _reload() async {
    try {
      final data = await WoScope.api(context).notifications();
      if (mounted) {
        setState(() {
          _items = data;
          _error = null;
        });
      }
    } catch (e) {
      // 已有数据时刷新失败就保留旧列表，不打断浏览；首屏还没数据才显示错误态。
      if (_items == null && mounted) setState(() => _error = e);
    }
    if (mounted) await WoScope.of(context).refresh();
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

  /// 左滑后弹确认；确认且删除成功才返回 true（让 Dismissible 真正移除）。
  Future<bool> _confirmDelete(WoNotification n) async {
    final session = WoScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: const Text('确定删除这条消息吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return false;
    try {
      await session.api.deleteNotification(n.id);
      return true;
    } catch (e) {
      if (mounted) _toast(e);
      return false;
    }
  }

  void _onDeleted(WoNotification n) {
    setState(() => _items?.removeWhere((x) => x.id == n.id));
    // 删掉的可能是未读，刷新角标。
    WoScope.of(context).refresh();
  }

  void _toast(Object error) {
    final msg = switch (error) {
      ApiException e => e.message,
      NetworkException e => e.message,
      _ => '操作失败',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
      body: SafeArea(top: false, child: _body()),
    );
  }

  Widget _body() {
    final items = _items;
    if (items == null) {
      if (_error != null) return _ErrorState(error: _error!, onRetry: _firstLoad);
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          children: const [
            SizedBox(height: 120),
            PlaceholderScreen(
              emoji: '💬',
              title: '消息中心',
              description: '家庭成员动态、插件通知、邀请消息都会在这里出现。',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.all(WoTokens.space5),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: WoTokens.space3),
        itemBuilder: (_, i) => _dismissibleTile(context, items[i]),
      ),
    );
  }

  /// 卡片包一层 Dismissible：从右往左滑（endToStart）露出红色删除背景，松手弹确认。
  Widget _dismissibleTile(BuildContext context, WoNotification n) {
    return Dismissible(
      key: ValueKey(n.id),
      direction: DismissDirection.endToStart,
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: WoTokens.space5),
        decoration: BoxDecoration(
          color: Colors.redAccent,
          borderRadius: BorderRadius.circular(WoTokens.cardRadius),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, color: Colors.white),
            SizedBox(width: 6),
            Text(
              '删除',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
      // 只允许左滑，右滑方向给个空背景避免误触。
      background: const SizedBox.shrink(),
      confirmDismiss: (_) => _confirmDelete(n),
      onDismissed: (_) => _onDeleted(n),
      child: _tile(context, n),
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

/// 加载失败态（😣 + 重试），与 AsyncView 的错误态观感一致。
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final message = switch (error) {
      ApiException e => e.message,
      NetworkException e => e.message,
      _ => error.toString(),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('😣', style: TextStyle(fontSize: 40)),
            const SizedBox(height: WoTokens.space4),
            Text('加载失败', style: t.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: WoTokens.space2),
            Text(
              message,
              style: t.bodySmall?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
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
