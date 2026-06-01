import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import 'anniversary_edit_page.dart';

/// 纪念日列表页：展示家庭所有纪念日，可新增、点击进入单条编辑。
class AnniversaryListPage extends StatefulWidget {
  const AnniversaryListPage({super.key});

  @override
  State<AnniversaryListPage> createState() => _AnniversaryListPageState();
}

class _AnniversaryListPageState extends State<AnniversaryListPage> {
  // `_future` 只驱动首屏 spinner;数据缓存进 `_items`,之后的增删改静默就地替换,
  // 不闪——见 CLAUDE.md「列表页刷新不能闪一下」。
  late Future<List<Anniversary>> _future;
  List<Anniversary>? _items;
  bool _loaded = false;

  // 首次加载放在 didChangeDependencies 而非 initState：_fetch 通过
  // WoScope.of(context) 依赖 InheritedWidget，在 initState 阶段访问会抛异常。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<Anniversary>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <Anniversary>[])
        : session.api.anniversaries(familyId);
  }

  void _store(List<Anniversary> list) {
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
      // 拉取失败就继续显示旧数据,不打断操作。
    }
    // 列表变化会影响首页卡片预览,刷新一次 bootstrap。
    if (mounted) await WoScope.of(context).refresh();
  }

  Future<void> _openEditor([Anniversary? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AnniversaryEditPage(existing: existing),
      ),
    );
    if (changed == true) await _refreshSilently();
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final cached = _items;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('纪念日')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: cached != null
            ? _buildBody(context, cached)
            : AsyncView<List<Anniversary>>(
                future: _future,
                onRetry: _retry,
                builder: _buildBody,
              ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<Anniversary> items) {
    if (items.isEmpty) return _Empty(onAdd: () => _openEditor());
    final sorted = [...items]
      ..sort((a, b) => a.daysUntil.compareTo(b.daysUntil));
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        WoTokens.space4,
        WoTokens.space4,
        WoTokens.space4,
        100,
      ),
      itemCount: sorted.length,
      separatorBuilder: (_, __) => const SizedBox(height: WoTokens.space3),
      itemBuilder: (_, i) => _AnniversaryTile(
        item: sorted[i],
        onTap: () => _openEditor(sorted[i]),
      ),
    );
  }
}

class _AnniversaryTile extends StatelessWidget {
  const _AnniversaryTile({required this.item, required this.onTap});

  final Anniversary item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final delta = item.daysUntil;
    final countdown = delta == 0 ? '就是今天 🎉' : '还有 $delta 天';
    final dateText =
        '${item.eventDate.year}.${item.eventDate.month.toString().padLeft(2, '0')}.${item.eventDate.day.toString().padLeft(2, '0')}'
        '${item.isLunar ? ' · 农历' : ''}';

    return WoCard(
      color: wo.anniv,
      onTap: onTap,
      padding: const EdgeInsets.all(WoTokens.space4),
      child: Row(
        children: [
          Text(item.emoji, style: const TextStyle(fontSize: 30)),
          const SizedBox(width: WoTokens.space4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(dateText, style: t.bodySmall?.copyWith(color: wo.fgMid)),
              ],
            ),
          ),
          const SizedBox(width: WoTokens.space3),
          Text(
            countdown,
            style: t.labelLarge?.copyWith(
              color: wo.accentDeep,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: WoTokens.space2),
          Icon(Icons.chevron_right, color: wo.fgDim, size: 20),
        ],
      ),
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
            const Text('🎂', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有纪念日', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '记下结婚日、相识日、宝宝生日……\n首页卡片会自动提醒下一个。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('添加第一个纪念日')),
          ],
        ),
      ),
    );
  }
}
