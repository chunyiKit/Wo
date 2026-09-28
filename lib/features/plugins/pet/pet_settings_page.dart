import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import '../../family/pet_profile_edit_page.dart';

class PetSettingsPage extends StatefulWidget {
  const PetSettingsPage({super.key, required this.pet});

  final Pet pet;

  @override
  State<PetSettingsPage> createState() => _PetSettingsPageState();
}

class _PetSettingsPageState extends State<PetSettingsPage> {
  late Future<(List<PetCarePlan>, List<PetRecordType>)> _future;
  (List<PetCarePlan>, List<PetRecordType>)? _data;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_data == null) _future = _fetch()..then(_store);
  }

  Future<(List<PetCarePlan>, List<PetRecordType>)> _fetch() async {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId!;
    final results = await Future.wait([
      session.api.petPlans(fid, widget.pet.id),
      session.api.petRecordTypes(fid, includeArchived: true),
    ]);
    return (results[0] as List<PetCarePlan>, results[1] as List<PetRecordType>);
  }

  void _store((List<PetCarePlan>, List<PetRecordType>) data) {
    if (mounted) setState(() => _data = data);
  }

  Future<void> _refreshSilently() async {
    try {
      _store(await _fetch());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => WoScaffold(
        appBar: WoAppBar(title: const Text('档案与照护计划')),
        body: _data != null
            ? _content(_data!)
            : AsyncView<(List<PetCarePlan>, List<PetRecordType>)>(
                future: _future,
                onRetry: () {
                  setState(() {
                    _data = null;
                    _future = _fetch()..then(_store);
                  });
                },
                builder: (_, data) => _content(_data ?? data),
              ),
      );

  Widget _content((List<PetCarePlan>, List<PetRecordType>) data) {
    final plans = data.$1;
    final types = data.$2;
    return ListView(
      padding: const EdgeInsets.all(WoTokens.space5),
      children: [
        WoCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              WoListTile(
                leading: Text(
                  widget.pet.emoji,
                  style: const TextStyle(fontSize: 26),
                ),
                title: Text(widget.pet.name),
                subtitle: const Text('照片、生日、品种与其他资料'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final changed = await Navigator.of(context).push<Pet>(
                    MaterialPageRoute(
                      builder: (_) => PetProfileEditPage(pet: widget.pet),
                    ),
                  );
                  if (changed != null && mounted) Navigator.pop(context, true);
                },
              ),
              const Divider(height: 1),
              WoListTile(
                leading: const Icon(Icons.tune),
                title: const Text('记录类型管理'),
                subtitle: const Text('自定义名称、emoji、顺序与停用状态'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PetTypeManagePage(),
                    ),
                  );
                  await _refreshSilently();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: WoTokens.space5),
        Row(
          children: [
            Text('照护计划', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            WoFilledButton.tonalIcon(
              onPressed: () => _editPlan(types),
              icon: const Icon(Icons.add),
              label: const Text('新建'),
            ),
          ],
        ),
        const SizedBox(height: WoTokens.space2),
        if (plans.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: WoTokens.space6),
            child: Center(child: Text('暂无照护计划')),
          )
        else
          for (final plan in plans)
            Padding(
              padding: const EdgeInsets.only(bottom: WoTokens.space2),
              child: WoCard(
                onTap: () => _editPlan(types, plan),
                child: WoListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Text(
                    plan.typeEmoji,
                    style: const TextStyle(fontSize: 26),
                  ),
                  title: Text(plan.name),
                  subtitle: Text(
                    '${_cycle(plan)} · ${plan.nextDueDate == null ? '无下次日期' : _ymd(plan.nextDueDate!)}',
                  ),
                  trailing: plan.active
                      ? const Icon(Icons.chevron_right)
                      : const Text('已停用'),
                ),
              ),
            ),
      ],
    );
  }

  Future<void> _editPlan(
    List<PetRecordType> allTypes, [
    PetCarePlan? plan,
  ]) async {
    final types = allTypes.where((item) => !item.archived).toList();
    if (types.isEmpty) return;
    var typeId = plan?.recordTypeId ?? types.first.id;
    var name = plan?.name ?? '';
    var note = plan?.note ?? '';
    var unit = plan?.recurrenceUnit ?? 'none';
    var interval = plan?.recurrenceInterval ?? 1;
    var due = plan?.nextDueDate ?? DateTime.now();
    var active = plan?.active ?? true;
    final saved = await showWoDialog<bool>(
      context: context,
      // 编辑弹窗和其中的日历都留在当前导航栈，返回时逐层关闭。
      useRootNavigator: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => WoAlertDialog(
          title: Text(plan == null ? '新建照护计划' : '编辑照护计划'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                WoDropdownButtonFormField<String>(
                  initialValue: typeId,
                  decoration: const InputDecoration(labelText: '记录类型'),
                  items: [
                    for (final type in types)
                      DropdownMenuItem(
                        value: type.id,
                        child: Text('${type.emoji} ${type.name}'),
                      ),
                  ],
                  onChanged: (value) => setDialogState(() => typeId = value!),
                ),
                const SizedBox(height: WoTokens.space4),
                WoTextFormField(
                  initialValue: name,
                  decoration: const InputDecoration(labelText: '计划名称 *'),
                  onChanged: (value) => name = value,
                ),
                const SizedBox(height: WoTokens.space4),
                WoTextFormField(
                  initialValue: note,
                  decoration: const InputDecoration(labelText: '备注'),
                  onChanged: (value) => note = value,
                ),
                const SizedBox(height: WoTokens.space4),
                Row(
                  children: [
                    Expanded(
                      child: WoDropdownButtonFormField<String>(
                        initialValue: unit,
                        decoration: const InputDecoration(labelText: '周期'),
                        items: const [
                          DropdownMenuItem(value: 'none', child: Text('仅一次')),
                          DropdownMenuItem(value: 'day', child: Text('每 N 天')),
                          DropdownMenuItem(value: 'week', child: Text('每 N 周')),
                          DropdownMenuItem(
                            value: 'month',
                            child: Text('每 N 月'),
                          ),
                          DropdownMenuItem(value: 'year', child: Text('每 N 年')),
                        ],
                        onChanged: (value) =>
                            setDialogState(() => unit = value!),
                      ),
                    ),
                    if (unit != 'none') ...[
                      const SizedBox(width: WoTokens.space3),
                      SizedBox(
                        width: 88,
                        child: WoTextFormField(
                          initialValue: '$interval',
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'N'),
                          onChanged: (value) =>
                              interval = int.tryParse(value) ?? 1,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: WoTokens.space3),
                WoListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('下次日期'),
                  subtitle: Text(_ymd(due)),
                  trailing: const Icon(Icons.calendar_today_outlined),
                  onTap: () async {
                    final value = await showDatePicker(
                      context: context,
                      useRootNavigator: false,
                      initialDate: due,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (value != null) setDialogState(() => due = value);
                  },
                ),
                if (plan != null) ...[
                  const SizedBox(height: WoTokens.space2),
                  WoSwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用计划'),
                    value: active,
                    onChanged: (value) => setDialogState(() => active = value),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (plan != null)
              WoTextButton(
                onPressed: () async {
                  final fid = WoScope.of(this.context).currentFamilyId!;
                  await WoScope.api(
                    this.context,
                  ).deletePetPlan(fid, widget.pet.id, plan.id);
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                },
                child: const Text('删除'),
              ),
            WoTextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            WoFilledButton(
              onPressed: () async {
                if (name.trim().isEmpty) return;
                final fid = WoScope.of(this.context).currentFamilyId!;
                try {
                  await WoScope.api(this.context).savePetPlan(
                    fid,
                    widget.pet.id,
                    planId: plan?.id,
                    recordTypeId: typeId,
                    name: name.trim(),
                    note: note.trim(),
                    recurrenceUnit: unit,
                    recurrenceInterval: interval.clamp(1, 999),
                    nextDueDate: due,
                    active: active,
                  );
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                } catch (error) {
                  if (mounted) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      WoSnackBar(
                        content: Text(
                          error is ApiException ? error.message : '保存失败',
                        ),
                      ),
                    );
                  }
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) await _refreshSilently();
  }
}

class PetTypeManagePage extends StatefulWidget {
  const PetTypeManagePage({super.key});

  @override
  State<PetTypeManagePage> createState() => _PetTypeManagePageState();
}

class _PetTypeManagePageState extends State<PetTypeManagePage> {
  List<PetRecordType>? _types;
  late Future<List<PetRecordType>> _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_types == null) {
      final fid = WoScope.of(context).currentFamilyId!;
      _future = WoScope.api(context).petRecordTypes(fid, includeArchived: true)
        ..then((value) {
          if (mounted) setState(() => _types = value);
        });
    }
  }

  Future<void> _edit([PetRecordType? type]) async {
    var name = type?.name ?? '';
    var emoji = type?.emoji ?? '🐾';
    var kind = type?.dataKind ?? 'general';
    final save = await showWoDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => WoAlertDialog(
          title: Text(type == null ? '新增记录类型' : '编辑记录类型'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              WoTextFormField(
                initialValue: name,
                decoration: const InputDecoration(labelText: '名称'),
                onChanged: (value) => name = value,
              ),
              const SizedBox(height: WoTokens.space4),
              WoTextFormField(
                initialValue: emoji,
                decoration: const InputDecoration(labelText: 'Emoji'),
                onChanged: (value) => emoji = value,
              ),
              const SizedBox(height: WoTokens.space4),
              WoDropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: '数据能力'),
                items: const [
                  DropdownMenuItem(value: 'general', child: Text('普通记录')),
                  DropdownMenuItem(value: 'weight', child: Text('体重（kg）')),
                ],
                onChanged: type == null
                    ? (value) => setState(() => kind = value!)
                    : null,
              ),
            ],
          ),
          actions: [
            WoTextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            WoFilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (save != true || name.trim().isEmpty || !mounted) return;
    final fid = WoScope.of(context).currentFamilyId!;
    final api = WoScope.api(context);
    if (type == null) {
      await api.createPetRecordType(
        fid,
        name: name.trim(),
        emoji: emoji.trim().isEmpty ? '🐾' : emoji.trim(),
        dataKind: kind,
      );
    } else {
      await api.updatePetRecordType(
        fid,
        type.id,
        name: name.trim(),
        emoji: emoji.trim().isEmpty ? '🐾' : emoji.trim(),
      );
    }
    final refreshed = await api.petRecordTypes(fid, includeArchived: true);
    if (mounted) setState(() => _types = refreshed);
  }

  @override
  Widget build(BuildContext context) => WoScaffold(
        appBar: WoAppBar(
          title: const Text('记录类型'),
          actions: [
            WoIconButton(onPressed: _edit, icon: const Icon(Icons.add)),
          ],
        ),
        body: _types == null
            ? AsyncView<List<PetRecordType>>(
                future: _future,
                onRetry: () {},
                builder: (_, value) => _list(_types ?? value),
              )
            : _list(_types!),
      );

  Widget _list(List<PetRecordType> types) => ReorderableListView.builder(
        padding: const EdgeInsets.all(WoTokens.space4),
        itemCount: types.length,
        onReorderItem: (oldIndex, newIndex) async {
          final copy = [...types];
          final item = copy.removeAt(oldIndex);
          copy.insert(newIndex, item);
          setState(() => _types = copy);
          final fid = WoScope.of(context).currentFamilyId!;
          await WoScope.api(context).reorderPetRecordTypes(
            fid,
            copy
                .where((item) => !item.archived)
                .map((item) => item.id)
                .toList(),
          );
        },
        itemBuilder: (_, index) {
          final type = types[index];
          return WoListTile(
            key: ValueKey(type.id),
            leading: Text(type.emoji, style: const TextStyle(fontSize: 25)),
            title: Text(type.name),
            subtitle: Text(type.isWeight ? '体重（kg）' : '普通记录'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                WoSwitch(
                  value: !type.archived,
                  onChanged: (enabled) async {
                    final fid = WoScope.of(context).currentFamilyId!;
                    await WoScope.api(
                      context,
                    ).updatePetRecordType(fid, type.id, archived: !enabled);
                    final copy = [...types];
                    copy[index] = PetRecordType(
                      id: type.id,
                      name: type.name,
                      emoji: type.emoji,
                      dataKind: type.dataKind,
                      sortOrder: type.sortOrder,
                      archived: !enabled,
                    );
                    if (mounted) setState(() => _types = copy);
                  },
                ),
                const Icon(Icons.drag_handle),
              ],
            ),
            onTap: () => _edit(type),
          );
        },
      );
}

String _cycle(PetCarePlan plan) {
  if (plan.recurrenceUnit == 'none') return '仅一次';
  const labels = {'day': '天', 'week': '周', 'month': '月', 'year': '年'};
  return '每 ${plan.recurrenceInterval} ${labels[plan.recurrenceUnit]}';
}

String _ymd(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
