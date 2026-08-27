import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/pet_avatar.dart';
import '../../../widgets/wo_card.dart';
import '../../family/pet_profile_edit_page.dart';
import 'pet_detail_page.dart';

class PetListPage extends StatefulWidget {
  const PetListPage({super.key});

  @override
  State<PetListPage> createState() => _PetListPageState();
}

class _PetListPageState extends State<PetListPage> {
  late Future<List<PetListItem>> _future;
  List<PetListItem>? _items;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<PetListItem>> _fetch() {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    return fid == null
        ? Future.value(<PetListItem>[])
        : session.api.petDailyPets(fid);
  }

  void _store(List<PetListItem> value) {
    if (mounted) setState(() => _items = value);
  }

  Future<void> _refreshSilently() async {
    try {
      _store(await _fetch());
    } catch (_) {
      // 保留旧列表。
    }
  }

  Future<void> _retry() {
    setState(() {
      _items = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  Future<void> _addPet() async {
    final result = await Navigator.of(
      context,
    ).push<Pet>(MaterialPageRoute(builder: (_) => const PetProfileEditPage()));
    if (result != null) await _refreshSilently();
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return WoScaffold(
      appBar: WoAppBar(title: const Text('宠物日常')),
      body: _items != null
          ? _list(_items!)
          : AsyncView<List<PetListItem>>(
              future: _future,
              onRetry: _retry,
              builder: (_, items) => _list(_items ?? items),
            ),
      floatingActionButton: WoFloatingActionButton.extended(
        onPressed: _addPet,
        backgroundColor: wo.pet,
        foregroundColor: wo.fg,
        icon: const Icon(Icons.add),
        label: const Text('添加宠物'),
      ),
    );
  }

  Widget _list(List<PetListItem> items) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🐾', style: TextStyle(fontSize: 52)),
            const SizedBox(height: WoTokens.space3),
            Text('先添加一位宠物家人', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: WoTokens.space2),
            const Text('建立档案后，就能记录照护、体重与健康时间线。'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refreshSilently,
      child: ListView.builder(
        padding: const EdgeInsets.all(WoTokens.space4),
        itemCount: items.length,
        itemBuilder: (_, index) => _card(items[index]),
      ),
    );
  }

  Widget _card(PetListItem item) {
    final wo = context.wo;
    final api = WoScope.api(context);
    final pet = item.pet;
    final details = [
      pet.breed,
      pet.species,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: WoTokens.space3),
      child: WoCard(
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => PetDetailPage(petId: pet.id)),
          );
          await _refreshSilently();
        },
        padding: const EdgeInsets.all(WoTokens.space4),
        child: Row(
          children: [
            PetAvatar(
              emoji: pet.emoji,
              size: 68,
              placeholderColor: wo.pet,
              url: pet.photoUrl == null
                  ? null
                  : '${api.baseUrl}${pet.photoUrl}',
              headers: api.imageHeaders,
            ),
            const SizedBox(width: WoTokens.space4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pet.name, style: Theme.of(context).textTheme.titleLarge),
                  if (details.isNotEmpty)
                    Text(details, style: TextStyle(color: wo.fgMid)),
                  const SizedBox(height: WoTokens.space2),
                  Text(
                    item.nextPlan == null
                        ? '最近待办 · 暂无'
                        : '最近待办 · ${_due(item.nextPlan!)} ${item.nextPlan!.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.latestWeight != null)
                    Text(
                      '最近体重 · ${item.latestWeight!.weightKg.toStringAsFixed(2)} kg',
                      style: TextStyle(color: wo.fgMid),
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

String _due(PetCarePlan plan) {
  final days = plan.daysUntil;
  if (days == null) return '';
  if (days < 0) return '逾期 ${-days} 天 ·';
  if (days == 0) return '今天 ·';
  return '$days 天后 ·';
}
