import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/wo_card.dart';
import 'account_edit_page.dart';
import 'retirement_common.dart';

/// 「资产」tab：家庭账户（存款 / 公积金）列表，带月固定收入与入账日。
class AccountsView extends StatefulWidget {
  const AccountsView({super.key, required this.onChanged});

  /// 列表变化后通知父级（让「总览」重算）。
  final VoidCallback onChanged;

  @override
  State<AccountsView> createState() => _AccountsViewState();
}

class _AccountsViewState extends State<AccountsView> {
  late Future<List<RetireAccount>> _future;
  List<RetireAccount>? _items;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<RetireAccount>> _fetch() {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    return fid == null
        ? Future.value(const <RetireAccount>[])
        : session.api.retireAccounts(fid);
  }

  void _store(List<RetireAccount> list) {
    if (mounted) setState(() => _items = list);
  }

  Future<void> _retry() {
    setState(() {
      _items = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  Future<void> _refreshSilently() async {
    try {
      final list = await _fetch();
      if (mounted) setState(() => _items = list);
    } catch (_) {
      // 拉取失败保留旧数据。
    }
    widget.onChanged();
    if (mounted) await WoScope.of(context).refresh();
  }

  Future<void> _openEditor([RetireAccount? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AccountEditPage(existing: existing)),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _delete(RetireAccount a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账户'),
        content: Text('确定删除「${a.name}」吗？关联它的负债会解除关联。'),
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
    if (confirmed != true || !mounted) return;
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;
    try {
      await session.api.deleteRetireAccount(fid, a.id);
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
    }
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
    final cached = _items;
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'retire-add-account',
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('加账户'),
      ),
      body: cached != null
          ? _buildBody(context, cached)
          : AsyncView<List<RetireAccount>>(
              future: _future,
              onRetry: _retry,
              builder: _buildBody,
            ),
    );
  }

  Widget _buildBody(BuildContext context, List<RetireAccount> all) {
    if (all.isEmpty) return _Empty(onAdd: _openEditor);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        WoTokens.space4,
        WoTokens.space3,
        WoTokens.space4,
        100,
      ),
      itemCount: all.length,
      separatorBuilder: (_, __) => const SizedBox(height: WoTokens.space3),
      itemBuilder: (_, i) => _AccountTile(
        account: all[i],
        onEdit: () => _openEditor(all[i]),
        onDelete: () => _delete(all[i]),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.onEdit,
    required this.onDelete,
  });

  final RetireAccount account;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final hasIncome = account.monthlyIncome > 0;
    return WoCard(
      onTap: onEdit,
      child: Row(
        children: [
          Text(account.emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        account.name,
                        style:
                            t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: WoTokens.space2),
                    _Chip(text: accountKindLabel(account.kind)),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  hasIncome
                      ? '余额 ${yuan(account.balance)} · 月入 ${yuan(account.monthlyIncome)}（${account.incomeDay} 号）'
                      : '余额 ${yuan(account.balance)}',
                  style: t.labelMedium?.copyWith(color: wo.fgMid),
                ),
              ],
            ),
          ),
          if (account.creatorName != null || account.creatorEmoji != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: MemberAvatar(
                url: account.creatorAvatarUrl,
                emoji: account.creatorEmoji ?? '👤',
                size: 22,
              ),
            ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: wo.fgDim),
            onSelected: (v) {
              if (v == 'edit') onEdit();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: wo.retire.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: t.labelSmall?.copyWith(color: wo.fg)),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;

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
            const Text('🏦', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有账户', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把家里的存款、公积金记下来，再设上每月固定收入。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('加第一个账户')),
          ],
        ),
      ),
    );
  }
}
