import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import 'stock_item_edit_page.dart';

/// 「囤货」tab：家庭囤货列表，可加减数量、低量告急、一键补进采买。
class StockItemsView extends StatefulWidget {
  const StockItemsView({super.key});

  @override
  State<StockItemsView> createState() => _StockItemsViewState();
}

class _StockItemsViewState extends State<StockItemsView> {
  // `_future` 只驱动首屏 spinner;拉到的数据缓存进 `_items`,之后的增删改只
  // 静默后台拉取并就地替换,不再把整列换成 spinner——否则每次操作整页会闪一下。
  late Future<List<StockItem>> _future;
  List<StockItem>? _items;
  bool _loaded = false;
  bool _lowOnly = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<StockItem>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <StockItem>[])
        : session.api.stockItems(familyId);
  }

  void _store(List<StockItem> list) {
    if (mounted) setState(() => _items = list);
  }

  /// 首屏加载失败后的重试:清空数据,回到 spinner 重新拉。
  Future<void> _retry() {
    setState(() {
      _items = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  /// 增删改后刷新:保留当前列表,后台静默拉取后就地替换,不闪 spinner。
  Future<void> _refreshSilently() async {
    try {
      final list = await _fetch();
      if (mounted) setState(() => _items = list);
    } catch (_) {
      // 拉取失败就继续显示旧数据,不打断操作。
    }
    // 列表变化会影响首页卡片预览,刷新一次 bootstrap。
    if (mounted) await WoScope.of(context).refresh();
  }

  Future<void> _openEditor([StockItem? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => StockItemEditPage(existing: existing)),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _bump(StockItem it, int delta) async {
    final next = it.qty + delta;
    if (next < 0) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.updateStockItem(
        familyId,
        it.id,
        name: it.name,
        emoji: it.emoji,
        qty: next,
        unit: it.unit,
        lowAt: it.lowAt,
        note: it.note,
      );
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _addToBuy(StockItem it) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.stockItemToBuy(familyId, it.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已把「${it.name}」加进采买清单')),
        );
      }
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _delete(StockItem it) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除囤货'),
        content: Text('确定删除「${it.name}」吗？'),
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cached = _items;
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
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
    final items = _lowOnly ? all.where((i) => i.isLow).toList() : all;
    final lowCount = all.where((i) => i.isLow).length;
    return Column(
      children: [
        if (lowCount > 0)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: WoTokens.space4,
              vertical: WoTokens.space2,
            ),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: !_lowOnly,
                  onSelected: (_) => setState(() => _lowOnly = false),
                ),
                const SizedBox(width: WoTokens.space2),
                ChoiceChip(
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
                    item: items[i],
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
  const _StockTile({
    required this.item,
    required this.onInc,
    required this.onDec,
    required this.onAddToBuy,
    required this.onEdit,
    required this.onDelete,
  });

  final StockItem item;
  final VoidCallback onInc;
  final VoidCallback onDec;
  final VoidCallback onAddToBuy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final qtyText = item.unit != null && item.unit!.isNotEmpty
        ? '${item.qty} ${item.unit}'
        : '${item.qty}';
    return WoCard(
      onTap: onEdit,
      child: Row(
        children: [
          Text(item.emoji, style: const TextStyle(fontSize: 26)),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Text(
                      '剩 $qtyText',
                      style: t.labelMedium?.copyWith(color: wo.fgMid),
                    ),
                    if (item.isLow) ...[
                      const SizedBox(width: WoTokens.space2),
                      Text(
                        '告急',
                        style: t.labelSmall?.copyWith(
                          color: wo.warning,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          // 快速加减库存。
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.remove_circle_outline, color: wo.fgDim),
            onPressed: item.qty > 0 ? onDec : null,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.add_circle_outline, color: wo.stock),
            onPressed: onInc,
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: wo.fgDim),
            onSelected: (v) {
              if (v == 'buy') onAddToBuy();
              if (v == 'edit') onEdit();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'buy', child: Text('补进采买')),
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
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
            const Text('📦', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有囤货', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把家里常备的日用品记下来，数量见底自动提醒。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('加第一样囤货')),
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
