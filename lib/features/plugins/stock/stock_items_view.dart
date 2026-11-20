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
import 'stock_item_edit_page.dart';

/// 「囤货」tab：家庭囤货列表，可加减数量、低量告急、一键补进采买。
class StockItemsView extends StatefulWidget {
  const StockItemsView({super.key});

  @override
  State<StockItemsView> createState() => _StockItemsViewState();
}

class _StockItemsViewState extends State<StockItemsView> with StockLocalRefresh<StockItemsView> {
  // `_future` 只驱动首屏 spinner;拉到的数据缓存进 `_items`,之后的增删改只
  // 静默后台拉取并就地替换,不再把整列换成 spinner——否则每次操作整页会闪一下。
  late Future<List<StockItem>> _future;
  List<StockItem>? _items;
  bool _loaded = false;
  String? _familyId;
  int _fetchTicket = 0;
  bool _refreshing = false, _refreshAgain = false, _refreshHome = false;
  final _busyIds = <String>{};
  bool _lowOnly = false;

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

  Future<List<StockItem>> _initialFetch() {
    final ticket = ++_fetchTicket;
    final family = _familyId;
    return _fetch().then((list) {
      if (mounted && ticket == _fetchTicket && family == _familyId) setState(() => _items = list);
      return list;
    });
  }

  Future<List<StockItem>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <StockItem>[])
        : session.api.stockItems(familyId);
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

  Future<void> _openEditor([StockItem? existing, bool stocktake = false]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => StockItemEditPage(existing: existing, stocktake: stocktake)),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _bump(StockItem it, int delta) async {
    if (_busyIds.contains(it.id) || it.quantityConflict || it.qty + delta < 0) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    setState(() => _busyIds.add(it.id));
    final clientId = const Uuid().v4();
    try {
      if (session.api.isLocal) {
        await session.api.adjustLocalStockItem(familyId, it.id, deltaQty: delta, clientId: clientId);
      } else {
        await session.api.updateStockItem(familyId, it.id, name: it.name, emoji: it.emoji,
          qty: it.qty + delta, unit: it.unit, lowAt: it.lowAt, note: it.note);
      }
      await _refreshSilently();
    } catch (e) {
      if (mounted) { _toast(e); await _refreshSilently(); }
    } finally { if (mounted) setState(() => _busyIds.remove(it.id)); }
  }

  Future<void> _addToBuy(StockItem it) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.stockItemToBuy(familyId, it.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(WoSnackBar(content: Text('已把「${it.name}」加进采买清单')));
      }
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _delete(StockItem it) async {
    final confirmed = await showWoDialog<bool>(
      context: context,
      builder: (ctx) => WoAlertDialog(
        title: const Text('删除囤货'),
        content: Text('确定删除「${it.name}」吗？'),
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
      await session.api.deleteStockItem(familyId, it.id);
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

  @override
  Widget build(BuildContext context) {
    final cached = _items;
    return WoScaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: WoFloatingActionButton.extended(
        heroTag: 'stock-add-item',
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('加囤货'),
      ),
      // 有缓存数据就直接渲染列表(刷新时就地替换、不闪);仅首屏走 AsyncView 转圈。
      body: cached != null
          ? _buildBody(context, cached)
          : AsyncView<List<StockItem>>(
              future: _future,
              onRetry: _retry,
              builder: _buildBody,
            ),
    );
  }

  Widget _buildBody(BuildContext context, List<StockItem> all) {
    if (all.isEmpty) return _EmptyStock(onAdd: _openEditor);
    final items = _lowOnly ? all.where((i) => i.isLow || i.quantityConflict).toList() : all;
    final conflictCount = all.where((i) => i.quantityConflict).length;
    final lowCount = all.where((i) => i.isLow).length;
    return Column(
      children: [
        if (conflictCount > 0)
          Padding(padding: const EdgeInsets.all(WoTokens.space3), child: Text(
            '$conflictCount 项库存需要盘点，常规加减已暂停。请核对实际数量。',
            style: TextStyle(color: context.wo.warning))),
        if (lowCount > 0)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WoTokens.space4,
              vertical: WoTokens.space2,
            ),
            child: Row(
              children: [
                WoChoiceChip(
                  label: const Text('全部'),
                  selected: !_lowOnly,
                  onSelected: (_) => setState(() => _lowOnly = false),
                ),
                const SizedBox(width: WoTokens.space2),
                WoChoiceChip(
                  label: Text('告急 $lowCount'),
                  selected: _lowOnly,
                  onSelected: (_) => setState(() => _lowOnly = true),
                ),
              ],
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? const _EmptyFilter(text: '没有告急的囤货 ✨')
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
                  itemBuilder: (_, i) => _StockTile(
                    key: ValueKey(items[i].id),
                    item: items[i], busy: _busyIds.contains(items[i].id),
                    onStocktake: WoScope.api(context).isLocal ? () => _openEditor(items[i], true) : null,
                    onInc: () => _bump(items[i], 1),
                    onDec: () => _bump(items[i], -1),
                    onAddToBuy: () => _addToBuy(items[i]),
                    onEdit: () => _openEditor(items[i]),
                    onDelete: () => _delete(items[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _StockTile extends StatelessWidget {
  const _StockTile({super.key, required this.item, required this.onInc,
    required this.onDec, required this.onAddToBuy, required this.onEdit,
    required this.onDelete, this.busy = false, this.onStocktake});
  final StockItem item;
  final bool busy;
  final VoidCallback onInc, onDec, onAddToBuy, onEdit, onDelete;
  final VoidCallback? onStocktake;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final qtyText = item.unit != null && item.unit!.isNotEmpty ? '${item.qty} ${item.unit}' : '${item.qty}';
    return WoCard(onTap: busy ? null : onEdit, child: Row(children: [
      Text(item.emoji, style: const TextStyle(fontSize: 26)),
      const SizedBox(width: WoTokens.space3),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(item.name, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 3),
        Text(item.quantityConflict ? '需盘点 · 账面 ${item.rawQty} ${item.unit ?? ''}' : '剩 $qtyText',
          style: t.labelMedium?.copyWith(color: item.quantityConflict ? wo.warning : wo.fgMid)),
        if (item.isLow && !item.quantityConflict) Text('告急', style: t.labelSmall?.copyWith(color: wo.warning, fontWeight: FontWeight.w700)),
        if (item.quantityConflict) ...[
          Text(item.quantityConflicts.isEmpty ? '合并后数量超出有效范围' : '${item.quantityConflicts.length} 条数量记录需核对',
            style: t.labelSmall?.copyWith(color: wo.warning)),
          if (onStocktake != null) WoTextButton(onPressed: busy ? null : onStocktake, child: const Text('盘点实际数量')),
        ],
        if (item.createdBy != null) ...[
          const SizedBox(height: 4),
          Row(children: [MemberAvatar(url: item.creatorAvatarUrl, emoji: item.creatorEmoji ?? '👤', size: 16),
            const SizedBox(width: 4), Expanded(child: Text(item.creatorName ?? '家庭成员', maxLines: 1,
              overflow: TextOverflow.ellipsis, style: t.labelSmall?.copyWith(color: wo.fgDim)))]),
        ],
      ])),
      WoIconButton(visualDensity: VisualDensity.compact, icon: Icon(Icons.remove_circle_outline, color: wo.fgDim),
        onPressed: !busy && !item.quantityConflict && item.qty > 0 ? onDec : null),
      WoIconButton(visualDensity: VisualDensity.compact, icon: Icon(Icons.add_circle_outline, color: wo.stock),
        onPressed: !busy && !item.quantityConflict ? onInc : null),
      PopupMenuButton<String>(enabled: !busy, icon: Icon(Icons.more_vert, color: wo.fgDim),
        onSelected: (value) {
          if (value == 'buy') onAddToBuy();
          if (value == 'edit') onEdit();
          if (value == 'stocktake') onStocktake?.call();
          if (value == 'delete') onDelete();
        }, itemBuilder: (_) => [
          const PopupMenuItem(value: 'buy', child: Text('补进采买')),
          const PopupMenuItem(value: 'edit', child: Text('编辑')),
          if (onStocktake != null) const PopupMenuItem(value: 'stocktake', child: Text('盘点实际数量')),
          const PopupMenuItem(value: 'delete', child: Text('删除')),
        ]),
    ]));
  }
}

class _EmptyStock extends StatelessWidget {
  const _EmptyStock({required this.onAdd});
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
            const WoEmptyMark(icon: Icons.inventory_2_outlined),
            const SizedBox(height: WoTokens.space4),
            Text('还没有囤货', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把家里常备的日用品记下来，数量见底自动提醒。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            WoFilledButton(onPressed: onAdd, child: const Text('加第一样囤货')),
          ],
        ),
      ),
    );
  }
}

class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space6),
        child: Text(text, style: t.bodyMedium?.copyWith(color: wo.fgMid)),
      ),
    );
  }
}
