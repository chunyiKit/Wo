import 'dart:async';
import 'package:uuid/uuid.dart';
import '../../../widgets/wo_cinema.dart';
import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import '../../../widgets/member_avatar.dart';
import 'stock_local_refresh.dart';
import 'buy_item_edit_page.dart';

/// 「采买」tab：共享待买清单。勾选「买到了」时可顺手入库（关联囤货则累加，
/// 否则新建一个囤货项），形成采买 ↔ 囤货的闭环。
class BuyItemsView extends StatefulWidget {
  const BuyItemsView({super.key});

  @override
  State<BuyItemsView> createState() => _BuyItemsViewState();
}

class _BuyItemsViewState extends State<BuyItemsView> with StockLocalRefresh<BuyItemsView> {
  // `_future` 只驱动首屏 spinner;拉到的数据缓存进 `_items`,之后的增删改只
  // 静默后台拉取并就地替换,不再把整列换成 spinner——否则每次操作整页会闪一下。
  late Future<List<BuyItem>> _future;
  List<BuyItem>? _items;
  bool _loaded = false;
  String? _familyId;
  int _fetchTicket = 0;
  bool _refreshing = false, _refreshAgain = false, _refreshHome = false;
  final _busyIds = <String>{};
  final _requestIds = <String, String>{};

  // null = 全部；false = 待买；true = 已买。默认看待买。
  bool? _bought = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = WoScope.of(context);
    bindStockChanges(session.api.isLocal);
    if (!_loaded || _familyId != session.currentFamilyId) {
      _loaded = true; _familyId = session.currentFamilyId; _items = null;
      _future = _initialFetch();
    }
  }

  @override
  void onStockLocalChanged() { unawaited(_refreshSilently(refreshHome: false)); }

  Future<List<BuyItem>> _initialFetch() {
    final ticket = ++_fetchTicket;
    final family = _familyId;
    return _fetch().then((list) {
      if (mounted && ticket == _fetchTicket && family == _familyId) setState(() => _items = list);
      return list;
    });
  }

  Future<List<BuyItem>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <BuyItem>[])
        : session.api.buyItems(familyId);
  }

  Future<void> _retry() {
    setState(() { _items = null; _future = _initialFetch(); });
    return _future;
  }

  /// 合并通知可连续到达；合并刷新请求并拒绝旧家庭/旧查询覆盖新列表。
  Future<void> _refreshSilently({bool refreshHome = true}) async {
    _refreshHome = _refreshHome || refreshHome;
    if (_refreshing) { _refreshAgain = true; return; }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        if (!mounted) return;
        final ticket = ++_fetchTicket;
        final family = _familyId;
        try {
          final list = await _fetch();
          if (mounted && ticket == _fetchTicket && family == _familyId) setState(() => _items = list);
        } catch (_) { /*保留旧行与滚动位置*/ }
      } while (mounted && _refreshAgain);
      if (mounted && _refreshHome) {
        _refreshHome = false;
        try { await WoScope.of(context).refresh(); } catch (_) { /*列表不因首页刷新失败而清空*/ }
      }
    } finally {
      _refreshing = false;
      if (mounted && _refreshAgain) unawaited(_refreshSilently(refreshHome: false));
    }
  }

  Future<void> _openEditor([BuyItem? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => BuyItemEditPage(existing: existing)),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _toggle(BuyItem buy) async {
    if (_busyIds.contains(buy.id)) return;
    if (buy.receiptConflict) {
      _toast(ApiException('STOCK_QUANTITY_CONFLICT', '收货数量存在冲突，请先在囤货页盘点相关库存'));
      return;
    }
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    setState(() => _busyIds.add(buy.id));
    try {
      if (buy.bought) {
        final key = 'reopen:${buy.id}:${buy.purchaseCycle}';
        await session.api.reopenBuyItem(familyId, buy.id,
          clientId: _requestIds.putIfAbsent(key, () => const Uuid().v4()));
      } else {
        final qty = await _askStockQty(buy);
        if (qty == null || !mounted) return;
        final key = 'receive:${buy.id}:${buy.purchaseCycle}:$qty';
        await session.api.markBuyBought(familyId, buy.id,
          intoStockQty: qty > 0 ? qty : null,
          clientId: _requestIds.putIfAbsent(key, () => const Uuid().v4()));
      }
      await _refreshSilently();
    } catch (error) {
      if (mounted) { _toast(error); await _refreshSilently(); }
    } finally { if (mounted) setState(() => _busyIds.remove(buy.id)); }
  }

  /// 0是用户明确选择只标记；非法输入不能静默变为0。
  Future<int?> _askStockQty(BuyItem buy) async {
    final controller = TextEditingController(text: '1');
    String? error;
    try {
      return await showWoDialog<int>(context: context, builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => WoAlertDialog(
          title: Text('买到「${buy.name}」'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(buy.stockItemId != null ? '要入库多少？会累加到对应囤货。' : '要入库多少？会新建一个囤货项。', style: TextStyle(color: ctx.wo.fgMid)),
            const SizedBox(height: WoTokens.space3),
            WoTextField(controller: controller, autofocus: true, keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: '入库数量', errorText: error)),
          ]),
          actions: [
            WoTextButton(onPressed: () => Navigator.of(ctx).pop(0), child: const Text('只标记买到')),
            WoFilledButton(onPressed: () {
              final count = int.tryParse(controller.text.trim());
              if (count == null || count < 1 || count > 1000000000) { setDialog(() => error = '请输入1至10亿的整数'); return; }
              Navigator.of(ctx).pop(count);
            }, child: const Text('入库')),
          ],
        )));
    } finally { controller.dispose(); }
  }

  Future<void> _delete(BuyItem b) async {
    final confirmed = await showWoDialog<bool>(
      context: context,
      builder: (ctx) => WoAlertDialog(
        title: const Text('删除采买'),
        content: Text('确定删除「${b.name}」吗？${b.bought || b.receiptConflict ? '\n已收货数量及需核对记录会保留，不会撤销入库。' : ''}'),
        actions: [
          WoTextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          WoTextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.deleteBuyItem(familyId, b.id);
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
    ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content: Text(msg)));
  }

  List<BuyItem> _filter(List<BuyItem> all) =>
      _bought == null ? all : all.where((b) => b.receiptConflict || b.bought == _bought).toList();

  @override
  Widget build(BuildContext context) {
    final cached = _items;
    return WoScaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: WoFloatingActionButton.extended(
        heroTag: 'stock-add-buy',
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('加采买'),
      ),
      // 有缓存数据就直接渲染列表(刷新时就地替换、不闪);仅首屏走 AsyncView 转圈。
      body: cached != null
          ? _buildBody(context, cached)
          : AsyncView<List<BuyItem>>(
              future: _future,
              onRetry: _retry,
              builder: _buildBody,
            ),
    );
  }

  Widget _buildBody(BuildContext context, List<BuyItem> all) {
    if (all.isEmpty) return _EmptyBuy(onAdd: _openEditor);
    final items = _filter(all);
    final conflictCount = all.where((b) => b.receiptConflict).length;
    return Column(
      children: [
        if (conflictCount > 0) Padding(padding: const EdgeInsets.all(WoTokens.space3),
          child: Text('$conflictCount 项收货数量需核对（包含已买项目）。请到囤货页盘点，不能重复确认入库。', style: TextStyle(color: context.wo.warning))),
        _FilterBar(
          selected: _bought,
          onSelect: (v) => setState(() => _bought = v),
        ),
        Expanded(
          child: items.isEmpty
              ? const _EmptyFilter()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    WoTokens.space4,
                    WoTokens.space2,
                    WoTokens.space4,
                    100,
                  ),
                  itemCount: items.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: WoTokens.space3),
                  itemBuilder: (_, i) => _BuyTile(
                    key: ValueKey(items[i].id),
                    buy: items[i], busy: _busyIds.contains(items[i].id),
                    onToggle: () => _toggle(items[i]),
                    onEdit: () => _openEditor(items[i]),
                    onDelete: () => _delete(items[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onSelect});

  final bool? selected;
  final ValueChanged<bool?> onSelect;

  @override
  Widget build(BuildContext context) {
    final options = <(bool?, String)>[
      (false, '待买'),
      (true, '已买'),
      (null, '全部'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: WoTokens.space4,
        vertical: WoTokens.space2,
      ),
      child: Row(
        children: [
          for (final (value, label) in options) ...[
            WoChoiceChip(
              label: Text(label),
              selected: value == selected,
              onSelected: (_) => onSelect(value),
            ),
            const SizedBox(width: WoTokens.space2),
          ],
        ],
      ),
    );
  }
}

class _BuyTile extends StatelessWidget {
  const _BuyTile({super.key, required this.buy, required this.onToggle,
    required this.onEdit, required this.onDelete, this.busy = false});
  final BuyItem buy;
  final VoidCallback onToggle, onEdit, onDelete;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final bought = buy.bought;
    return WoCard(onTap: busy ? null : onEdit, child: Row(children: [
      GestureDetector(onTap: !busy && !buy.receiptConflict ? onToggle : null, behavior: HitTestBehavior.opaque,
        child: Icon(buy.receiptConflict ? Icons.warning_amber_rounded : bought ? Icons.check_circle : Icons.radio_button_unchecked,
          color: buy.receiptConflict ? wo.warning : bought ? wo.stock : wo.fgDim, size: 28)),
      const SizedBox(width: WoTokens.space3),
      Text(buy.emoji, style: const TextStyle(fontSize: 24)),
      const SizedBox(width: WoTokens.space3),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(buy.name, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600,
          decoration: bought && !buy.receiptConflict ? TextDecoration.lineThrough : null,
          color: bought && !buy.receiptConflict ? wo.fgDim : wo.fg), maxLines: 1, overflow: TextOverflow.ellipsis),
        if ((buy.wantQty?.isNotEmpty ?? false) || buy.stockItemId != null) ...[
          const SizedBox(height: 3),
          Wrap(spacing: WoTokens.space2, children: [
            if (buy.wantQty?.isNotEmpty ?? false) Text(buy.wantQty!, style: t.labelSmall?.copyWith(color: wo.fgMid)),
            if (buy.stockItemId != null) Text('关联囤货', style: t.labelSmall?.copyWith(color: wo.fgDim)),
          ]),
        ],
        if (buy.receiptConflict) Text('收货数量待核对，请在囤货页盘点相关项目', style: t.labelSmall?.copyWith(color: wo.warning)),
        if (buy.createdBy != null) ...[
          const SizedBox(height: 4),
          Row(children: [MemberAvatar(url: buy.creatorAvatarUrl, emoji: buy.creatorEmoji ?? '👤', size: 16),
            const SizedBox(width: 4), Expanded(child: Text(buy.creatorName ?? '家庭成员', maxLines: 1,
              overflow: TextOverflow.ellipsis, style: t.labelSmall?.copyWith(color: wo.fgDim)))]),
        ],
      ])),
      PopupMenuButton<String>(enabled: !busy, icon: Icon(Icons.more_vert, color: wo.fgDim),
        onSelected: (value) { if (value == 'edit') onEdit(); if (value == 'delete') onDelete(); },
        itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('编辑')), PopupMenuItem(value: 'delete', child: Text('删除'))]),
    ]));
  }
}

class _EmptyBuy extends StatelessWidget {
  const _EmptyBuy({required this.onAdd});
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
            const WoEmptyMark(icon: Icons.shopping_bag_outlined),
            const SizedBox(height: WoTokens.space4),
            Text('采买清单是空的', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '想到要买什么就记一笔，出门照着买；\n囤货见底时也能一键加进来。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            WoFilledButton(onPressed: onAdd, child: const Text('加第一项采买')),
          ],
        ),
      ),
    );
  }
}

class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter();

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space6),
        child: Text('这里空空如也', style: t.bodyMedium?.copyWith(color: wo.fgMid)),
      ),
    );
  }
}
