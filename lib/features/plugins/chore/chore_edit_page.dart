import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/member_avatar.dart';

/// 家务新增 / 编辑页。
///
/// [existing] 为空 = 新增；非空 = 编辑。保存成功后 `Navigator.pop(true)`。
class ChoreEditPage extends StatefulWidget {
  const ChoreEditPage({super.key, this.existing});

  final Chore? existing;

  @override
  State<ChoreEditPage> createState() => _ChoreEditPageState();
}

class _ChoreEditPageState extends State<ChoreEditPage> {
  static const _emojis = [
    '🧹', '🧺', '🍽️', '🗑️', '🧽', '🛏️', '🪴', '🐶',
    '🛒', '👕', '🚽', '🍳', '💡', '📦', '🚗', '🧊',
  ];

  late String _emoji;
  late final TextEditingController _title;
  late final TextEditingController _note;

  // 当前选中的负责人 user id；null = 未指派。
  String? _assignedTo;

  // 是否每周重复。开启后可在列表页「一键重新匹配」批量重置。
  bool _recurring = false;

  List<Member> _members = const [];
  bool _membersLoading = true;
  bool _membersLoaded = false;

  bool _submitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    _emoji = c?.emoji ?? '🧹';
    _assignedTo = c?.assignedTo;
    _recurring = c?.recurring ?? false;
    _title = TextEditingController(text: c?.title ?? '');
    _note = TextEditingController(text: c?.note ?? '');
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
          // 只在活跃成员里指派。
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

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty || _submitting) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final note = _note.text.trim();

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      if (_isEditing) {
        await session.api.updateChore(
          familyId,
          widget.existing!.id,
          title: title,
          emoji: _emoji,
          note: note.isEmpty ? null : note,
          assignedTo: _assignedTo,
          recurring: _recurring,
        );
      } else {
        await session.api.createChore(
          familyId,
          title: title,
          emoji: _emoji,
          note: note.isEmpty ? null : note,
          assignedTo: _assignedTo,
          recurring: _recurring,
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

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: Text(_isEditing ? '编辑家务' : '加家务')),
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
                              ? wo.chore.withValues(alpha: 0.30)
                              : wo.bgTint,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: sel ? wo.chore : Colors.transparent,
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
                  labelText: '家务',
                  hintText: '比如「倒垃圾」「洗碗」',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              Text('谁来做', style: t.titleSmall),
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
              const SizedBox(height: WoTokens.space3),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _recurring,
                onChanged: (v) => setState(() => _recurring = v),
                activeColor: wo.chore,
                title: Text('每周重复', style: t.titleSmall),
                subtitle: Text(
                  '每周固定要做的家务。新一周可在列表页「一键重新匹配」，把它们一起重置为待做。',
                  style: t.labelSmall?.copyWith(color: wo.fgMid),
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  hintText: '注意事项、截止时间、做法……',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: WoTokens.space4),
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
