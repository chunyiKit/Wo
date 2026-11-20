import 'dart:async';
import 'package:flutter/material.dart';
import '../../../widgets/wo_cinema.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import '../../../widgets/member_avatar.dart';
import '../retirement/finance_ui_support.dart';
import '../accounting/accounting_category_dialog.dart';
import '../accounting/accounting_page.dart';

String _money(double v) =>
    v == v.roundToDouble() ? '¥${v.toInt()}' : '¥${v.toStringAsFixed(2)}';

String _cycleLabel(String cycle) => cycle == 'yearly' ? '年' : '月';

/// 订阅管家首页：列出订阅 / 定期账单，显示金额、周期、下次扣费倒计时。
class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> with FinanceLocalRefresh<SubscriptionPage> {
  // `_future` 只驱动首屏 spinner;数据缓存进 `_items`,之后的增删改静默就地替换,
  // 不闪——见 CLAUDE.md「列表页刷新不能闪一下」。
  late Future<List<Subscription>> _future;
  List<Subscription>? _items;
  bool _loaded = false;
  String? _familyId;
  int _ticket = 0;
  bool _refreshing = false, _again = false, _home = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = WoScope.of(context);
    bindFinanceChanges(session.api.isLocal);
    if (!_loaded || _familyId != session.currentFamilyId) {
      _loaded = true; _familyId = session.currentFamilyId; _items = null;
      _future = _initialFetch();
    }
  }
  @override
  void onFinanceChanged() { unawaited(_refreshSilently(notifyHome: false)); }
  Future<List<Subscription>> _initialFetch() {
    final ticket = ++_ticket; final family = _familyId;
    return _fetch().then((rows) { if (mounted && ticket == _ticket && family == _familyId) setState(() => _items = rows); return rows; });
  }

  Future<List<Subscription>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <Subscription>[])
        : session.api.subscriptions(familyId);
  }

  Future<void> _retry() {
    setState(() { _items = null; _future = _initialFetch(); }); return _future;
  }
  Future<void> _refreshSilently({bool notifyHome = true}) async {
    _home = _home || notifyHome;
    if (_refreshing) { _again = true; return; }
    _refreshing = true;
    try {
      do {
        _again = false;
        final ticket = ++_ticket; final family = _familyId;
        try { final rows = await _fetch(); if (mounted && ticket == _ticket && family == _familyId) setState(() => _items = rows); } catch (_) { /* 保留缓存 */ }
      } while (mounted && _again);
      if (mounted && _home) { _home = false;  try { await WoScope.of(context).refresh(); } catch (_) {} }
    } finally { _refreshing = false; if (mounted && _again) unawaited(_refreshSilently(notifyHome: false)); }
  }

  Future<void> _openEditor([Subscription? existing, bool confirmBilling = false]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SubscriptionEditPage(existing: existing, confirmBilling: confirmBilling),
      ),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _togglePause(Subscription s) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    if (s.billingConflict && !s.active && session.api.isLocal) { await _openEditor(s, true); return; }
    try {
      await session.api.updateSubscription(familyId, s.id, active: !s.active);
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _delete(Subscription s) async {
    final confirmed = await showWoDialog<bool>(
      context: context,
      builder: (ctx) => WoAlertDialog(
        title: const Text('删除订阅'),
        content: Text('确定删除「${s.name}」吗？'),
        actions: [
          WoTextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          WoTextButton(
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
      FormatException e => e.message,
      NetworkException e => e.message,
      _ => '操作失败',
    };
    ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return WoScaffold(
      backgroundColor: wo.bg,
      appBar: WoAppBar(title: const Text('订阅管家')),
      floatingActionButton: WoFloatingActionButton.extended(
        onPressed: () => _openEditor(),
        backgroundColor: wo.subscribe,
        foregroundColor: wo.fg,
        icon: const Icon(Icons.add),
        label: const Text('加订阅'),
      ),
      body: SafeArea(
        child: Column(children: [
          if (WoScope.api(context).isLocal) const LocalFinanceStatus(),
          Expanded(child: _items != null ? _buildBody(context, _items!) : AsyncView<List<Subscription>>(
            future: _future, onRetry: _retry, builder: _buildBody)),
        ]),
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
          key: ValueKey(list[i].id), sub: list[i],
          onReview: WoScope.api(context).isLocal ? () => _openEditor(list[i], true) : null,
          onEdit: () => _openEditor(list[i]),
          onTogglePause: () => _togglePause(list[i]),
          onDelete: () => _delete(list[i]),
        ),
      ),
    );
  }
}

class _SubTile extends StatelessWidget {
  const _SubTile({super.key, required this.sub, required this.onEdit,
    required this.onTogglePause, required this.onDelete, this.onReview});
  final Subscription sub;
  final VoidCallback onEdit, onTogglePause, onDelete;
  final VoidCallback? onReview;
  ({String text, Color? tone}) _due(BuildContext context) {
    final wo = context.wo;
    if (sub.billingConflict) return (text: '账期待核对', tone: wo.warning);
    if (!sub.active) return (text: '已暂停', tone: wo.fgDim);
    final local = WoScope.api(context).isLocal;
    final action = local ? '到期' : '扣费';
    if (sub.daysUntil < 0) return (text: local ? '已到期，待前台处理' : '已过期待扣费', tone: wo.danger);
    if (sub.daysUntil == 0) return (text: '今天$action', tone: wo.warning);
    if (sub.daysUntil == 1) return (text: '明天$action', tone: wo.warning);
    return (text: '${sub.daysUntil} 天后$action', tone: sub.daysUntil <= 3 ? wo.warning : null);
  }
  @override
  Widget build(BuildContext context) {
    final wo = context.wo; final t = Theme.of(context).textTheme; final due = _due(context);
    return WoCard(onTap: onEdit, child: Opacity(opacity: !sub.active && !sub.billingConflict ? 0.55 : 1,
      child: Row(children: [Text(sub.emoji, style: const TextStyle(fontSize: 26)),
        const SizedBox(width: WoTokens.space3), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(sub.name, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Wrap(spacing: WoTokens.space2, children: [
            Text('${sub.amountText == null ? _money(sub.amount) : '¥${sub.amountText}'} / ${_cycleLabel(sub.cycle)}', style: t.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text(due.text, style: t.labelSmall?.copyWith(color: due.tone ?? wo.fgMid)),
          ]),
          if (sub.billingConflict) ...[
            Text('同一期记账记录不一致，请先核对已有账单与下次到期日。', style: t.labelSmall?.copyWith(color: wo.warning)),
            if (onReview != null) WoTextButton(onPressed: onReview, child: const Text('核对并确认账期')),
          ] else if (sub.autoRecord) Text(WoScope.api(context).isLocal ? '前台处理到期记账' : '到期自动记账', style: t.labelSmall?.copyWith(color: wo.subscribe)),
          if (sub.createdBy != null) ...[
            const SizedBox(height: 4), Row(children: [MemberAvatar(url: sub.creatorAvatarUrl, emoji: sub.creatorEmoji ?? '👤', size: 16),
              const SizedBox(width: 4), Expanded(child: Text(sub.creatorName ?? '家庭成员', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.labelSmall?.copyWith(color: wo.fgDim)))]),
          ],
        ])),
        PopupMenuButton<String>(icon: Icon(Icons.more_vert, color: wo.fgDim),
          onSelected: (value) { if (value == 'edit') onEdit(); if (value == 'pause') onTogglePause(); if (value == 'delete') onDelete(); },
          itemBuilder: (_) => [const PopupMenuItem(value: 'edit', child: Text('编辑')),
            PopupMenuItem(value: 'pause', child: Text(sub.active ? '暂停' : '启用')),
            const PopupMenuItem(value: 'delete', child: Text('删除'))]),
      ])));
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
            const WoEmptyMark(icon: Icons.credit_card_outlined),
            const SizedBox(height: WoTokens.space4),
            Text('还没有订阅', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把视频会员、云盘、房租这些定期账单记下来，到期自动提醒，还能自动记账。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            WoFilledButton(onPressed: onAdd, child: const Text('加第一个订阅')),
          ],
        ),
      ),
    );
  }
}

/// 订阅新增 / 编辑页。[existing] 为空 = 新增；非空 = 编辑。保存成功 `pop(true)`。
class SubscriptionEditPage extends StatefulWidget {
  const SubscriptionEditPage({super.key, this.existing, this.confirmBilling = false});

  final Subscription? existing;
  final bool confirmBilling;

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
  String _accountingCategory = 'subscription';
  bool _excludeFromBudget = false;
  List<ExpenseCategory>? _categories;
  bool _categoriesRequested = false;
  bool _loadingCategories = false;
  String? _categoryError;
  bool _submitting = false;
  bool _reviewRequired = false, _reviewChecked = false;
  final _requestKey = FinanceRequestKey();
  String? _reviewFrontier, _latestBillNote;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _reviewFrontier = s?.conflictFrontier;
    _reviewRequired = widget.confirmBilling || s?.billingConflict == true;
    _emoji = s?.emoji ?? '💳';
    _name = TextEditingController(text: s?.name ?? '');
    _amount = TextEditingController(
      text: s == null ? '' : (s.amountText ?? _money(s.amount).replaceFirst('¥', '')),
    );
    _note = TextEditingController(text: s?.note ?? '');
    _cycle = s?.cycle ?? 'monthly';
    _nextDue = s?.nextDue ?? DateTime.now();
    _notify = s?.notifyEnabled ?? true;
    _notifyDaysBefore = s?.notifyDaysBefore ?? 3;
    _autoRecord = s?.autoRecord ?? true;
    _accountingCategory = s?.accountingCategory ?? 'subscription';
    _excludeFromBudget = s?.excludeFromBudget ?? false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_categoriesRequested) {
      _categoriesRequested = true;
      _loadCategories();
    }
  }

  Future<void> _loadCategories() async {
    if (_loadingCategories) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    setState(() {
      _loadingCategories = true;
      _categoryError = null;
    });
    try {
      final categories = await session.api.accountingCategories(familyId);
      if (mounted) setState(() => _categories = categories);
    } catch (_) {
      if (mounted) setState(() => _categoryError = '分类加载失败，已保留当前设置');
    } finally {
      if (mounted) setState(() => _loadingCategories = false);
    }
  }

  Future<void> _addCategory() async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    final categories = _categories;
    if (familyId == null || categories == null) return;
    final category = await showWoDialog<ExpenseCategory>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AccountingCategoryDialog(
        api: session.api,
        familyId: familyId,
        categories: categories,
      ),
    );
    if (category != null && mounted) {
      setState(() {
        _categories = [...categories, category];
        _accountingCategory = category.code;
      });
    }
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
      useRootNavigator: false,
      initialDate: _nextDue,
      firstDate: _nextDue.isBefore(DateTime(now.year - 1)) ? DateTime(_nextDue.year, 1, 1) : DateTime(now.year - 1),
      lastDate: _nextDue.isAfter(DateTime(now.year + 5)) ? DateTime(_nextDue.year + 1, 1, 1) : DateTime(now.year + 5),
    );
    if (picked != null) {
      setState(
        () => _nextDue = DateTime(picked.year, picked.month, picked.day),
      );
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    String amountText;
    try { amountText = financeAmount(_amount.text, subscription: true); }
    on FormatException catch (error) { _toast(error); return; }
    final amount = double.parse(amountText);
    if (name.isEmpty) {
      _toastMsg('请填写名称');
      return;
    }
    if (amount <= 0) {
      _toastMsg('请填写正确的金额');
      return;
    }
    if (_submitting) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final note = _note.text.trim();
    final nav = Navigator.of(context);
    setState(() => _submitting = true);
    try {
      String? expectedFrontier;
      if (session.api.isLocal && _isEditing) {
        final latest = (await session.api.subscriptions(familyId)).where((item) => item.id == widget.existing!.id).toList();
        if (latest.isEmpty) throw ApiException('NOT_FOUND', '订阅已删除，请返回列表', statusCode: 404);
        expectedFrontier = latest.single.conflictFrontier;
        if (_reviewRequired && expectedFrontier != null && expectedFrontier != _reviewFrontier) {
          if (mounted) {
            setState(() { _reviewFrontier = expectedFrontier; _reviewChecked = false; _submitting = false;
              _latestBillNote = '当前到期日 ${latest.single.nextDue.year}-${latest.single.nextDue.month}-${latest.single.nextDue.day}，每期 ¥${latest.single.amountText ?? latest.single.amount.toStringAsFixed(2)}'; });
            _toastMsg('账期或关联账目已变化，请重新查看并勾选确认');
          }
          return;
        }
        if (latest.single.billingConflict && !_reviewRequired) {
          if (mounted) setState(() { _reviewRequired = true; _reviewChecked = false; _submitting = false;
            _reviewFrontier = expectedFrontier;
            _latestBillNote = '当前到期日 ${latest.single.nextDue.year}-${latest.single.nextDue.month}-${latest.single.nextDue.day}，每期 ¥${latest.single.amountText ?? latest.single.amount.toStringAsFixed(2)}'; });
          if (mounted) _toastMsg('账期有新差异，请先核对已有账目'); return;
        }
      }
      final review = session.api.isLocal && _reviewRequired;
      if (review) {
        if (expectedFrontier == null) throw ApiException('LOCAL_FINANCIAL_CONFLICT', '请重新读取完整账期记录后确认', statusCode: 409);
        if (!_reviewChecked) { setState(() => _submitting = false); _toastMsg('请先核对已有账目并明确确认下次日期'); return; }
        final confirmed = await showWoDialog<bool>(context: context, builder: (ctx) => WoAlertDialog(
          title: const Text('确认订阅账期'),
          content: Text('已核对「$name」的已有账目，并确认下次到期日为 ${_nextDue.year}-${_nextDue.month}-${_nextDue.day}，每期金额 ¥$amountText。已有账目保留，历史差异请在记账页更正。'),
          actions: [WoTextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('继续核对')),
            WoFilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('确认账期'))]));
        if (confirmed != true || !mounted) { if (mounted) setState(() => _submitting = false); return; }
      }
      final clientId = session.api.isLocal ? _requestKey.forBody([familyId, widget.existing?.id, name, _emoji, amountText, _cycle,
        _nextDue.toIso8601String(), note, _notify, _notifyDaysBefore, _autoRecord, _accountingCategory, _excludeFromBudget, review, expectedFrontier]) : null;
      if (_isEditing) {
        await session.api.updateSubscription(
          familyId,
          widget.existing!.id,
          name: name,
          emoji: _emoji,
          amount: amount, amountText: amountText, clientId: clientId,
          cycle: _cycle,
          nextDue: _nextDue,
          note: note,
          notifyEnabled: _notify,
          notifyDaysBefore: _notifyDaysBefore,
          autoRecord: _autoRecord,
          accountingCategory: _accountingCategory,
          excludeFromBudget: _excludeFromBudget, confirmBilling: review, expectedConflictFrontier: expectedFrontier,
        );
      } else {
        await session.api.createSubscription(
          familyId,
          name: name,
          emoji: _emoji,
          amount: amount, amountText: amountText, clientId: clientId,
          cycle: _cycle,
          nextDue: _nextDue,
          note: note.isEmpty ? null : note,
          notifyEnabled: _notify,
          notifyDaysBefore: _notifyDaysBefore,
          autoRecord: _autoRecord,
          accountingCategory: _accountingCategory,
          excludeFromBudget: _excludeFromBudget,
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

  void _toastMsg(String msg) => ScaffoldMessenger.of(
        context,
      ).showSnackBar(WoSnackBar(content: Text(msg)));

  void _toast(Object error) {
    final msg = switch (error) {
      ApiException e => e.message,
      FormatException e => e.message,
      NetworkException e => e.message,
      _ => '操作失败',
    };
    _toastMsg(msg);
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return WoScaffold(
      backgroundColor: wo.bg,
      appBar: WoAppBar(title: Text(_isEditing ? '编辑订阅' : '加订阅')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_reviewRequired && WoScope.api(context).isLocal) ...[
                Text('账期记录存在差异，请先核对已有账目；确认后才恢复后续自动记账。', style: t.bodyMedium?.copyWith(color: wo.warning)),
                if (_latestBillNote != null) Text(_latestBillNote!, style: t.bodyMedium?.copyWith(color: wo.warning)),
                WoTextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountingPage())), child: const Text('查看已有账目')),
                CheckboxListTile(contentPadding: EdgeInsets.zero, value: _reviewChecked,
                  onChanged: _submitting ? null : (value) => setState(() => _reviewChecked = value ?? false),
                  title: const Text('我已核对已有账目，并确认下次到期日与每期金额')),
                const SizedBox(height: WoTokens.space3),
              ],
              if (WoScope.api(context).isLocal) const LocalFinanceStatus(),
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
              WoTextField(
                controller: _name,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '比如「Netflix」「房租」「宽带」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              WoTextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
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
                  WoChoiceChip(
                    label: const Text('按月'),
                    selected: _cycle == 'monthly',
                    onSelected: (_) => setState(() => _cycle = 'monthly'),
                  ),
                  WoChoiceChip(
                    label: const Text('按年'),
                    selected: _cycle == 'yearly',
                    onSelected: (_) => setState(() => _cycle = 'yearly'),
                  ),
                ],
              ),
              const SizedBox(height: WoTokens.space3),
              WoListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.event, color: wo.subscribe),
                title: const Text('下次扣费日'),
                subtitle: Text(
                  '${_nextDue.year}年${_nextDue.month}月${_nextDue.day}日',
                  style: t.bodyMedium?.copyWith(color: wo.fgMid),
                ),
                trailing: WoTextButton(
                  onPressed: _pickDate,
                  child: const Text('选择'),
                ),
                onTap: _pickDate,
              ),
              WoSwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoRecord,
                activeColor: wo.subscribe,
                title: const Text('到期自动记账'),
                subtitle: Text(
                  WoScope.api(context).isLocal ? '打开 App 时处理到期记账（需已安装记账插件）' : '到期当天把这笔扣费记进「记账」（需家庭已安装记账插件）',
                  style: t.labelSmall?.copyWith(color: wo.fgMid),
                ),
                onChanged: (v) => setState(() => _autoRecord = v),
              ),
              if (_autoRecord) ...[
                const SizedBox(height: WoTokens.space3),
                if (_categories != null) ...[
                  WoDropdownButtonFormField<String>(
                    key: ValueKey('accounting-category-$_accountingCategory'),
                    value:
                        _categories!.any((c) => c.code == _accountingCategory)
                            ? _accountingCategory
                            : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '账单分类'),
                    items: [
                      for (final category in _categories!)
                        DropdownMenuItem(
                          value: category.code,
                          child: Text(
                            '${category.emoji} ${category.label}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _submitting
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => _accountingCategory = value);
                            }
                          },
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: WoTextButton.icon(
                      onPressed: _submitting ? null : _addCategory,
                      icon: const Icon(Icons.add),
                      label: const Text('新增分类'),
                    ),
                  ),
                ] else if (_loadingCategories)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: WoTokens.space3),
                    child: Text('正在加载账单分类…'),
                  ),
                if (_categoryError != null)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _categoryError!,
                          style: TextStyle(color: wo.fgMid),
                        ),
                      ),
                      WoTextButton(
                        onPressed: _loadCategories,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                WoSwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: !_excludeFromBudget,
                  activeColor: wo.subscribe,
                  title: const Text('计入月预算'),
                  subtitle: Text(
                    _excludeFromBudget ? '仍计入本月支出，但不扣减预算' : '自动生成的账单会扣减当月预算',
                    style: t.labelSmall?.copyWith(color: wo.fgMid),
                  ),
                  onChanged: _submitting
                      ? null
                      : (value) => setState(() => _excludeFromBudget = !value),
                ),
                Text(
                  '修改仅影响之后自动生成的账单。',
                  style: t.labelSmall?.copyWith(color: wo.fgMid),
                ),
                const SizedBox(height: WoTokens.space3),
              ],
              WoSwitchListTile(
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
                      child: WoSlider(
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
              WoTextField(
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
              WoFilledButton(
                onPressed: _submitting ? null : _save,
                style: WoFilledButton.styleFrom(
                  backgroundColor: wo.subscribe,
                  foregroundColor: wo.fg,
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: WoProgressIndicator(strokeWidth: 2),
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
