import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/wo_card.dart';

/// 纪念日新增 / 编辑页。
///
/// [existing] 为空 = 新增；非空 = 编辑既有记录（多一个删除入口）。
/// 保存 / 删除成功后 `Navigator.pop(true)`，由列表页据此刷新。
class AnniversaryEditPage extends StatefulWidget {
  const AnniversaryEditPage({super.key, this.existing});

  final Anniversary? existing;

  @override
  State<AnniversaryEditPage> createState() => _AnniversaryEditPageState();
}

class _AnniversaryEditPageState extends State<AnniversaryEditPage> {
  static const _emojis = [
    '💞',
    '💍',
    '🎂',
    '👶',
    '🏠',
    '🐱',
    '🐶',
    '✈️',
    '🎓',
    '🌹',
    '🎉',
    '🌙',
  ];

  // 提前提醒的可选天数（0 = 当天）。
  static const _daysBeforeOptions = [0, 1, 3, 7];

  late String _emoji;
  late DateTime _date;
  late bool _isLunar;
  late bool _notifyEnabled;
  late int _notifyDaysBefore;
  late final TextEditingController _name;
  late final TextEditingController _note;
  bool _submitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _emoji = e?.emoji ?? '💞';
    _date = e?.eventDate ?? DateTime.now();
    _isLunar = e?.isLunar ?? false;
    _notifyEnabled = e?.notifyEnabled ?? false;
    _notifyDaysBefore = e?.notifyDaysBefore ?? 1;
    _name = TextEditingController(text: e?.name ?? '');
    _note = TextEditingController(text: e?.note ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    final note = _note.text.trim();
    try {
      if (_isEditing) {
        await session.api.updateAnniversary(
          familyId,
          widget.existing!.id,
          name: name,
          eventDate: _date,
          emoji: _emoji,
          isLunar: _isLunar,
          note: note.isEmpty ? null : note,
          notifyEnabled: _notifyEnabled,
          notifyDaysBefore: _notifyDaysBefore,
        );
      } else {
        await session.api.createAnniversary(
          familyId,
          name: name,
          eventDate: _date,
          emoji: _emoji,
          isLunar: _isLunar,
          note: note.isEmpty ? null : note,
          notifyEnabled: _notifyEnabled,
          notifyDaysBefore: _notifyDaysBefore,
        );
      }
      if (mounted) nav.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        _toast(e);
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除纪念日'),
        content: Text('确定删除「${widget.existing!.name}」吗？此操作不可撤销。'),
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
    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      await session.api.deleteAnniversary(familyId, widget.existing!.id);
      if (mounted) nav.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        _toast(e);
      }
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
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final dateText = '${_date.year}年${_date.month}月${_date.day}日';
    final canSave = _name.text.trim().isNotEmpty && !_submitting;

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(
        title: Text(_isEditing ? '编辑纪念日' : '新增纪念日'),
        actions: [
          if (_isEditing)
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: _submitting ? null : _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 实时预览卡。
              WoCard(
                color: wo.anniv,
                padding: const EdgeInsets.all(WoTokens.space6),
                child: Row(
                  children: [
                    Text(_emoji, style: const TextStyle(fontSize: 34)),
                    const SizedBox(width: WoTokens.space4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _name.text.trim().isEmpty
                                ? '纪念日名字'
                                : _name.text.trim(),
                            style: t.titleLarge,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$dateText${_isLunar ? ' · 农历' : ''}',
                            style: t.bodySmall?.copyWith(color: wo.fgMid),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: WoTokens.space6),
              Text('挑一个 emoji', style: t.titleMedium),
              const SizedBox(height: WoTokens.space3),
              GridView.count(
                crossAxisCount: 6,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: WoTokens.space2,
                mainAxisSpacing: WoTokens.space2,
                children: [
                  for (final e in _emojis)
                    GestureDetector(
                      onTap: () => setState(() => _emoji = e),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: e == _emoji ? wo.accentSoft : wo.bgTint,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: e == _emoji ? wo.accent : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: WoTokens.space6),
              TextField(
                controller: _name,
                maxLength: 32,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '名字',
                  hintText: '比如「我们的结婚纪念日」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              // 日期选择
              InkWell(
                borderRadius: BorderRadius.circular(WoTokens.cardRadius),
                onTap: _pickDate,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: WoTokens.space4,
                    vertical: WoTokens.space4,
                  ),
                  decoration: BoxDecoration(
                    color: wo.bgTint,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_outlined, color: wo.fgMid, size: 20),
                      const SizedBox(width: WoTokens.space3),
                      Text('日期',
                          style: t.bodyMedium?.copyWith(color: wo.fgMid)),
                      const Spacer(),
                      Text(dateText, style: t.titleMedium),
                      const SizedBox(width: WoTokens.space2),
                      Icon(Icons.chevron_right, color: wo.fgDim, size: 20),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              SwitchListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: WoTokens.space2),
                title: const Text('按农历记'),
                subtitle: Text(
                  '开启后这天按农历周年提醒',
                  style: t.bodySmall?.copyWith(color: wo.fgMid),
                ),
                value: _isLunar,
                onChanged: (v) => setState(() => _isLunar = v),
              ),
              // 到期提醒开关 + 提前天数。
              SwitchListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: WoTokens.space2),
                title: const Text('到期提醒'),
                subtitle: Text(
                  _notifyEnabled
                      ? (_notifyDaysBefore == 0
                          ? '当天给全家发一条通知'
                          : '提前 $_notifyDaysBefore 天给全家发一条通知')
                      : '到日子时给全家发一条通知',
                  style: t.bodySmall?.copyWith(color: wo.fgMid),
                ),
                value: _notifyEnabled,
                onChanged: (v) => setState(() => _notifyEnabled = v),
              ),
              if (_notifyEnabled) ...[
                const SizedBox(height: WoTokens.space2),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: WoTokens.space2),
                  child: Row(
                    children: [
                      Text(
                        '提前',
                        style: t.bodyMedium?.copyWith(color: wo.fgMid),
                      ),
                      const SizedBox(width: WoTokens.space3),
                      Expanded(
                        child: Wrap(
                          spacing: WoTokens.space2,
                          children: [
                            for (final d in _daysBeforeOptions)
                              ChoiceChip(
                                label: Text(d == 0 ? '当天' : '$d 天'),
                                selected: _notifyDaysBefore == d,
                                onSelected: (_) =>
                                    setState(() => _notifyDaysBefore = d),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: WoTokens.space2),
              TextField(
                controller: _note,
                maxLength: 200,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  hintText: '写点想记住的话',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: WoTokens.space5),
              FilledButton(
                onPressed: canSave ? _save : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isEditing ? '保存' : '添加'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
