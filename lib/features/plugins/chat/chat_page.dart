import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../data/api_client.dart';
import '../../../data/chat_local_store.dart';
import '../../../data/chat_message_query.dart';
import '../../../data/chat_sync_service.dart';
import '../../../data/image_pick.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/placeholder_screen.dart';
import 'chat_history_list.dart';
import 'chat_history_refresh.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final _store = ChatLocalStore.instance;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  ChatSyncService? _syncService;
  List<ChatLocalMessage>? _items;
  Timer? _poller;
  String? _scopeKey;
  WoSession? _session;
  final _syncingScopes = <String>{};
  bool _sendingImage = false;
  static const _pageSize = 500;
  int _scopeGeneration = 0;
  int _loadRequest = 0;
  bool _hasOlder = false;
  bool _loadingOlder = false;
  bool _hasNewMessages = false;

  bool _isScope(String owner, String family, int generation) =>
      _isCurrentScope(owner, family) &&
      generation == _scopeGeneration &&
      owner == _ownerUserId &&
      family == _familyId;

  bool get _atBottom =>
      !_scrollController.hasClients || _scrollController.position.pixels < 80;

  ChatMessageCursor _cursor(ChatLocalMessage message) => ChatMessageCursor(
    message.createdAt.toUtc().toIso8601String(),
    message.localId!,
  );

  ChatMessageCursor _oldestCursor(List<ChatLocalMessage> messages) => _cursor(
    messages.reduce((a, b) {
      final order = a.createdAt.compareTo(b.createdAt);
      return order < 0 || (order == 0 && a.localId! < b.localId!) ? a : b;
    }),
  );

  String? _ownerUserId;
  String? _familyId;
  String _myName = '';
  String _myEmoji = '👤';
  String? _myAvatarUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncSilently());
    }
  }

  bool _isCurrentScope(String owner, String family) =>
      mounted &&
      _session?.user?.id == owner &&
      _session?.currentFamilyId == family;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final session = WoScope.of(context);
    if (!identical(_session, session)) {
      _syncService = ChatSyncService(api: session.api, store: _store);
      _session?.chatRefreshSignal.removeListener(_onExternalRefresh);
      _session = session;
      session.chatRefreshSignal.addListener(_onExternalRefresh);
    }

    final owner = session.user?.id;
    final family = session.currentFamilyId;
    if (owner == null || family == null) {
      _scopeGeneration++;
      _loadRequest++;
      _poller?.cancel();
      _scopeKey = null;
      _ownerUserId = null;
      _familyId = null;
      _items = null;
      return;
    }
    final nextKey = '$owner|$family';
    if (nextKey != _scopeKey) {
      _scopeGeneration++;
      _loadRequest++;
      _poller?.cancel();
      _items = null;
      _hasOlder = false;
      _loadingOlder = false;
      _hasNewMessages = false;
      _scopeKey = nextKey;
      _ownerUserId = owner;
      _familyId = family;
      _myName = session.user?.displayName ?? '';
      _myEmoji = session.user?.avatarEmoji ?? '👤';
      _myAvatarUrl = session.user?.avatarUrl;
      if (owner != null && family != null) {
        _start(ownerUserId: owner, familyId: family);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poller?.cancel();
    _session?.chatRefreshSignal.removeListener(_onExternalRefresh);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onExternalRefresh() {
    unawaited(_syncSilently());
  }

  Future<void> _start({
    required String ownerUserId,
    required String familyId,
  }) async {
    final generation = _scopeGeneration;
    _poller?.cancel();
    setState(() => _items = null);
    await Future.wait([
      _loadLocal(ownerUserId: ownerUserId, familyId: familyId, scroll: true),
      _loadMyMember(familyId),
    ]);
    if (!_isScope(ownerUserId, familyId, generation)) return;
    await _syncSilently();
    if (!_isScope(ownerUserId, familyId, generation)) return;
    _poller = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_syncSilently()),
    );
  }

  Future<void> _loadMyMember(String familyId) async {
    final owner = _ownerUserId;
    final generation = _scopeGeneration;
    if (owner == null) return;
    try {
      final members = await WoScope.api(context).members(familyId);
      Member? mine;
      for (final member in members) {
        if (member.userId == owner) {
          mine = member;
          break;
        }
      }
      final currentMember = mine;
      if (currentMember != null && _isScope(owner, familyId, generation)) {
        setState(() {
          _myName = currentMember.displayName;
          _myEmoji = currentMember.avatarEmoji;
          _myAvatarUrl = currentMember.avatarUrl;
        });
      }
    } catch (_) {
      // 用全局用户资料作为兜底。
    }
  }

  Future<void> _loadLocal({
    required String ownerUserId,
    required String familyId,
    bool scroll = false,
  }) async {
    if (ownerUserId != _ownerUserId || familyId != _familyId || _loadingOlder)
      return;
    final generation = _scopeGeneration;
    final request = ++_loadRequest;
    final previous = _items;
    final from = previous != null && previous.isNotEmpty
        ? _oldestCursor(previous)
        : null;
    final rows = await _store.listMessages(
      ownerUserId: ownerUserId,
      familyId: familyId,
      from: from,
      retainedLocalIds: previous?.map((m) => m.localId!).toList() ?? const [],
      // 后续只刷新已经展开的时间范围，避免新消息挤掉已加载的历史。
      limit: from == null ? _pageSize + 1 : null,
    );
    if (!_isScope(ownerUserId, familyId, generation) || request != _loadRequest)
      return;
    final readingHistory =
        !scroll && !_atBottom && previous != null && previous.isNotEmpty;
    final refresh = ChatHistoryRefresh<ChatLocalMessage>(
      previous: previous ?? const [],
      fresh: from == null && rows.length > _pageSize ? rows.sublist(1) : rows,
      id: (message) => message.localId!,
      readingHistory: readingHistory,
    );
    // 每次都重新探测：首次同步可能回填到原窗口之前，旧的 false 会过期。
    final older = refresh.items.isEmpty
        ? <ChatLocalMessage>[]
        : await _store.listMessages(
            ownerUserId: ownerUserId,
            familyId: familyId,
            before: _oldestCursor(refresh.items),
            limit: 1,
          );
    if (!_isScope(ownerUserId, familyId, generation) || request != _loadRequest)
      return;
    setState(() {
      _hasOlder = older.isNotEmpty;
      _items = refresh.items;
      _hasNewMessages = refresh.hasNewMessages;
    });
    if (scroll || _atBottom) _scrollToBottom();
  }

  Future<void> _loadOlder() async {
    final owner = _ownerUserId;
    final family = _familyId;
    final items = _items;
    if (_loadingOlder ||
        !_hasOlder ||
        owner == null ||
        family == null ||
        items == null ||
        items.isEmpty)
      return;
    final generation = _scopeGeneration;
    ++_loadRequest;
    setState(() => _loadingOlder = true);
    try {
      final older = await _store.listMessages(
        ownerUserId: owner,
        familyId: family,
        before: _oldestCursor(items),
        limit: _pageSize + 1,
      );
      if (!_isScope(owner, family, generation)) return;
      setState(() {
        _hasOlder = older.length > _pageSize;
        final page = _hasOlder ? older.sublist(1) : older;
        final seen = items.map((m) => m.localId).toSet();
        _items = [...page.where((m) => seen.add(m.localId)), ...items];
      });
    } catch (_) {
      if (_isScope(owner, family, generation)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const WoSnackBar(content: Text('加载历史失败，请重试')));
      }
    } finally {
      if (_isScope(owner, family, generation)) {
        setState(() => _loadingOlder = false);
      }
    }
  }

  Future<void> _syncSilently({bool scroll = false}) async {
    final owner = _ownerUserId;
    final family = _familyId;
    final service = _syncService;
    if (owner == null || family == null || service == null) return;
    final generation = _scopeGeneration;
    final scope = '$owner|$family';
    if (!_isCurrentScope(owner, family) || !_syncingScopes.add(scope)) return;
    try {
      await service.sync(
        ownerUserId: owner,
        familyId: family,
        isCurrentScope: () => _isScope(owner, family, generation),
      );
    } catch (_) {
      // 保留本地历史，不用网络错误打断聊天。
    } finally {
      _syncingScopes.remove(scope);
      // 网络失败时也显示恢复后的可重试状态。
      if (_isScope(owner, family, generation)) {
        await _loadLocal(ownerUserId: owner, familyId: family, scroll: scroll);
      }
    }
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    final owner = _ownerUserId;
    final family = _familyId;
    final service = _syncService;
    if (owner == null || family == null || service == null) return;

    final generation = _scopeGeneration;
    _textController.clear();
    final local = await _store.insertOutgoingText(
      ownerUserId: owner,
      familyId: family,
      clientId: const Uuid().v4(),
      senderName: _myName.isEmpty ? '我' : _myName,
      senderEmoji: _myEmoji,
      senderAvatarUrl: _myAvatarUrl,
      body: text,
    );
    if (!_isScope(owner, family, generation)) return;
    await _loadLocal(ownerUserId: owner, familyId: family, scroll: true);
    await _sendLocal(service, local, generation);
  }

  Future<void> _pickAndSendImage() async {
    if (_sendingImage) return;
    final owner = _ownerUserId;
    final family = _familyId;
    final service = _syncService;
    if (owner == null || family == null || service == null) return;

    final generation = _scopeGeneration;
    _sendingImage = true;
    try {
      final bytes = await pickAndCompressImage(maxEdge: 1600, quality: 86);
      if (bytes == null || !_isScope(owner, family, generation)) return;
      final clientId = const Uuid().v4();
      final path = await _store.writeImageBytes(
        ownerUserId: owner,
        familyId: family,
        key: clientId,
        bytes: Uint8List.fromList(bytes),
      );
      if (!_isScope(owner, family, generation)) return;
      final local = await _store.insertOutgoingImage(
        ownerUserId: owner,
        familyId: family,
        clientId: clientId,
        senderName: _myName.isEmpty ? '我' : _myName,
        senderEmoji: _myEmoji,
        senderAvatarUrl: _myAvatarUrl,
        imageLocalPath: path,
        imageSizeBytes: bytes.length,
      );
      if (!_isScope(owner, family, generation)) return;
      await _loadLocal(ownerUserId: owner, familyId: family, scroll: true);
      await _sendLocal(service, local, generation);
    } finally {
      _sendingImage = false;
    }
  }

  Future<void> _retry(ChatLocalMessage message) async {
    final service = _syncService;
    final owner = _ownerUserId;
    final family = _familyId;
    if (service == null || owner == null || family == null) return;
    await _sendLocal(service, message, _scopeGeneration);
  }

  Future<void> _sendLocal(
    ChatSyncService service,
    ChatLocalMessage message,
    int generation,
  ) async {
    final owner = message.ownerUserId;
    final family = message.familyId;
    try {
      await service.sendPending(
        message,
        isCurrentScope: () => _isScope(owner, family, generation),
      );
    } catch (e) {
      if (_isScope(owner, family, generation)) _toast(e);
    } finally {
      if (_isScope(owner, family, generation)) {
        await _loadLocal(ownerUserId: owner, familyId: family);
      }
    }
  }

  void _scrollToBottom() {
    final generation = _scopeGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          generation != _scopeGeneration ||
          !_scrollController.hasClients)
        return;
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _toast(Object error) {
    final msg = switch (error) {
      ApiException e => e.message,
      NetworkException e => e.message,
      StateError e => e.message,
      _ => '发送失败',
    };
    ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return WoScaffold(
      appBar: WoAppBar(title: const Text('家聊')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _body()),
                  if (_hasNewMessages)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 8,
                      child: Center(
                        child: FilledButton(
                          onPressed: () => _loadLocal(
                            ownerUserId: _ownerUserId!,
                            familyId: _familyId!,
                            scroll: true,
                          ),
                          child: const Text('查看最新消息'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            _composer(),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final owner = _ownerUserId;
    final items = _items;
    if (owner == null || _familyId == null) {
      return const PlaceholderScreen(
        emoji: '💬',
        title: '家聊',
        description: '请先加入或创建一个家庭。',
      );
    }
    if (items == null) {
      return const Center(child: WoProgressIndicator());
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _syncSilently(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            PlaceholderScreen(
              emoji: '💬',
              title: '还没有聊天',
              description: '说第一句话吧。',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _syncSilently(),
      child: ChatHistoryList<ChatLocalMessage>(
        items: items,
        controller: _scrollController,
        hasOlder: _hasOlder,
        loadingOlder: _loadingOlder,
        onLoadOlder: _loadOlder,
        itemKey: (message) => ValueKey(message.localId),
        itemBuilder: (message) => _messageTile(message, owner),
        padding: const EdgeInsets.fromLTRB(
          WoTokens.space4,
          WoTokens.space4,
          WoTokens.space4,
          WoTokens.space6,
        ),
      ),
    );
  }

  Widget _messageTile(ChatLocalMessage message, String ownerUserId) {
    final mine = message.senderId == ownerUserId;
    final avatar = MemberAvatar(
      url: message.senderAvatarUrl,
      emoji: message.senderEmoji,
      size: 32,
    );
    final bubble = _bubble(message, mine);
    return Padding(
      padding: const EdgeInsets.only(bottom: WoTokens.space3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: mine
            ? [
                Flexible(child: bubble),
                const SizedBox(width: WoTokens.space2),
                avatar,
              ]
            : [
                avatar,
                const SizedBox(width: WoTokens.space2),
                Flexible(child: bubble),
              ],
      ),
    );
  }

  Widget _bubble(ChatLocalMessage message, bool mine) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final bg = mine ? wo.accentSoft : wo.bgTint;
    final textColor = wo.fg;
    return Column(
      crossAxisAlignment: mine
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        if (!mine)
          Padding(
            padding: const EdgeInsets.only(left: WoTokens.space1, bottom: 2),
            child: Text(
              message.senderName,
              style: t.labelSmall?.copyWith(color: wo.fgDim),
            ),
          ),
        GestureDetector(
          onTap: message.status == chatStatusFailed
              ? () => _retry(message)
              : null,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 280),
            padding: message.isImage
                ? const EdgeInsets.all(WoTokens.space2)
                : const EdgeInsets.symmetric(
                    horizontal: WoTokens.space3,
                    vertical: WoTokens.space2,
                  ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: wo.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.isImage) _image(message),
                if ((message.body ?? '').isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: message.isImage ? WoTokens.space2 : 0,
                    ),
                    child: Text(
                      message.body!,
                      style: t.bodyMedium?.copyWith(color: textColor),
                    ),
                  ),
                if (message.status != chatStatusSent)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      message.status == chatStatusSending ? '发送中' : '发送失败，点按重试',
                      style: t.labelSmall?.copyWith(
                        color: message.status == chatStatusSending
                            ? wo.fgDim
                            : wo.danger,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _image(ChatLocalMessage message) {
    final wo = context.wo;
    final p = message.imageLocalPath;
    if (p != null && File(p).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.file(File(p), width: 220, height: 220, fit: BoxFit.cover),
      );
    }
    return Container(
      width: 220,
      height: 160,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: wo.bgElev,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(Icons.image_not_supported_outlined, color: wo.fgDim),
    );
  }

  Widget _composer() {
    final wo = context.wo;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: wo.bg,
        border: Border(top: BorderSide(color: wo.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          WoTokens.space3,
          WoTokens.space2,
          WoTokens.space3,
          WoTokens.space2,
        ),
        child: Row(
          children: [
            WoIconButton(
              tooltip: '发送图片',
              onPressed: _pickAndSendImage,
              icon: const Icon(Icons.photo_outlined),
            ),
            Expanded(
              child: WoTextField(
                controller: _textController,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => unawaited(_sendText()),
                decoration: InputDecoration(
                  hintText: '输入消息',
                  filled: true,
                  fillColor: wo.bgTint,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: WoTokens.space4,
                    vertical: WoTokens.space3,
                  ),
                ),
              ),
            ),
            const SizedBox(width: WoTokens.space2),
            IconButton.filled(
              tooltip: '发送',
              onPressed: _sendText,
              icon: const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
