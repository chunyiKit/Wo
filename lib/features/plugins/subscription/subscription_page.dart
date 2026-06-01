import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';

String _money(double v) =>
    v == v.roundToDouble() ? '¥${v.toInt()}' : '¥${v.toStringAsFixed(2)}';

String _cycleLabel(String cycle) => cycle == 'yearly' ? '年' : '月';

/// 订阅管家首页：列出订阅 / 定期账单，显示金额、周期、下次扣费倒计时。
class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> {
  // `_future` 只驱动首屏 spinner;数据缓存进 `_items`,之后的增删改静默就地替换,
  // 不闪——见 CLAUDE.md「列表页刷新不能闪一下」。
  late Future<List<Subscription>> _future;
  List<Subscription>? _items;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<Subscription>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <Subscription>[])
        : session.api.subscriptions(familyId);
  }

  void _store(List<Subscription> list) {
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

  Future<void> _openEditor([Subscription? existing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => SubscriptionEditPage(existing: existing)),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _togglePause(Subscription s) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.updateSubscription(familyId, s.id, active: !s.active);
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _delete(Subscription s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅'),
        content: Text('确定删除「${s.name}」吗？'),
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
      await session.api.deleteSubscription(familyId, s.id);
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
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
      appBar: AppBar(title: const Text('订阅管家')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        backgroundColor: wo.subscribe,
        foregroundColor: wo.fg,
        icon: const Icon(Icons.add),
        label: const Text('加订阅'),
      ),
      body: SafeArea(
        child: _items != null
            ? _buildBody(context, _items!)
            : AsyncView<List<Subscription>>(
                future: _future,
                onRetry: _retry,
                builder: _buildBody,
              ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<Subscription> list) {
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
        itemBuilder: (_, i) => _SubTile(
          sub: list[i],
          onEdit: () => _openEditor(list[i]),
          onTogglePause: () => _togglePause(list[i]),
          onDelete: () => _delete(list[i]),
        ),
      ),
    );
  }
}

class _SubTile extends StatelessWidget {
  const _SubTile({
    required this.sub,
    required this.onEdit,
    required this.onTogglePause,
    required this.onDelete,
  });

  final Subscription sub;
  final VoidCallback onEdit;
  final VoidCallback onTogglePause;
  final VoidCallback onDelete;

  ({String text, Color? tone}) _due(BuildContext context) {
    final wo = context.wo;
    if (!sub.active) return (text: '已暂停', tone: wo.fgDim);
    final d = sub.daysUntil;
    if (d < 0) return (text: '已过期待扣费', tone: wo.danger);
    if (d == 0) return (text: '今天扣费', tone: wo.warning);
    if (d == 1) return (text: '明天扣费', tone: wo.warning);
    if (d <= 3) return (text: '$d 天后扣费', tone: wo.warning);
    return (text: '$d 天后扣费', tone: null);
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final due = _due(context);
    final dim = !sub.active;
    return WoCard(
      onTap: onEdit,
      child: Opacity(
        opacity: dim ? 0.55 : 1,
        child: Row(
          children: [
            Text(sub.emoji, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: WoTokens.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sub.name,
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
                        '${_money(sub.amount)} / ${_cycleLabel(sub.cycle)}',
                        style: t.labelMedium?.copyWith(
                          color: wo.fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: WoTokens.space2),
                      Text(
                        due.text,
                        style: t.labelSmall?.copyWith(
                          color: due.tone ?? wo.fgMid,
                          fontWeight: due.tone != null
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  if (sub.autoRecord) ...[
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.sync_alt, size: 12, color: wo.subscribe),
                        const SizedBox(width: 3),
                        Text(
                          '到期自动记账',
                          style: t.labelSmall?.copyWith(color: wo.subscribe),
                        ),
                      ],
                    ),
                  ],
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
                  child: Text(sub.active ? '暂停' : '启用'),
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
            const Text('💳', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有订阅', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把视频会员、云盘、房租这些定期账单记下来，到期自动提醒，还能自动记账。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('加第一个订阅')),
          ],
        ),
      ),
    );
  }
}

/// 订阅新增 / 编辑页。[existing] 为空 = 新增；非空 = 编辑。保存成功 `pop(true)`。
class SubscriptionEditPage extends StatefulWidget {
  const SubscriptionEditPage({super.key, this.existing});

  final Subscription? existing;

  @override
  State<SubscriptionEditPage> createState() => _SubscriptionEditPageState();
}

class _SubscriptionEditPageState extends State<SubscriptionEditPage> {
  static const _emojis = [
    '💳',
    '📺',
    '🎵',
    '☁️',
    '🎮',
    '📰',
    '🏠',
    '📱',
    '🚗',
    '💡',
    '🌐',
    '🏋️',
    '📚',
    '🍿',
    '🐱',
    '💧',
  ];

  late String _emoji;
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _note;

  String _cycle = 'monthly';
  late DateTime _nextDue;
  bool _notify = true;
  int _notifyDaysBefore = 3;
  bool _autoRecord = true;
  bool _submitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _emoji = s?.emoji ?? '💳';
    _name = TextEditingController(text: s?.name ?? '');
    _amount = TextEditingController(
      text: s == null ? '' : _money(s.amount).replaceFirst('¥', ''),
    );
    _note = TextEditingController(text: s?.note ?? '');
    _cycle = s?.cycle ?? 'monthly';
    _nextDue = s?.nextDue ?? DateTime.now();
    _notify = s?.notifyEnabled ?? true;
    _notifyDaysBefore = s?.notifyDaysBefore ?? 3;
    _autoRecord = s?.autoRecord ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _nextDue,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) {
      setState(
          () => _nextDue = DateTime(picked.year, picked.month, picked.day));
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final amount = double.tryParse(_amount.text.trim());
    if (name.isEmpty) {
      _toastMsg('请填写名称');
      return;
    }
    if (amount == null || amount <= 0) {
      _toastMsg('请填写正确的金额');
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
        await session.api.updateSubscription(
          familyId,
          widget.existing!.id,
          name: name,
          emoji: _emoji,
          amount: amount,
          cycle: _cycle,
          nextDue: _nextDue,
          note: note,
          notifyEnabled: _notify,
          notifyDaysBefore: _notifyDaysBefore,
          autoRecord: _autoRecord,
        );
      } else {
        await session.api.createSubscription(
          familyId,
          name: name,
          emoji: _emoji,
          amount: amount,
          cycle: _cycle,
          nextDue: _nextDue,
          note: note.isEmpty ? null : note,
          notifyEnabled: _notify,
          notifyDaysBefore: _notifyDaysBefore,
          autoRecord: _autoRecord,
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

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: Text(_isEditing ? '编辑订阅' : '加订阅')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                              ? wo.subscribe.withValues(alpha: 0.30)
                              : wo.bgTint,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: sel ? wo.subscribe : Colors.transparent,
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
                controller: _name,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '比如「Netflix」「房租」「宽带」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              TextField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: '金额',
                  prefixText: '¥ ',
                  hintText: '每期扣费金额',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              Text('计费周期', style: t.titleSmall),
              const SizedBox(height: WoTokens.space2),
              Wrap(
                spacing: WoTokens.space2,
                children: [
                  ChoiceChip(
                    label: const Text('按月'),
                    selected: _cycle == 'monthly',
                    onSelected: (_) => setState(() => _cycle = 'monthly'),
                  ),
                  ChoiceChip(
                    label: const Text('按年'),
                    selected: _cycle == 'yearly',
                    onSelected: (_) => setState(() => _cycle = 'yearly'),
                  ),
                ],
              ),
              const SizedBox(height: WoTokens.space3),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.event, color: wo.subscribe),
                title: const Text('下次扣费日'),
                subtitle: Text(
                  '${_nextDue.year}年${_nextDue.month}月${_nextDue.day}日',
                  style: t.bodyMedium?.copyWith(color: wo.fgMid),
                ),
                trailing:
                    TextButton(onPressed: _pickDate, child: const Text('选择')),
                onTap: _pickDate,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoRecord,
                activeColor: wo.subscribe,
                title: const Text('到期自动记账'),
                subtitle: Text(
                  '到期当天把这笔扣费记进「记账」（需家庭已安装记账插件）',
                  style: t.labelSmall?.copyWith(color: wo.fgMid),
                ),
                onChanged: (v) => setState(() => _autoRecord = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _notify,
                activeColor: wo.subscribe,
                title: const Text('到期前提醒'),
                subtitle: Text(
                  _notify
                      ? (_notifyDaysBefore == 0
                          ? '当天提醒全家'
                          : '提前 $_notifyDaysBefore 天提醒全家')
                      : '开启后会在扣费前推送通知',
                  style: t.labelSmall?.copyWith(color: wo.fgMid),
                ),
                onChanged: (v) => setState(() => _notify = v),
              ),
              if (_notify)
                Row(
                  children: [
                    Text('提前', style: t.bodyMedium?.copyWith(color: wo.fgMid)),
                    Expanded(
                      child: Slider(
                        value: _notifyDaysBefore.toDouble(),
                        min: 0,
                        max: 14,
                        divisions: 14,
                        activeColor: wo.subscribe,
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
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _note,
                maxLength: 200,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  hintText: '账号、套餐、备注……',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              FilledButton(
                onPressed: _submitting ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: wo.subscribe,
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
