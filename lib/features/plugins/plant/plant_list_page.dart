import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import 'plant_detail_page.dart';
import 'plant_edit_sheet.dart';
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
  // 改变它来让天气卡片重拉(如设完默认位置/名称返回)。
  int _weatherToken = 0;

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
      builder: (_) => const PlantEditSheet(),
    );
    if (created == true) await _refreshSilently();
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _PlantSettingsSheet(),
    );
    // 位置/名称可能变了,让天气卡片重拉。
    if (mounted) setState(() => _weatherToken++);
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
        child: Column(
          children: [
            _WeatherCard(key: ValueKey(_weatherToken)),
            Expanded(
              child: _items != null
                  ? _buildGrid(context, _items!)
                  : AsyncView<List<Plant>>(
                      future: _future,
                      onRetry: _retry,
                      builder: _buildGrid,
                    ),
            ),
          ],
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

/// 默认环境(定位)设置表单。
class _PlantSettingsSheet extends StatefulWidget {
  const _PlantSettingsSheet();

  @override
  State<_PlantSettingsSheet> createState() => _PlantSettingsSheetState();
}

class _PlantSettingsSheetState extends State<_PlantSettingsSheet> {
  PlantFamilySettings? _settings;
  final _label = TextEditingController();
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
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
          _label.text = s.locationLabel ?? '';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveLabel() async {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;
    FocusScope.of(context).unfocus();
    try {
      final s = await session.api.updatePlantSettings(
        fid,
        locationLabel: _label.text.trim(),
      );
      if (mounted) {
        setState(() => _settings = s);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已保存位置名称')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败:$e')));
      }
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
          else if (s != null && s.hasLocation) ...[
            // 已定位:醒目地显示状态 + 名称(若有)+ 经纬度,确保「位置信息」可见。
            Row(
              children: [
                Icon(Icons.check_circle, color: wo.plant, size: 20),
                const SizedBox(width: WoTokens.space2),
                Expanded(
                  child: Text(
                    (s.locationLabel != null && s.locationLabel!.isNotEmpty)
                        ? s.locationLabel!
                        : '已定位',
                    style: t.titleSmall?.copyWith(color: wo.fg),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '经纬度 ${s.latitude!.toStringAsFixed(4)}, ${s.longitude!.toStringAsFixed(4)}',
              style: t.bodySmall?.copyWith(color: wo.fgMid),
            ),
          ] else
            Text(
              '尚未设置位置',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
            ),
          const SizedBox(height: WoTokens.space4),
          FilledButton.icon(
            onPressed: _busy ? null : _useDeviceLocation,
            icon: const Icon(Icons.my_location),
            label: Text(_busy ? '定位中…' : '使用当前定位'),
          ),
          if (s != null && s.hasLocation) ...[
            const SizedBox(height: WoTokens.space4),
            TextField(
              controller: _label,
              decoration: InputDecoration(
                labelText: '位置名称(可选)',
                hintText: '如:家 / 杭州西湖',
                suffixIcon: TextButton(
                  onPressed: _saveLabel,
                  child: const Text('保存'),
                ),
              ),
              onSubmitted: (_) => _saveLabel(),
            ),
          ],
        ],
      ),
    );
  }
}

/// 主页顶部天气卡片:显示当前位置名 + 和风能取到的全部天气字段。
/// 自己拉取(用 [ValueKey] 在位置变化后重建即重拉);不可用时显示原因。
class _WeatherCard extends StatefulWidget {
  const _WeatherCard({super.key});

  @override
  State<_WeatherCard> createState() => _WeatherCardState();
}

class _WeatherCardState extends State<_WeatherCard> {
  Future<PlantWeather>? _future;
  bool _loaded = false;

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
    final fid = session.currentFamilyId;
    setState(() {
      _future = fid == null
          ? Future.value(const PlantWeather(reason: '未加入家庭'))
          : session.api.plantWeather(fid);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        WoTokens.space4,
        WoTokens.space4,
        WoTokens.space4,
        0,
      ),
      padding: const EdgeInsets.all(WoTokens.space4),
      decoration: BoxDecoration(
        color: wo.plant,
        borderRadius: BorderRadius.circular(WoTokens.cardRadius),
      ),
      child: FutureBuilder<PlantWeather>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: WoTokens.space3),
                Text('天气加载中…', style: t.bodyMedium?.copyWith(color: wo.fg)),
              ],
            );
          }
          final w = snap.data;
          if (w == null || !w.available) {
            return Row(
              children: [
                Icon(Icons.cloud_off_outlined, color: wo.fgMid, size: 20),
                const SizedBox(width: WoTokens.space2),
                Expanded(
                  child: Text(
                    w?.reason ?? '天气不可用',
                    style: t.bodyMedium?.copyWith(color: wo.fgMid),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.refresh, color: wo.fgMid),
                  onPressed: _reload,
                ),
              ],
            );
          }
          return _buildWeather(context, w);
        },
      ),
    );
  }

  Widget _buildWeather(BuildContext context, PlantWeather w) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final place = (w.locationLabel != null && w.locationLabel!.isNotEmpty)
        ? w.locationLabel!
        : '当前位置';

    // 全部字段(空的自动跳过)。
    final rows = <(String, String)>[
      if (w.feelsLikeC != null) ('体感', '${w.feelsLikeC!.toStringAsFixed(0)}℃'),
      if (w.humidityPct != null) ('湿度', '${w.humidityPct}%'),
      if (w.precipMm != null) ('降水', '${w.precipMm} mm'),
      if (w.pressureHpa != null)
        ('气压', '${w.pressureHpa!.toStringAsFixed(0)} hPa'),
      if (w.visibilityKm != null)
        ('能见度', '${w.visibilityKm!.toStringAsFixed(0)} km'),
      if (w.cloudPct != null) ('云量', '${w.cloudPct}%'),
      if (w.dewPointC != null) ('露点', '${w.dewPointC!.toStringAsFixed(0)}℃'),
      if (w.windDir != null) ('风向', w.windDir!),
      if (w.windScale != null) ('风力', '${w.windScale} 级'),
      if (w.windSpeedKmh != null)
        ('风速', '${w.windSpeedKmh!.toStringAsFixed(0)} km/h'),
      if (w.windDeg != null) ('风向角', '${w.windDeg!.toStringAsFixed(0)}°'),
      if (w.uvIndex != null) ('紫外线', w.uvIndex!.toStringAsFixed(0)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头部:地点 + 天况 + 大号温度 + 刷新。
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.place, size: 16, color: wo.fgMid),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          place,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.titleSmall?.copyWith(color: wo.fg),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    w.condition ?? '—',
                    style: t.bodyMedium?.copyWith(color: wo.fgMid),
                  ),
                ],
              ),
            ),
            Text(
              w.tempC != null ? '${w.tempC!.toStringAsFixed(0)}℃' : '—',
              style: t.displaySmall?.copyWith(
                color: wo.fg,
                fontWeight: FontWeight.w600,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.refresh, color: wo.fgMid),
              onPressed: _reload,
            ),
          ],
        ),
        if (rows.isNotEmpty) ...[
          const SizedBox(height: WoTokens.space3),
          Wrap(
            spacing: WoTokens.space2,
            runSpacing: WoTokens.space2,
            children: [
              for (final (label, value) in rows)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WoTokens.space3,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: wo.bgElev.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(WoTokens.chipRadius),
                  ),
                  child: Text(
                    '$label $value',
                    style: t.labelMedium?.copyWith(color: wo.fg),
                  ),
                ),
            ],
          ),
        ],
        if (w.observedAt != null) ...[
          const SizedBox(height: WoTokens.space2),
          Text(
            '观测 ${w.observedAt}',
            style: t.labelSmall?.copyWith(color: wo.fgDim),
          ),
        ],
      ],
    );
  }
}
