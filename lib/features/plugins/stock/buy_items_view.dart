import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import 'buy_item_edit_page.dart';

/// 「采买」tab：共享待买清单。勾选「买到了」时可顺手入库（关联囤货则累加，
/// 否则新建一个囤货项），形成采买 ↔ 囤货的闭环。
class BuyItemsView extends StatefulWidget {
  const BuyItemsView({super.key});

  @override
  State<BuyItemsView> createState() => _BuyItemsViewState();
}

class _BuyItemsViewState extends State<BuyItemsView> {
  late Future<List<BuyItem>> _future;
  bool _loaded = false;

  // null = 全部；false = 待买；true = 已买。默认看待买。
  bool? _bought = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _reload();
    }
  }

  void _reload() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    _future = familyId == null
        ? Future.value(const <BuyItem>[])
        : session.api.buyItems(familyId);
  }

  Future<void> _refreshAll() async {
    if (!mounted) return;
    setState(_reload);
    await WoScope.of(context).refresh();
  }

  Future<void> _openEditor([BuyItem? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => BuyItemEditPage(existing: existing)),
    );
    if (changed == true) await _refreshAll();
  }

  Future<void> _toggle(BuyItem b) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    if (b.bought) {
      try {
        await session.api.reopenBuyItem(familyId, b.id);
        await _refreshAll();
      } catch (e) {
        if (mounted) _toast(e);
      }
      return;
    }
    // 标记买到：先问要不要入库。null = 关掉对话框（取消），0 = 只标记买到。
    final qty = await _askStockQty(b);
    if (qty == null || !mounted) return;
    try {
      await session.api.markBuyBought(
        familyId,
        b.id,
        intoStockQty: qty > 0 ? qty : null,
      );
      await _refreshAll();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  /// 返回入库数量；返回 0 表示只标记买到不入库；返回 null 表示取消。
  Future<int?> _askStockQty(BuyItem b) async {
    final controller = TextEditingController(text: '1');
    final linked = b.stockItemId != null;
    return showDialog<int>(
      context: context,
      builder: (ctx) {
        final wo = ctx.wo;
        return AlertDialog(
          title: Text('买到「${b.name}」'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                linked ? '要入库多少？会累加到对应囤货。' : '要入库多少？会新建一个囤货项。',
                style: TextStyle(color: wo.fgMid),
              ),
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '入库数量'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(0),
              child: const Text('只标记买到'),
            ),
            FilledButton(
              onPressed: () {
                final n = int.tryParse(controller.text.trim()) ?? 0;
                Navigator.of(ctx).pop(n);
              },
              child: const Text('入库'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _delete(BuyItem b) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除采买'),
        content: Text('确定删除「${b.name}」吗？'),
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
      await session.api.deleteBuyItem(familyId, b.id);
      await _refreshAll();
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

  List<BuyItem> _filter(List<BuyItem> all) =>
      _bought == null ? all : all.where((b) => b.bought == _bought).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'stock-add-buy',
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('加采买'),
      ),
      body: AsyncView<List<BuyItem>>(
        future: _future,
        onRetry: () => setState(_reload),
        builder: (context, all) {
          if (all.isEmpty) return _EmptyBuy(onAdd: _openEditor);
          final items = _filter(all);
          return Column(
            children: [
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
                          buy: items[i],
                          onToggle: () => _toggle(items[i]),
                          onEdit: () => _openEditor(items[i]),
                          onDelete: () => _delete(items[i]),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
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
            ChoiceChip(
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
  const _BuyTile({
    required this.buy,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final BuyItem buy;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final bought = buy.bought;
    return WoCard(
      onTap: onEdit,
      child: Row(
        children: [
          GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: Icon(
              bought ? Icons.check_circle : Icons.radio_button_unchecked,
              color: bought ? wo.stock : wo.fgDim,
              size: 28,
            ),
          ),
          const SizedBox(width: WoTokens.space3),
          Text(buy.emoji, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  buy.name,
                  style: t.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    decoration: bought ? TextDecoration.lineThrough : null,
                    color: bought ? wo.fgDim : wo.fg,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if ((buy.wantQty != null && buy.wantQty!.isNotEmpty) ||
                    buy.stockItemId != null) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (buy.wantQty != null && buy.wantQty!.isNotEmpty)
                        Text(
                          buy.wantQty!,
                          style: t.labelSmall?.copyWith(color: wo.fgMid),
                        ),
                      if (buy.stockItemId != null) ...[
                        if (buy.wantQty != null && buy.wantQty!.isNotEmpty)
                          const SizedBox(width: WoTokens.space2),
                        Icon(Icons.link, size: 12, color: wo.fgDim),
                        const SizedBox(width: 2),
                        Text(
                          '关联囤货',
                          style: t.labelSmall?.copyWith(color: wo.fgDim),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
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
            const Text('🛒', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('采买清单是空的', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '想到要买什么就记一笔，出门照着买；\n囤货见底时也能一键加进来。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('加第一项采买')),
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
        child: Text(
          '这里空空如也',
          style: t.bodyMedium?.copyWith(color: wo.fgMid),
        ),
      ),
    );
  }
}
