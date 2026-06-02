import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'plant_placements.dart';

/// 新建 / 编辑植物表单(底部弹层)。传 [existing] 即编辑模式,否则新建。
///
/// 摆放标签全家共享、存后端;在这里可挑选 / 添加 / 长按删除。pop(true) 表示有改动,
/// 调用方据此刷新。
class PlantEditSheet extends StatefulWidget {
  const PlantEditSheet({super.key, this.existing});

  final Plant? existing;

  @override
  State<PlantEditSheet> createState() => _PlantEditSheetState();
}

class _PlantEditSheetState extends State<PlantEditSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _species =
      TextEditingController(text: widget.existing?.species ?? '');

  // 摆放标签全家共享、存后端。首帧用默认值占位,拉到家庭设置后替换。编辑模式下
  // 预选当前植物的摆放(即使它不在候选里也并入,避免选不中)。
  List<String> _placements = List.of(kDefaultPlacements);
  late String _placement =
      widget.existing?.placement ?? kDefaultPlacements.first;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (!_placements.contains(_placement)) {
      _placements = [_placement, ..._placements];
    }
    _loadPlacements();
  }

  Future<void> _loadPlacements() async {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;
    try {
      final settings = await session.api.plantSettings(fid);
      if (!mounted || settings.placements.isEmpty) return;
      setState(() {
        final list = [...settings.placements];
        // 保证当前选中的摆放始终在候选里(编辑老植物的自定义摆放)。
        if (!list.contains(_placement)) list.insert(0, _placement);
        _placements = list;
      });
    } catch (_) {
      // 拉取失败就先用默认占位,不打断。
    }
  }

  /// 把当前候选列表整体 PUT 到后端(全家共享);失败回滚并提示。
  Future<void> _persistPlacements(List<String> next, {String? select}) async {
    final prev = _placements;
    setState(() {
      _placements = next;
      if (select != null) _placement = select;
      if (!_placements.contains(_placement) && _placements.isNotEmpty) {
        _placement = _placements.first;
      }
    });
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;
    try {
      final settings =
          await session.api.updatePlantSettings(fid, placements: next);
      if (mounted && settings.placements.isNotEmpty) {
        setState(() => _placements = settings.placements);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _placements = prev); // 回滚
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('标签保存失败:$e')));
      }
    }
  }

  Future<void> _addPlacement() async {
    final ctrl = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加摆放位置'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 12,
          decoration: const InputDecoration(
            hintText: '如:北阳台 / 卫生间 / 客厅飘窗',
            helperText: '全家共享;此标签会作为环境信息发给 AI,写具体些更准',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (label == null || label.isEmpty || !mounted) return;
    if (_placements.contains(label)) {
      setState(() => _placement = label);
      return;
    }
    await _persistPlacements([..._placements, label], select: label);
  }

  Future<void> _deletePlacement(String p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「$p」'),
        content: const Text('全家共享的候选标签里移除,不影响已用此标签的植物。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _persistPlacements(_placements.where((e) => e != p).toList());
  }

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
        if (_isEdit) {
          await session.api.updatePlant(
            fid,
            widget.existing!.id,
            name: name,
            species: _species.text.trim(),
            placement: _placement,
          );
        } else {
          await session.api.createPlant(
            fid,
            name: name,
            species: _species.text.trim(),
            placement: _placement,
          );
        }
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
            _isEdit ? '编辑植物' : '添加植物',
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
          const SizedBox(height: 2),
          Text(
            '长按标签可删除;此标签会作为环境信息发给 AI',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: wo.fgDim),
          ),
          const SizedBox(height: WoTokens.space2),
          Wrap(
            spacing: WoTokens.space2,
            runSpacing: WoTokens.space2,
            children: [
              for (final p in _placements)
                GestureDetector(
                  onLongPress: () => _deletePlacement(p),
                  child: ChoiceChip(
                    label: Text(p),
                    selected: _placement == p,
                    onSelected: (_) => setState(() => _placement = p),
                  ),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: const Text('添加'),
                onPressed: _addPlacement,
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
