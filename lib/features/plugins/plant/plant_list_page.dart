import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import 'plant_detail_page.dart';
import 'plant_location.dart';

/// 植物日记首页:植物网格 + 右下角新增 + 右上角默认环境(定位)设置。
class PlantListPage extends StatefulWidget {
  const PlantListPage({super.key});

  @override
  State<PlantListPage> createState() => _PlantListPageState();
}

class _PlantListPageState extends State<PlantListPage> {
  // `_future` 只驱动首屏 spinner;数据缓存进 `_items`,之后的增删改静默就地替换,
  // 不再把整页换成 spinner——见 CLAUDE.md「列表页刷新不能闪一下」。
  late Future<List<Plant>> _future;
  List<Plant>? _items;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<Plant>> _fetch() {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    return fid == null ? Future.value(<Plant>[]) : session.api.plants(fid);
  }

  void _store(List<Plant> list) {
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
  }

  Future<void> _openCreateSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _PlantEditSheet(),
    );
    if (created == true) await _refreshSilently();
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _PlantSettingsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(
        title: const Text('植物日记'),
        actions: [
          IconButton(
            tooltip: '默认环境',
            onPressed: _openSettings,
            icon: const Icon(Icons.place_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: _items != null
            ? _buildGrid(context, _items!)
            : AsyncView<List<Plant>>(
                future: _future,
                onRetry: _retry,
                builder: _buildGrid,
              ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCreateSheet,
        backgroundColor: wo.plant,
        foregroundColor: wo.fg,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, List<Plant> plants) {
    if (plants.isEmpty) {
      return _EmptyState(onAdd: _openCreateSheet);
    }
    return GridView.builder(
      padding: const EdgeInsets.all(WoTokens.space4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: WoTokens.space4,
        crossAxisSpacing: WoTokens.space4,
        childAspectRatio: 0.82,
      ),
      itemCount: plants.length,
      itemBuilder: (_, i) => _PlantCard(
        plant: plants[i],
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlantDetailPage(plantId: plants[i].id),
            ),
          );
          await _refreshSilently(); // 详情页可能改了周期 / 加了记录,回来刷新。
        },
      ),
    );
  }
}

class _PlantCard extends StatelessWidget {
  const _PlantCard({required this.plant, required this.onTap});

  final Plant plant;
  final VoidCallback onTap;

  String? _careHint() {
    final now = DateTime.now();
    DateTime? soonest;
    String kind = '';
    for (final e in [
      (plant.nextWaterDue, '浇水'),
      (plant.nextFertDue, '施肥'),
    ]) {
      final d = e.$1;
      if (d == null) continue;
      if (soonest == null || d.isBefore(soonest)) {
        soonest = d;
        kind = e.$2;
      }
    }
    if (soonest == null) return null;
    final days =
        soonest.difference(DateTime(now.year, now.month, now.day)).inDays;
    if (days < 0) return '$kind已逾期';
    if (days == 0) return '今天$kind';
    return '$days 天后$kind';
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final api = WoScope.api(context);
    final hint = _careHint();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: wo.bgElev,
          borderRadius: BorderRadius.circular(WoTokens.cardRadius),
          boxShadow: WoTokens.cardShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: plant.coverUrl != null && plant.coverUrl!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: '${api.baseUrl}${plant.coverUrl!}',
                      httpHeaders: api.imageHeaders,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(color: wo.plant),
                      errorWidget: (_, __, ___) => Container(
                        color: wo.plant,
                        alignment: Alignment.center,
                        child: Text(
                          plant.emoji,
                          style: const TextStyle(fontSize: 36),
                        ),
                      ),
                    )
                  : Container(
                      color: wo.plant,
                      alignment: Alignment.center,
                      child: Text(
                        plant.emoji,
                        style: const TextStyle(fontSize: 36),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(WoTokens.space3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    plant.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.titleSmall?.copyWith(color: wo.fg),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hint ?? plant.placement,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(
                      color: hint != null && hint.contains('逾期')
                          ? wo.danger
                          : wo.fgMid,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🌿', style: TextStyle(fontSize: 48)),
          const SizedBox(height: WoTokens.space3),
          Text('还没有植物', style: t.titleMedium?.copyWith(color: wo.fg)),
          const SizedBox(height: WoTokens.space2),
          Text(
            '给家里的植物拍张照,建个档案吧',
            style: t.bodySmall?.copyWith(color: wo.fgMid),
          ),
          const SizedBox(height: WoTokens.space4),
          FilledButton(onPressed: onAdd, child: const Text('添加一株')),
        ],
      ),
    );
  }
}

/// 新建植物表单。
class _PlantEditSheet extends StatefulWidget {
  const _PlantEditSheet();

  @override
  State<_PlantEditSheet> createState() => _PlantEditSheetState();
}

class _PlantEditSheetState extends State<_PlantEditSheet> {
  final _name = TextEditingController();
  final _species = TextEditingController();
  String _placement = '室内';
  bool _saving = false;

  static const _placements = ['室内', '阳台', '朝南窗', '朝北窗', '室外'];

  @override
  void dispose() {
    _name.dispose();
    _species.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    try {
      if (fid != null) {
        await session.api.createPlant(
          fid,
          name: name,
          species: _species.text.trim(),
          placement: _placement,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败:$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        WoTokens.space5,
        WoTokens.space5,
        WoTokens.space5,
        insets.bottom + WoTokens.space5,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '添加植物',
            style:
                Theme.of(context).textTheme.titleLarge?.copyWith(color: wo.fg),
          ),
          const SizedBox(height: WoTokens.space4),
          TextField(
            controller: _name,
            decoration:
                const InputDecoration(labelText: '名称', hintText: '如:绿萝'),
          ),
          const SizedBox(height: WoTokens.space3),
          TextField(
            controller: _species,
            decoration: const InputDecoration(
              labelText: '品种(可选)',
              hintText: '不填的话 AI 会帮你认',
            ),
          ),
          const SizedBox(height: WoTokens.space4),
          Text(
            '摆放位置',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: wo.fgMid),
          ),
          const SizedBox(height: WoTokens.space2),
          Wrap(
            spacing: WoTokens.space2,
            children: [
              for (final p in _placements)
                ChoiceChip(
                  label: Text(p),
                  selected: _placement == p,
                  onSelected: (_) => setState(() => _placement = p),
                ),
            ],
          ),
          const SizedBox(height: WoTokens.space5),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }
}

/// 默认环境(定位)设置表单。
class _PlantSettingsSheet extends StatefulWidget {
  const _PlantSettingsSheet();

  @override
  State<_PlantSettingsSheet> createState() => _PlantSettingsSheetState();
}

class _PlantSettingsSheetState extends State<_PlantSettingsSheet> {
  PlantFamilySettings? _settings;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final s = await session.api.plantSettings(fid);
      if (mounted) {
        setState(() {
          _settings = s;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _useDeviceLocation() async {
    setState(() => _busy = true);
    final loc = await getCurrentLocation();
    if (!loc.ok) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(loc.error!)));
      }
      return;
    }
    if (!mounted) return;
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    try {
      final s = await session.api.updatePlantSettings(
        fid!,
        latitude: loc.latitude,
        longitude: loc.longitude,
      );
      if (mounted) {
        setState(() {
          _settings = s;
          _busy = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已更新默认位置')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败:$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final insets = MediaQuery.of(context).viewInsets;
    final s = _settings;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        WoTokens.space5,
        WoTokens.space5,
        WoTokens.space5,
        insets.bottom + WoTokens.space5,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('默认环境', style: t.titleLarge?.copyWith(color: wo.fg)),
          const SizedBox(height: WoTokens.space2),
          Text(
            '用于按当地天气分析植物状态。家里植物默认共用这个位置。',
            style: t.bodySmall?.copyWith(color: wo.fgMid),
          ),
          const SizedBox(height: WoTokens.space4),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(WoTokens.space4),
                child: CircularProgressIndicator(),
              ),
            )
          else
            Text(
              s != null && s.hasLocation
                  ? '当前位置:${s.locationLabel ?? '${s.latitude!.toStringAsFixed(3)}, ${s.longitude!.toStringAsFixed(3)}'}'
                  : '尚未设置位置',
              style: t.bodyMedium?.copyWith(color: wo.fg),
            ),
          const SizedBox(height: WoTokens.space4),
          FilledButton.icon(
            onPressed: _busy ? null : _useDeviceLocation,
            icon: const Icon(Icons.my_location),
            label: Text(_busy ? '定位中…' : '使用当前定位'),
          ),
        ],
      ),
    );
  }
}
