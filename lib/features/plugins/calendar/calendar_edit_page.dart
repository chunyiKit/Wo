import 'package:add_2_calendar/add_2_calendar.dart' as cal;
import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/member_avatar.dart';

/// 家历新增 / 编辑页。
///
/// [existing] 为空 = 新增；非空 = 编辑。保存成功后 `Navigator.pop(true)`。
/// 统一一条「条目」：选了日期就是日程（可再选时间），不选日期就是无日期待办。
class CalendarEditPage extends StatefulWidget {
  const CalendarEditPage({super.key, this.existing});

  final CalendarItem? existing;

  @override
  State<CalendarEditPage> createState() => _CalendarEditPageState();
}

class _CalendarEditPageState extends State<CalendarEditPage> {
  static const _emojis = [
    '📅',
    '📌',
    '🩺',
    '🎂',
    '✈️',
    '🛒',
    '💰',
    '🎓',
    '🏠',
    '🚗',
    '🎉',
    '📞',
    '💊',
    '🐶',
    '⚽',
    '🍽️',
    '📝',
  ];

  // 重复选项：值对应后端 repeat 字段。
  static const _repeats = <(String, String)>[
    ('none', '不重复'),
    ('daily', '每天'),
    ('weekly', '每周'),
    ('monthly', '每月'),
  ];

  late String _emoji;
  late final TextEditingController _title;
  late final TextEditingController _note;

  DateTime? _date; // null = 无日期待办
  bool _allDay = true;
  TimeOfDay? _time; // 仅 _allDay=false 时有意义
  String _repeat = 'none';
  String? _assignedTo;
  bool _notify = false;
  int _notifyDaysBefore = 0;
  // 保存后是否弹系统日历「添加事件」页(用户在那里自定义提醒)。仅有日期时有效。
  bool _addToPhone = false;

  List<Member> _members = const [];
  bool _membersLoading = true;
  bool _membersLoaded = false;
  bool _submitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    _emoji = c?.emoji ?? '📅';
    _title = TextEditingController(text: c?.title ?? '');
    _note = TextEditingController(text: c?.note ?? '');
    _date = c?.eventDate;
    _allDay = c?.allDay ?? true;
    if (c?.startMinute != null) {
      _time =
          TimeOfDay(hour: c!.startMinute! ~/ 60, minute: c.startMinute! % 60);
    }
    _repeat = c?.repeat ?? 'none';
    _assignedTo = c?.assignedTo;
    _notify = c?.notifyEnabled ?? false;
    _notifyDaysBefore = c?.notifyDaysBefore ?? 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_membersLoaded) {
      _membersLoaded = true;
      _loadMembers();
    }
  }

  Future<void> _loadMembers() async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) {
      if (mounted) setState(() => _membersLoading = false);
      return;
    }
    try {
      final members = await session.api.members(familyId);
      if (mounted) {
        setState(() {
          _members = members.where((m) => m.status == 'active').toList();
          _membersLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _membersLoading = false);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) {
      setState(() => _date = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 9, minute: 0),
    );
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty || _submitting) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final note = _note.text.trim();

    // 无日期待办：清掉时间 / 重复 / 提醒（后端也会兜底，这里先归一好让请求干净）。
    final hasDate = _date != null;
    final allDay = !hasDate || _allDay;
    final startMinute = (hasDate && !allDay && _time != null)
        ? _time!.hour * 60 + _time!.minute
        : null;
    final repeat = hasDate ? _repeat : 'none';
    final notify = hasDate && _notify;

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      if (_isEditing) {
        await session.api.updateCalendarItem(
          familyId,
          widget.existing!.id,
          title: title,
          emoji: _emoji,
          eventDate: _date,
          allDay: allDay,
          startMinute: startMinute,
          repeat: repeat,
          note: note.isEmpty ? null : note,
          assignedTo: _assignedTo,
          notifyEnabled: notify,
          notifyDaysBefore: _notifyDaysBefore,
        );
      } else {
        await session.api.createCalendarItem(
          familyId,
          title: title,
          emoji: _emoji,
          eventDate: _date,
          allDay: allDay,
          startMinute: startMinute,
          repeat: repeat,
          note: note.isEmpty ? null : note,
          assignedTo: _assignedTo,
          notifyEnabled: notify,
          notifyDaysBefore: _notifyDaysBefore,
        );
      }
      // 仅当勾选且有日期时，弹系统日历「添加事件」页（用户在那里自定义提醒）。
      if (_addToPhone && hasDate) {
        await _pushToPhoneCalendar(title: title, note: note, allDay: allDay);
      }
      if (mounted) nav.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        _toast(e);
      }
    }
  }

  /// 弹出手机自带日历的「添加事件」页，预填标题/时间/重复，提醒留给用户在系统页里设。
  /// Android 走 ACTION_INSERT intent（免权限）；iOS 弹 EventKit 编辑页。
  Future<void> _pushToPhoneCalendar({
    required String title,
    required String note,
    required bool allDay,
  }) async {
    final d = _date!;
    final DateTime start;
    final DateTime end;
    if (allDay || _time == null) {
      start = DateTime(d.year, d.month, d.day);
      end = start.add(const Duration(days: 1));
    } else {
      start = DateTime(d.year, d.month, d.day, _time!.hour, _time!.minute);
      end = start.add(const Duration(hours: 1));
    }

    cal.Recurrence? recurrence;
    switch (_repeat) {
      case 'daily':
        recurrence = cal.Recurrence(frequency: cal.Frequency.daily);
      case 'weekly':
        recurrence = cal.Recurrence(frequency: cal.Frequency.weekly);
      case 'monthly':
        recurrence = cal.Recurrence(frequency: cal.Frequency.monthly);
      default:
        recurrence = null;
    }

    try {
      await cal.Add2Calendar.addEvent2Cal(
        cal.Event(
          title: title,
          description: note.isEmpty ? null : note,
          startDate: start,
          endDate: end,
          allDay: allDay,
          recurrence: recurrence,
        ),
      );
    } catch (_) {
      // 弹日历失败不应连累家历本身已保存成功，静默忽略。
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
    final canSave = _title.text.trim().isNotEmpty && !_submitting;
    final hasDate = _date != null;

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: Text(_isEditing ? '编辑日程' : '加一项')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // emoji 选择
              SizedBox(
                height: 52,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _emojis.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: WoTokens.space2),
                  itemBuilder: (_, i) {
                    final e = _emojis[i];
                    final sel = e == _emoji;
                    return GestureDetector(
                      onTap: () => setState(() => _emoji = e),
                      child: Container(
                        width: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: sel
                              ? wo.calendar.withValues(alpha: 0.30)
                              : wo.bgTint,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: sel ? wo.calendar : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 26)),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              TextField(
                controller: _title,
                maxLength: 64,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '标题',
                  hintText: '比如「看牙医」「交房租」「周末爬山」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),

              // 日期：可选；不选 = 无日期待办。
              _DateRow(
                date: _date,
                onPick: _pickDate,
                onClear: () => setState(() {
                  _date = null;
                  _allDay = true;
                  _time = null;
                  _repeat = 'none';
                  _notify = false;
                }),
              ),

              // 以下区块仅在排了日期时才有意义。
              if (hasDate) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: !_allDay,
                  activeColor: wo.calendar,
                  title: const Text('指定时间'),
                  subtitle: Text(
                    _allDay
                        ? '当前为全天'
                        : (_time == null
                            ? '点右侧选个时间'
                            : '时间：${_time!.format(context)}'),
                    style: t.labelSmall?.copyWith(color: wo.fgMid),
                  ),
                  onChanged: (v) {
                    setState(() {
                      _allDay = !v;
                      if (v && _time == null) {
                        _time = const TimeOfDay(hour: 9, minute: 0);
                      }
                    });
                  },
                ),
                if (!_allDay)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule, size: 18),
                      label:
                          Text(_time == null ? '选择时间' : _time!.format(context)),
                    ),
                  ),
                const SizedBox(height: WoTokens.space3),
                Text('重复', style: t.titleSmall),
                const SizedBox(height: WoTokens.space2),
                Wrap(
                  spacing: WoTokens.space2,
                  children: [
                    for (final (value, label) in _repeats)
                      ChoiceChip(
                        label: Text(label),
                        selected: _repeat == value,
                        onSelected: (_) => setState(() => _repeat = value),
                      ),
                  ],
                ),
                if (_repeat != 'none')
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '重复项「完成」时会自动顺延到下一次，不会被划掉。',
                      style: t.labelSmall?.copyWith(color: wo.fgMid),
                    ),
                  ),
              ],
              const SizedBox(height: WoTokens.space3),

              // 指派成员
              Text('谁来负责', style: t.titleSmall),
              const SizedBox(height: WoTokens.space2),
              if (_membersLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: WoTokens.space2),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Wrap(
                  spacing: WoTokens.space2,
                  runSpacing: WoTokens.space2,
                  children: [
                    ChoiceChip(
                      label: const Text('暂不指派'),
                      selected: _assignedTo == null,
                      onSelected: (_) => setState(() => _assignedTo = null),
                    ),
                    for (final m in _members)
                      ChoiceChip(
                        avatar: MemberAvatar(
                          url: m.avatarUrl,
                          emoji: m.avatarEmoji,
                          size: 20,
                        ),
                        label: Text(m.displayName),
                        selected: _assignedTo == m.userId,
                        onSelected: (_) =>
                            setState(() => _assignedTo = m.userId),
                      ),
                  ],
                ),

              // 提醒：仅排了日期时可开。
              if (hasDate) ...[
                const SizedBox(height: WoTokens.space2),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _notify,
                  activeColor: wo.calendar,
                  title: const Text('到点提醒'),
                  subtitle: Text(
                    _notify
                        ? (_notifyDaysBefore == 0
                            ? '当天推送提醒全家'
                            : '提前 $_notifyDaysBefore 天推送提醒全家')
                        : '开启后会在到期前推送通知',
                    style: t.labelSmall?.copyWith(color: wo.fgMid),
                  ),
                  onChanged: (v) => setState(() => _notify = v),
                ),
                if (_notify)
                  Row(
                    children: [
                      Text('提前',
                          style: t.bodyMedium?.copyWith(color: wo.fgMid)),
                      Expanded(
                        child: Slider(
                          value: _notifyDaysBefore.toDouble(),
                          min: 0,
                          max: 14,
                          divisions: 14,
                          activeColor: wo.calendar,
                          label: _notifyDaysBefore == 0
                              ? '当天'
                              : '$_notifyDaysBefore 天',
                          onChanged: (v) =>
                              setState(() => _notifyDaysBefore = v.round()),
                        ),
                      ),
                      Text(
                        _notifyDaysBefore == 0 ? '当天' : '$_notifyDaysBefore 天',
                        style: t.bodyMedium,
                      ),
                    ],
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _addToPhone,
                  activeColor: wo.calendar,
                  title: const Text('存入手机日历'),
                  subtitle: Text(
                    '保存后弹出手机自带日历，可在那里自定义提醒时间',
                    style: t.labelSmall?.copyWith(color: wo.fgMid),
                  ),
                  onChanged: (v) => setState(() => _addToPhone = v),
                ),
              ],
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  hintText: '地点、要带的东西、注意事项……',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              FilledButton(
                onPressed: canSave ? _save : null,
                style: FilledButton.styleFrom(
                  backgroundColor: wo.calendar,
                  foregroundColor: wo.fg,
                ),
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

/// 日期选择行：显示已选日期，可清除（清除即变成无日期待办）。
class _DateRow extends StatelessWidget {
  const _DateRow(
      {required this.date, required this.onPick, required this.onClear});

  final DateTime? date;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final has = date != null;
    final label =
        has ? '${date!.year}年${date!.month}月${date!.day}日' : '无日期（仅作为待办）';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: WoTokens.space1),
      child: Row(
        children: [
          Icon(Icons.event, size: 20, color: wo.calendar),
          const SizedBox(width: WoTokens.space2),
          Expanded(
            child: GestureDetector(
              onTap: onPick,
              child: Text(
                label,
                style: t.bodyLarge?.copyWith(
                  color: has ? wo.fg : wo.fgMid,
                  fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
          if (has)
            TextButton(onPressed: onClear, child: const Text('清除'))
          else
            TextButton(onPressed: onPick, child: const Text('选日期')),
        ],
      ),
    );
  }
}
