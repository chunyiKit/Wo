import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../data/image_pick.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';

/// 植物详情:头部(封面 + 周期设置) + 养护时间线。
class PlantDetailPage extends StatefulWidget {
  const PlantDetailPage({super.key, required this.plantId});

  final String plantId;

  @override
  State<PlantDetailPage> createState() => _PlantDetailPageState();
}

class _PlantDetailPageState extends State<PlantDetailPage> {
  // `_future` 只驱动首屏 spinner;数据缓存进 `_data`,之后的刷新(增删改、轮询)
  // 静默就地替换,不闪——见 CLAUDE.md「列表页刷新不能闪一下」。
  late Future<_DetailData> _future;
  _DetailData? _data;
  bool _loaded = false;
  bool _uploading = false;

  Timer? _pollTimer;
  int _pollsLeft = 0;
  static const _maxPolls = 8;
  static const _pollInterval = Duration(seconds: 5);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<_DetailData> _fetch() {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    return fid == null
        ? Future.value(const _DetailData(plant: null, logs: []))
        : _load(fid);
  }

  Future<_DetailData> _load(String fid) async {
    final api = WoScope.of(context).api;
    final plant = await api.plant(fid, widget.plantId);
    final logs = await api.plantLogs(fid, widget.plantId);
    return _DetailData(plant: plant, logs: logs);
  }

  void _store(_DetailData data) {
    if (!mounted) return;
    setState(() => _data = data);
    _maybeSchedulePoll(data.logs);
  }

  Future<void> _retry() {
    setState(() {
      _data = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  /// 刷新:保留当前内容,后台静默拉取后就地替换,不闪 spinner。
  Future<void> _refreshSilently() async {
    try {
      final data = await _fetch();
      _store(data);
    } catch (_) {
      // 拉取失败就继续显示旧数据。
    }
  }

  void _maybeSchedulePoll(List<PlantLog> logs) {
    final anyPending = logs.any((l) => l.aiPending);
    if (anyPending && _pollsLeft == 0) {
      _pollsLeft = _maxPolls;
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(_pollInterval, (timer) {
        if (!mounted || _pollsLeft <= 0) {
          timer.cancel();
          return;
        }
        _pollsLeft--;
        _refreshSilently();
      });
    } else if (!anyPending) {
      _pollsLeft = 0;
      _pollTimer?.cancel();
    }
  }

  Future<void> _addLog() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final bytes = await pickAndCompressImage(source: source);
    if (bytes == null) return;

    final note = await _askNote();
    if (!mounted) return;

    setState(() => _uploading = true);
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    try {
      if (fid != null) {
        await session.api.createPlantLog(
          fid,
          widget.plantId,
          bytes: bytes,
          filename: 'plant.jpg',
          note: note,
        );
      }
      if (mounted) {
        setState(() => _uploading = false);
        await _refreshSilently();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _uploading = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('上传失败:$e')));
      }
    }
  }

  Future<String?> _askNote() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备注(可选)'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '如:今天换了盆 / 叶子有点黄'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('跳过'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _editCycle(Plant plant) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CycleSheet(plant: plant),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _adopt(PlantLog log) async {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;
    try {
      await session.api.adoptPlantSuggestion(
        fid,
        widget.plantId,
        log.id,
        water: log.aiSuggestedWaterDays != null,
        fert: log.aiSuggestedFertDays != null,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已采纳建议周期')));
        await _refreshSilently();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('采纳失败:$e')));
      }
    }
  }

  Future<void> _reanalyze(PlantLog log) async {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;
    try {
      await session.api.reanalyzePlantLog(fid, widget.plantId, log.id);
      if (mounted) await _refreshSilently();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('植物详情')),
      body: SafeArea(
        child: _data != null
            ? _buildContent(context, _data!)
            : AsyncView<_DetailData>(
                future: _future,
                onRetry: _retry,
                builder: _buildContent,
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _addLog,
        backgroundColor: wo.plant,
        foregroundColor: wo.fg,
        icon: _uploading
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_a_photo_outlined),
        label: Text(_uploading ? '上传中' : '记录'),
      ),
    );
  }

  Widget _buildContent(BuildContext context, _DetailData data) {
    final wo = context.wo;
    final plant = data.plant;
    if (plant == null) {
      return const Center(child: Text('植物不存在'));
    }
    return ListView(
      padding: const EdgeInsets.all(WoTokens.space4),
      children: [
        _Header(plant: plant, onEditCycle: () => _editCycle(plant)),
        const SizedBox(height: WoTokens.space5),
        Text(
          '养护记录',
          style:
              Theme.of(context).textTheme.titleMedium?.copyWith(color: wo.fg),
        ),
        const SizedBox(height: WoTokens.space3),
        if (data.logs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: WoTokens.space5),
            child: Center(
              child: Text(
                '还没有记录,拍一张开始吧',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: wo.fgMid),
              ),
            ),
          )
        else
          for (final log in data.logs)
            _LogCard(
              log: log,
              onAdopt: () => _adopt(log),
              onRetry: () => _reanalyze(log),
            ),
      ],
    );
  }
}

class _DetailData {
  const _DetailData({required this.plant, required this.logs});
  final Plant? plant;
  final List<PlantLog> logs;
}

class _Header extends StatelessWidget {
  const _Header({required this.plant, required this.onEditCycle});

  final Plant plant;
  final VoidCallback onEditCycle;

  String _cycleText() {
    final parts = <String>[];
    if (plant.waterIntervalDays != null) {
      parts.add('每 ${plant.waterIntervalDays} 天浇水');
    }
    if (plant.fertIntervalDays != null) {
      parts.add('每 ${plant.fertIntervalDays} 天施肥');
    }
    return parts.isEmpty ? '未设置养护周期' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final api = WoScope.api(context);
    return Container(
      decoration: BoxDecoration(
        color: wo.bgElev,
        borderRadius: BorderRadius.circular(WoTokens.cardRadius),
        boxShadow: WoTokens.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: plant.coverUrl != null && plant.coverUrl!.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: '${api.baseUrl}${plant.coverUrl!}',
                    httpHeaders: api.imageHeaders,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: wo.plant),
                    errorWidget: (_, __, ___) => Container(color: wo.plant),
                  )
                : Container(
                    color: wo.plant,
                    alignment: Alignment.center,
                    child:
                        Text(plant.emoji, style: const TextStyle(fontSize: 48)),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(WoTokens.space4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plant.name, style: t.titleLarge?.copyWith(color: wo.fg)),
                const SizedBox(height: 2),
                Text(
                  '${plant.species ?? '品种待识别'} · ${plant.placement}',
                  style: t.bodySmall?.copyWith(color: wo.fgMid),
                ),
                const SizedBox(height: WoTokens.space3),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _cycleText(),
                        style: t.bodyMedium?.copyWith(color: wo.fg),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: onEditCycle,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('周期'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  const _LogCard({
    required this.log,
    required this.onAdopt,
    required this.onRetry,
  });

  final PlantLog log;
  final VoidCallback onAdopt;
  final VoidCallback onRetry;

  String _dateText() {
    final d = log.createdAt;
    if (d == null) return '';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final api = WoScope.api(context);
    final advice = log.aiAdvice;
    final hasSuggestion =
        log.aiSuggestedWaterDays != null || log.aiSuggestedFertDays != null;

    return Container(
      margin: const EdgeInsets.only(bottom: WoTokens.space3),
      padding: const EdgeInsets.all(WoTokens.space3),
      decoration: BoxDecoration(
        color: wo.bgElev,
        borderRadius: BorderRadius.circular(WoTokens.cardRadius),
        boxShadow: WoTokens.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: log.photoUrl != null && log.photoUrl!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: '${api.baseUrl}${log.photoUrl!}',
                        httpHeaders: api.imageHeaders,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(width: 72, height: 72, color: wo.bgTint),
                        errorWidget: (_, __, ___) =>
                            Container(width: 72, height: 72, color: wo.bgTint),
                      )
                    : Container(width: 72, height: 72, color: wo.bgTint),
              ),
              const SizedBox(width: WoTokens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _dateText(),
                      style: t.bodySmall?.copyWith(color: wo.fgMid),
                    ),
                    const SizedBox(height: 4),
                    if (log.aiPending)
                      Text(
                        'AI 分析中…',
                        style: t.bodySmall?.copyWith(color: wo.fgMid),
                      )
                    else if (log.aiFailed)
                      Row(
                        children: [
                          Text(
                            '分析失败',
                            style: t.bodySmall?.copyWith(color: wo.danger),
                          ),
                          const SizedBox(width: WoTokens.space2),
                          GestureDetector(
                            onTap: onRetry,
                            child: Text(
                              '重试',
                              style: t.bodySmall?.copyWith(
                                color: wo.plant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      )
                    else if (log.aiAssessment != null)
                      Text(
                        log.aiAssessment!,
                        style:
                            t.bodyMedium?.copyWith(color: wo.fg, height: 1.4),
                      ),
                    if (log.note != null && log.note!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '备注:${log.note!}',
                        style: t.bodySmall?.copyWith(color: wo.fgMid),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (advice != null && advice.isNotEmpty) ...[
            const SizedBox(height: WoTokens.space3),
            _AdviceRow(emoji: '💧', label: '浇水', text: advice['watering']),
            _AdviceRow(emoji: '🌱', label: '施肥', text: advice['fertilizing']),
            _AdviceRow(emoji: '✂️', label: '修剪', text: advice['pruning']),
          ],
          if (hasSuggestion) ...[
            const SizedBox(height: WoTokens.space3),
            Container(
              padding: const EdgeInsets.all(WoTokens.space3),
              decoration: BoxDecoration(
                color: wo.plant.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'AI 建议:'
                      '${log.aiSuggestedWaterDays != null ? '每 ${log.aiSuggestedWaterDays} 天浇水 ' : ''}'
                      '${log.aiSuggestedFertDays != null ? '每 ${log.aiSuggestedFertDays} 天施肥' : ''}',
                      style: t.bodySmall?.copyWith(color: wo.fg),
                    ),
                  ),
                  TextButton(onPressed: onAdopt, child: const Text('采纳')),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AdviceRow extends StatelessWidget {
  const _AdviceRow({
    required this.emoji,
    required this.label,
    required this.text,
  });

  final String emoji;
  final String label;
  final Object? text;

  @override
  Widget build(BuildContext context) {
    final s = text?.toString();
    if (s == null || s.isEmpty) return const SizedBox.shrink();
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji),
          const SizedBox(width: WoTokens.space2),
          Expanded(
            child: Text(
              s,
              style: t.bodySmall?.copyWith(color: wo.fgMid, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// 浇水/施肥周期设置表单。
class _CycleSheet extends StatefulWidget {
  const _CycleSheet({required this.plant});

  final Plant plant;

  @override
  State<_CycleSheet> createState() => _CycleSheetState();
}

class _CycleSheetState extends State<_CycleSheet> {
  late final TextEditingController _water = TextEditingController(
    text: widget.plant.waterIntervalDays?.toString() ?? '',
  );
  late final TextEditingController _fert = TextEditingController(
    text: widget.plant.fertIntervalDays?.toString() ?? '',
  );
  bool _saving = false;

  @override
  void dispose() {
    _water.dispose();
    _fert.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    final water = int.tryParse(_water.text.trim());
    final fert = int.tryParse(_fert.text.trim());
    try {
      if (fid != null) {
        await session.api.updatePlant(
          fid,
          widget.plant.id,
          waterIntervalDays: water,
          fertIntervalDays: fert,
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
    final t = Theme.of(context).textTheme;
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
          Text('养护周期', style: t.titleLarge?.copyWith(color: wo.fg)),
          const SizedBox(height: WoTokens.space2),
          Text(
            '设定后到点会提醒。留空表示不提醒。',
            style: t.bodySmall?.copyWith(color: wo.fgMid),
          ),
          const SizedBox(height: WoTokens.space4),
          TextField(
            controller: _water,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: '浇水间隔(天)', suffixText: '天'),
          ),
          const SizedBox(height: WoTokens.space3),
          TextField(
            controller: _fert,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: '施肥间隔(天)', suffixText: '天'),
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
