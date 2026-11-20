import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../data/api_client.dart';
import '../../../data/wo_session.dart';
import '../../../local/local_runtime.dart';
import '../../../local/local_store.dart';
import '../../../local/plugins/chat_routes.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/placeholder_screen.dart';
import 'chat_history_list.dart';
import 'chat_history_refresh.dart';

/// 本地家聊不经过旧远程 ChatSyncService 的账号/时间游标与图片上传流程。
class LocalChatPage extends StatefulWidget {
  const LocalChatPage({super.key});
  @override
  State<LocalChatPage> createState() => _LocalChatPageState();
}

class _LocalChatPageState extends State<LocalChatPage> with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  LocalRuntime? _runtime;
  ChatRoutes? _routes;
  WoSession? _session;
  String? _family, _owner;
  List<Json>? _items;
  List<Json> _statuses = [];
  Set<String>? _knownIds;
  bool _hasOlder = false, _loadingOlder = false, _hasNew = false, _sending = false, _authorized = false;
  String? _error;
  String? _pendingClient, _pendingText;
  int _generation = 0, _request = 0;
  static const _pageSize = 500;
  bool get _atBottom => !_scroll.hasClients || _scroll.position.pixels < 80;
  bool _current(String family, int generation) => mounted && family == _family &&
    generation == _generation && _session?.currentFamilyId == family &&
    _session?.user?.id == _owner;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _runtime = LocalRuntime.instance;
    if (_runtime != null) {
      _routes = ChatRoutes(_runtime!.store);
      _runtime!.changes.addListener(_changed);
    }
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = WoScope.of(context);
    if (!identical(session, _session)) {
      _session?.chatRefreshSignal.removeListener(_changed);
      _session = session; session.chatRefreshSignal.addListener(_changed);
    }
    if (_family != session.currentFamilyId || _owner != session.user?.id) {
      _generation++; _request++;
      _family = session.currentFamilyId; _owner = session.user?.id;
      _items = null; _knownIds = null; _statuses = [];
      _hasOlder = false; _loadingOlder = false; _hasNew = false; _authorized = false;
      _pendingClient = null; _pendingText = null; _text.clear(); _error = null;
      unawaited(_load(scroll: true));
    }
  }
  void _changed() { unawaited(_load()); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }
  int _startIndex(List<Json> rows, List<Json>? existing) {
    if (existing == null || existing.isEmpty) return math.max(0, rows.length - _pageSize);
    final positions = {for (var i = 0; i < rows.length; i++) rows[i]['id'] as String: i};
    final indexes = existing.map((row) => positions[row['id']]).whereType<int>().toList();
    return indexes.isEmpty ? math.max(0, rows.length - _pageSize) : indexes.reduce(math.min);
  }
  Future<void> _load({bool scroll = false}) async {
    final family = _family, routes = _routes, generation = _generation;
    if (family == null || routes == null || _loadingOlder) return;
    final request = ++_request;
    try {
      final rows = await routes.localSnapshot(family), statuses = await routes.statuses(family);
      if (!_current(family, generation) || request != _request) return;
      final previous = _items;
      final reading = !scroll && !_atBottom && previous != null && previous.isNotEmpty;
      final newcomer = _knownIds != null && rows.any((row) => !_knownIds!.contains(row['id']));
      final start = scroll ? math.max(0, rows.length - _pageSize) : _startIndex(rows, previous);
      final refresh = ChatHistoryRefresh<Json>(previous: previous ?? [], fresh: rows,
        id: (row) => row['id'] as String, readingHistory: reading);
      setState(() {
        _statuses = statuses; _knownIds = rows.map((row) => row['id'] as String).toSet();
        _items = reading ? refresh.items : rows.sublist(start);
        _hasOlder = _startIndex(rows, _items) > 0;
        _hasNew = reading ? _hasNew || newcomer : false;
        _error = null; _authorized = true;
      });
      if (scroll || !reading) _toBottom();
    } on ApiException catch (e) {
      if (_current(family, generation) && request == _request) setState(() {
        if (e.statusCode == 403) {
          _items = []; _statuses = []; _knownIds = null; _text.clear(); _authorized = false;
          _pendingClient = null; _pendingText = null; _hasNew = false; _hasOlder = false;
          _error = '当前家庭授权已失效，未展示旧家庭的聊天或待发送草稿';
        } else { _error = '本地聊天未能刷新，已保留现有记录'; }
      });
    } catch (_) {
      if (_current(family, generation) && request == _request) setState(() => _error = '本地聊天未能刷新，已保留现有记录');
    }
  }
  Future<void> _older() async {
    final family = _family, routes = _routes, previous = _items, generation = _generation;
    if (_loadingOlder || !_hasOlder || family == null || routes == null || previous == null) return;
    ++_request;
    setState(() => _loadingOlder = true);
    try {
      final rows = await routes.localSnapshot(family);
      if (!_current(family, generation)) return;
      final before = _startIndex(rows, previous), start = math.max(0, before - _pageSize);
      final byId = {for (final row in rows) row['id']: row};
      final seen = previous.map((row) => row['id']).toSet();
      setState(() {
        _items = [...rows.sublist(start, before).where((row) => seen.add(row['id'])),
          ...previous.map((row) => byId[row['id']] ?? row)];
        _hasOlder = start > 0;
      });
    } catch (_) {
      if (_current(family, generation)) _toast('更早的本地聊天未能加载，请重试');
    } finally {
      if (_current(family, generation)) { setState(() => _loadingOlder = false); unawaited(_load()); }
    }
  }
  void _toBottom() {
    final generation = _generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !_scroll.hasClients) return;
      unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic));
    });
  }
  void _toast(String value) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content: Text(value)));
  }
  Future<void> _send() async {
    final family = _family, routes = _routes, generation = _generation;
    final value = _text.text.trim();
    if (_sending || family == null || routes == null || value.isEmpty) return;
    if (value.runes.length > 2000) { _toast('每条聊天最多2000字'); return; }
    if (_pendingClient == null || _pendingText != value) {
      _pendingClient = const Uuid().v4(); _pendingText = value;
    }
    final client = _pendingClient!;
    setState(() => _sending = true);
    try {
      // 稳定client_id和原文先持久落盘；提交结果未知/进程退出后可显示显式重试行。
      await routes.stageText(family, clientId: client, body: value);
      _runtime?.changed();
      if (!_current(family, generation)) return;
      if (_text.text.trim() == value) _text.clear();
      _pendingClient = null; _pendingText = null;
      final commit = routes.commitPending(family, client);
      unawaited(_load(scroll: true));
      await commit;
    } on ApiException catch (e) { if (_current(family, generation)) _toast(e.message); }
    catch (_) { if (_current(family, generation)) _toast('尚未确认提交，已落盘的草稿可点按重试；输入框中未清除的原文请保留'); }
    finally {
      _runtime?.changed();
      if (mounted) setState(() => _sending = false);
      if (_current(family, generation)) await _load();
    }
  }
  Future<void> _retryPending(Json message) async {
    final family = _family, routes = _routes, generation = _generation;
    if (_sending || family == null || routes == null || message['local_pending'] != true) return;
    setState(() => _sending = true);
    try {
      // commitPending先查已提交回执，不会把未知结果当新消息再发。
      final commit = routes.commitPending(family, message['client_id'] as String);
      unawaited(_load()); await commit;
    } catch (_) { if (_current(family, generation)) _toast('尚未确认提交，保留本机待发送行供重试'); }
    finally {
      _runtime?.changed();
      if (mounted) setState(() => _sending = false);
      if (_current(family, generation)) await _load();
    }
  }
  Future<void> _discardPending(Json message) async {
    final family = _family, routes = _routes, generation = _generation;
    if (family == null || routes == null || message['local_pending'] != true || _sending) return;
    final yes = await showWoDialog<bool>(context: context, builder: (dialog) => WoAlertDialog(
      title: const Text('删除本机待发送草稿？'),
      content: const Text('只删除尚未提交的本机草稿。若消息已提交，必须改用本人撤回。'), actions: [
        WoTextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
        WoFilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('删除草稿')),
      ],
    ));
    if (yes != true || !_current(family, generation)) return;
    try {
      await routes.discardPending(family, message['client_id'] as String);
      _runtime?.changed(); await _load();
    } catch (_) { if (_current(family, generation)) _toast('草稿未能删除；若已提交，请刷新后使用撤回'); }
  }
  Future<void> _withdraw(Json message) async {
    final family = _family, routes = _routes, generation = _generation;
    if (family == null || routes == null || message['sender_id'] != _owner || message['retracted'] == true) return;
    final yes = await showWoDialog<bool>(context: context, builder: (dialog) => WoAlertDialog(
      title: const Text('撤回这条聊天？'),
      content: const Text('本机将显示撤回占位并同步删除标记。已读、截图、离线复制和既有归档中的内容无法自动收回。'),
      actions: [
        WoTextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
        WoFilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('撤回本人消息')),
      ],
    ));
    if (yes != true || !_current(family, generation)) return;
    try {
      await routes.request('DELETE', family, ['chat', 'messages', message['id'] as String]);
      _runtime?.changed(); await _load();
    } catch (_) { if (_current(family, generation)) _toast('撤回未完成，请重试'); }
  }
  Future<void> _status() async {
    final family = _family, routes = _routes, generation = _generation;
    if (family == null || routes == null) return;
    final own = _statuses.where((row) => row['created_by'] == _owner).firstOrNull;
    final emoji = TextEditingController(text: own?['emoji'] as String? ?? ''), text = TextEditingController(text: own?['text'] as String? ?? '');
    try {
      final yes = await showWoDialog<bool>(context: context, builder: (dialog) => WoAlertDialog(
        title: const Text('我的家聊状态'), content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: emoji, maxLength: 16, decoration: const InputDecoration(labelText: '状态emoji')),
          TextField(controller: text, maxLength: 80, decoration: const InputDecoration(labelText: '给家人看的状态（可留空清除）')),
        ]), actions: [
          WoTextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
          WoFilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('保存本机状态')),
        ],
      ));
      if (yes != true || !_current(family, generation)) return;
      await routes.request('PUT', family, ['chat', 'status'], body: {'emoji': emoji.text, 'text': text.text});
      _runtime?.changed(); await _load();
    } catch (_) { if (_current(family, generation)) _toast('状态未能保存，请重试'); }
    finally { emoji.dispose(); text.dispose(); }
  }
  Widget _message(Json message) {
    final mine = message['sender_id'] == _owner, withdrawn = message['retracted'] == true;
    final pending = message['local_pending'] == true, committing = message['delivery_status'] == 'committing_local';
    final avatar = MemberAvatar(url: message['sender_avatar_url'] as String?, emoji: message['sender_emoji'] as String? ?? '👤', size: 32);
    final bubble = Flexible(child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
      if (!mine) Text(message['sender_name'] as String? ?? '', style: Theme.of(context).textTheme.labelSmall),
      GestureDetector(
        onTap: pending && !committing ? () => unawaited(_retryPending(message)) : null,
        onLongPress: mine && !withdrawn ? () => unawaited(pending ? _discardPending(message) : _withdraw(message)) : null,
        child: Container(constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: WoTokens.space3, vertical: WoTokens.space2),
          decoration: BoxDecoration(color: mine ? context.wo.accentSoft : context.wo.bgTint,
            borderRadius: BorderRadius.circular(18), border: Border.all(color: context.wo.hairline)),
          child: Text(withdrawn ? '此消息已撤回' : message['body'] as String? ?? '',
            style: TextStyle(color: withdrawn ? context.wo.fgDim : context.wo.fg, fontStyle: withdrawn ? FontStyle.italic : FontStyle.normal)),
        )),
      if (mine && !withdrawn) Text(pending ? (committing ? '正在提交本机' : '本机待发送 · 点按重试') : '已保存本机',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: pending && !committing ? context.wo.danger : context.wo.fgDim)),
    ]));
    return Padding(padding: const EdgeInsets.only(bottom: WoTokens.space3), child: Row(
      crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: mine ? [bubble, const SizedBox(width: WoTokens.space2), avatar] : [avatar, const SizedBox(width: WoTokens.space2), bubble],
    ));
  }
  Widget _body() {
    final items = _items;
    if (_family == null) return const PlaceholderScreen(emoji: '💬', title: '家聊', description: '请先加入或创建一个家庭。');
    if (_routes == null) return const PlaceholderScreen(emoji: '💬', title: '本地聊天尚未就绪', description: '现有资料保留在本机，未切换到远端服务。');
    if (items == null) return Center(child: _error == null ? const WoProgressIndicator() :
      Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!), WoTextButton(onPressed: () => unawaited(_load(scroll: true)), child: const Text('重试'))]));
    if (items.isEmpty) return const PlaceholderScreen(emoji: '💬', title: '还没有聊天', description: '说第一句话吧，消息先保存在本机。');
    return ChatHistoryList<Json>(items: items, controller: _scroll, hasOlder: _hasOlder,
      loadingOlder: _loadingOlder, onLoadOlder: () => unawaited(_older()),
      itemKey: (message) => ValueKey(message['id']), itemBuilder: _message,
      padding: const EdgeInsets.all(WoTokens.space4));
  }
  @override
  Widget build(BuildContext context) => WoScaffold(
    appBar: WoAppBar(title: const Text('家聊'), actions: [WoTextButton(onPressed: _family == null || !_authorized ? null : () => unawaited(_status()), child: const Text('我的状态'))]),
    body: SafeArea(child: Column(children: [
      SizedBox(height: 38, child: ListView(scrollDirection: Axis.horizontal, children: [
        const Padding(padding: EdgeInsets.symmetric(horizontal: WoTokens.space3, vertical: 8), child: Text('本机保存 · 前台局域网同步')),
        for (final status in _statuses) if ('${status['emoji'] ?? ''}${status['text'] ?? ''}'.isNotEmpty)
          Padding(padding: const EdgeInsets.only(right: WoTokens.space3), child: Row(mainAxisSize: MainAxisSize.min, children: [
            MemberAvatar(url: status['sender_avatar_url'] as String?, emoji: status['sender_emoji'] as String? ?? '👤'),
            Text(' ${status['sender_name']} ${status['emoji'] ?? ''} ${status['text'] ?? ''}'),
          ])),
      ])),
      Expanded(child: Stack(children: [Positioned.fill(child: _body()),
        if (_hasNew) Positioned(left: 0, right: 0, bottom: 8, child: Center(child: WoFilledButton(
          onPressed: () => unawaited(_load(scroll: true)), child: const Text('查看新消息或补录')))),
      ])),
      if (_error != null && _items != null) Text(_error!, style: Theme.of(context).textTheme.labelSmall),
      DecoratedBox(decoration: BoxDecoration(color: context.wo.bg, border: Border(top: BorderSide(color: context.wo.hairline))),
        child: Padding(padding: const EdgeInsets.all(WoTokens.space3), child: Row(children: [
          WoIconButton(tooltip: '聊天附件暂未接入', onPressed: () => _toast('本地聊天图片和文件附件尚未接入；未向远端上传原件'), icon: const Icon(Icons.attach_file)),
          Expanded(child: TextField(controller: _text, enabled: _authorized, minLines: 1, maxLines: 5, maxLength: 2000,
            decoration: const InputDecoration(hintText: '给家人说句话', counterText: ''), textInputAction: TextInputAction.newline)),
          WoIconButton(tooltip: '保存消息', onPressed: _sending || !_authorized || _routes == null || _family == null ? null : () => unawaited(_send()), icon: Icon(_sending ? Icons.hourglass_empty : Icons.send)),
        ]))),
    ])),
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); _runtime?.changes.removeListener(_changed);
    _session?.chatRefreshSignal.removeListener(_changed); _text.dispose(); _scroll.dispose();
    super.dispose();
  }
}
