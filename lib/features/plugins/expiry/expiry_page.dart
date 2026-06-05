import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import 'expiry_kinds.dart';

String _dateLabel(DateTime d) => '${d.year}年${d.month}月${d.day}日';

/// 到期管家首页：列出会到期的证件 / 年检 / 保险 / 合同，显示到期日与倒计时。
class ExpiryPage extends StatefulWidget {
  const ExpiryPage({super.key});

  @override
  State<ExpiryPage> createState() => _ExpiryPageState();
}

class _ExpiryPageState extends State<ExpiryPage> {
  // `_future` 只驱动首屏 spinner;数据缓存进 `_items`,之后的增删改静默就地替换,
  // 不闪——见 CLAUDE.md「列表页刷新不能闪一下」。
  late Future<List<ExpiryItem>> _future;
  List<ExpiryItem>? _items;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<ExpiryItem>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <ExpiryItem>[])
        : session.api.expiryItems(familyId);
  }

  void _store(List<ExpiryItem> list) {
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
    if (mounted) await WoScope.of(context).refresh();
  }

  Future<void> _openEditor([ExpiryItem? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ExpiryEditPage(existing: existing)),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _togglePause(ExpiryItem e) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.updateExpiryItem(familyId, e.id, active: !e.active);
      await _refreshSilently();
    } catch (err) {
      if (mounted) _toast(err);
    }
  }

  Future<void> _delete(ExpiryItem e) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记录'),
        content: Text('确定删除「${e.name}」吗？'),
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
    try {
      await session.api.deleteExpiryItem(familyId, e.id);
      await _refreshSilently();
    } catch (err) {
      if (mounted) _toast(err);
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
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('到期管家')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        backgroundColor: wo.expiry,
        foregroundColor: wo.fg,
        icon: const Icon(Icons.add),
        label: const Text('加一项'),
      ),
      body: SafeArea(
        child: _items != null
            ? _buildBody(context, _items!)
            : AsyncView<List<ExpiryItem>>(
                future: _future,
                onRetry: _retry,
                builder: _buildBody,
              ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<ExpiryItem> list) {
    if (list.isEmpty) return _Empty(onAdd: _openEditor);
    return RefreshIndicator(
      onRefresh: _refreshSilently,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          WoTokens.space4,
          WoTokens.space3,
          WoTokens.space4,
          100,
        ),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: WoTokens.space3),
        itemBuilder: (_, i) => _ItemTile(
          item: list[i],
          onEdit: () => _openEditor(list[i]),
          onTogglePause: () => _togglePause(list[i]),
          onDelete: () => _delete(list[i]),
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.onEdit,
    required this.onTogglePause,
    required this.onDelete,
  });

  final ExpiryItem item;
  final VoidCallback onEdit;
  final VoidCallback onTogglePause;
  final VoidCallback onDelete;

  ({String text, Color? tone}) _due(BuildContext context) {
    final wo = context.wo;
    if (!item.active) return (text: '已暂停', tone: wo.fgDim);
    final d = item.daysUntil;
    if (d < 0) return (text: '已过期 ${-d} 天', tone: wo.danger);
    if (d == 0) return (text: '今天到期', tone: wo.danger);
    if (d == 1) return (text: '明天到期', tone: wo.warning);
    if (d <= 14) return (text: '$d 天后到期', tone: wo.warning);
    return (text: '$d 天后到期', tone: null);
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final due = _due(context);
    final dim = !item.active;
    final kindLabel = kindFor(item.kind).label;
    return WoCard(
      onTap: onEdit,
      child: Opacity(
        opacity: dim ? 0.55 : 1,
        child: Row(
          children: [
            Text(item.emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: WoTokens.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: t.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: wo.fg,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        kindLabel,
                        style: t.labelSmall?.copyWith(color: wo.fgMid),
                      ),
                      const SizedBox(width: WoTokens.space2),
                      Text(
                        _dateLabel(item.expireOn),
                        style: t.labelSmall?.copyWith(color: wo.fgMid),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    due.text,
                    style: t.labelMedium?.copyWith(
                      color: due.tone ?? wo.fgMid,
                      fontWeight:
                          due.tone != null ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: wo.fgDim),
              onSelected: (v) {
                if (v == 'edit') onEdit();
                if (v == 'pause') onTogglePause();
                if (v == 'delete') onDelete();
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(
                  value: 'pause',
                  child: Text(item.active ? '暂停提醒' : '启用'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
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
            const Text('📄', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有记录', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把身份证、护照、驾照、车险、年检、合同这些会到期的事情记下来，'
              '到期前自动提醒全家，别再错过续期。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('加第一项')),
          ],
        ),
      ),
    );
  }
}

/// 到期项新增 / 编辑页。[existing] 为空 = 新增；非空 = 编辑。保存成功 `pop(true)`。
class ExpiryEditPage extends StatefulWidget {
  const ExpiryEditPage({super.key, this.existing});

  final ExpiryItem? existing;

  @override
  State<ExpiryEditPage> createState() => _ExpiryEditPageState();
}

class _ExpiryEditPageState extends State<ExpiryEditPage> {
  // 常用「提前提醒」档位（天）。后端允许 0–365，这里给常用预设。
  static const _leadOptions = [0, 7, 15, 30, 60, 90];

  late String _kind;
  late String _emoji;
  late final TextEditingController _name;
  late final TextEditingController _note;
  late DateTime _expireOn;
  bool _notify = true;
  int _notifyDaysBefore = 30;
  bool _submitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? 'passport';
    _emoji = e?.emoji ?? kindFor(_kind).emoji;
    _name = TextEditingController(text: e?.name ?? '');
    _note = TextEditingController(text: e?.note ?? '');
    _expireOn = e?.expireOn ?? DateTime.now().add(const Duration(days: 30));
    _notify = e?.notifyEnabled ?? true;
    _notifyDaysBefore = e?.notifyDaysBefore ?? 30;
  }

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  void _pickKind(ExpiryKind k) {
    setState(() {
      // 切换类型时，若用户还没自定义过 emoji（仍是上一个类型的默认值），就跟着更新。
      if (_emoji == kindFor(_kind).emoji) _emoji = k.emoji;
      _kind = k.code;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expireOn,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 30),
    );
    if (picked != null) {
      setState(() => _expireOn = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toastMsg('请填写名称');
      return;
    }
    if (_submitting) return;
    setState(() => _submitting = true);
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final note = _note.text.trim();
    final nav = Navigator.of(context);
    try {
      if (_isEditing) {
        await session.api.updateExpiryItem(
          familyId,
          widget.existing!.id,
          name: name,
          emoji: _emoji,
          kind: _kind,
          expireOn: _expireOn,
          note: note,
          notifyEnabled: _notify,
          notifyDaysBefore: _notifyDaysBefore,
        );
      } else {
        await session.api.createExpiryItem(
          familyId,
          name: name,
          emoji: _emoji,
          kind: _kind,
          expireOn: _expireOn,
          note: note.isEmpty ? null : note,
          notifyEnabled: _notify,
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

  void _toastMsg(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _toast(Object error) {
    final msg = switch (error) {
      ApiException e => e.message,
      NetworkException e => e.message,
      _ => '操作失败',
    };
    _toastMsg(msg);
  }

  String _leadLabel(int days) => days == 0 ? '当天' : '提前 $days 天';

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: Text(_isEditing ? '编辑' : '加一项')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('类型', style: t.titleSmall),
              const SizedBox(height: WoTokens.space2),
              Wrap(
                spacing: WoTokens.space2,
                runSpacing: WoTokens.space2,
                children: [
                  for (final k in expiryKinds)
                    ChoiceChip(
                      avatar: Text(k.emoji, style: const TextStyle(fontSize: 16)),
                      label: Text(k.label),
                      selected: k.code == _kind,
                      onSelected: (_) => _pickKind(k),
                    ),
                ],
              ),
              const SizedBox(height: WoTokens.space4),
              TextField(
                controller: _name,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '比如「老爸的护照」「家庭车险」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.event, color: wo.expiry),
                title: const Text('到期日'),
                subtitle: Text(
                  _dateLabel(_expireOn),
                  style: t.bodyMedium?.copyWith(color: wo.fgMid),
                ),
                trailing:
                    TextButton(onPressed: _pickDate, child: const Text('选择')),
                onTap: _pickDate,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _notify,
                activeColor: wo.expiry,
                title: const Text('到期前提醒'),
                subtitle: Text(
                  _notify ? '提醒全家提前安排续期' : '开启后会在到期前推送通知',
                  style: t.labelSmall?.copyWith(color: wo.fgMid),
                ),
                onChanged: (v) => setState(() => _notify = v),
              ),
              if (_notify) ...[
                const SizedBox(height: WoTokens.space2),
                Wrap(
                  spacing: WoTokens.space2,
                  children: [
                    for (final d in _leadOptions)
                      ChoiceChip(
                        label: Text(_leadLabel(d)),
                        selected: d == _notifyDaysBefore,
                        onSelected: (_) =>
                            setState(() => _notifyDaysBefore = d),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _note,
                maxLength: 200,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  hintText: '证件号、办理地点、提醒事项……',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              FilledButton(
                onPressed: _submitting ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: wo.expiry,
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
