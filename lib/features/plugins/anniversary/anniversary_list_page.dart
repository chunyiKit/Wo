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
  late Future<List<Anniversary>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    _future = familyId == null
        ? Future.value(const <Anniversary>[])
        : session.api.anniversaries(familyId);
  }

  Future<void> _openEditor([Anniversary? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AnniversaryEditPage(existing: existing),
      ),
    );
    if (changed == true && mounted) {
      setState(_reload);
      // 列表变化会影响首页卡片预览，刷新一次 bootstrap。
      await WoScope.of(context).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('纪念日')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: AsyncView<List<Anniversary>>(
          future: _future,
          onRetry: () => setState(_reload),
          builder: (context, items) {
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
              separatorBuilder: (_, __) =>
                  const SizedBox(height: WoTokens.space3),
              itemBuilder: (_, i) => _AnniversaryTile(
                item: sorted[i],
                onTap: () => _openEditor(sorted[i]),
              ),
            );
          },
        ),
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
