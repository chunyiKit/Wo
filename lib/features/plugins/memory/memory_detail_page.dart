import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/member_avatar.dart';
import 'memory_edit_page.dart';
import 'memory_gallery_page.dart';
import 'memory_media.dart';

/// 回忆详情：大图 + 标题 + 正文 + 元信息 + 双向留言区。
///
/// 编辑 / 删除 / 新增留言后，返回 `true` 通知列表刷新。
class MemoryDetailPage extends StatefulWidget {
  const MemoryDetailPage({super.key, required this.memory});

  final Memory memory;

  @override
  State<MemoryDetailPage> createState() => _MemoryDetailPageState();
}

class _MemoryDetailPageState extends State<MemoryDetailPage> {
  late Memory _memory;
  bool _changed = false;

  final _commentController = TextEditingController();
  bool _sending = false;
  bool _detailLoaded = false;

  @override
  void initState() {
    super.initState();
    _memory = widget.memory;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 列表卡片不带 comments 全量，进详情后拉一次拿到留言。
    if (!_detailLoaded) {
      _detailLoaded = true;
      _reloadDetail();
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _reloadDetail() async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      final fresh = await session.api.memory(familyId, _memory.id);
      if (mounted) setState(() => _memory = fresh);
    } catch (_) {
      // 拉取失败不致命，仍显示列表带过来的数据。
    }
  }

  void _openGallery(Memory m, int index) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => MemoryGalleryPage(media: m.media, initialIndex: index),
      ),
    );
  }

  Future<void> _edit() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => MemoryEditPage(existing: _memory)),
    );
    if (saved != true || !mounted) return;
    _changed = true;
    await _reloadDetail();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除回忆'),
        content: Text('确定删除「${_memory.title}」吗？照片和留言会一起删除，不可撤销。'),
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
    final nav = Navigator.of(context);
    try {
      await session.api.deleteMemory(familyId, _memory.id);
      if (mounted) nav.pop(true);
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _sendComment() async {
    final text = _commentController.text.trim();
    if (text.isEmpty || _sending) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    setState(() => _sending = true);
    try {
      final comment =
          await session.api.addMemoryComment(familyId, _memory.id, text);
      if (!mounted) return;
      setState(() {
        _memory = _withComment(_memory, comment);
        _commentController.clear();
        _changed = true;
        _sending = false;
      });
      FocusScope.of(context).unfocus();
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        _toast(e);
      }
    }
  }

  Future<void> _deleteComment(MemoryComment c) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.deleteMemoryComment(familyId, _memory.id, c.id);
      if (!mounted) return;
      setState(() {
        _memory = _withoutComment(_memory, c.id);
        _changed = true;
      });
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Memory _withComment(Memory m, MemoryComment c) => Memory(
        id: m.id,
        familyId: m.familyId,
        title: m.title,
        body: m.body,
        mood: m.mood,
        location: m.location,
        visibility: m.visibility,
        eventDate: m.eventDate,
        createdBy: m.createdBy,
        authorName: m.authorName,
        authorEmoji: m.authorEmoji,
        createdAt: m.createdAt,
        media: m.media,
        commentCount: m.commentCount + 1,
        comments: [...m.comments, c],
      );

  Memory _withoutComment(Memory m, String commentId) {
    final remaining = m.comments.where((c) => c.id != commentId).toList();
    return Memory(
      id: m.id,
      familyId: m.familyId,
      title: m.title,
      body: m.body,
      mood: m.mood,
      location: m.location,
      visibility: m.visibility,
      eventDate: m.eventDate,
      createdBy: m.createdBy,
      authorName: m.authorName,
      authorEmoji: m.authorEmoji,
      createdAt: m.createdAt,
      media: m.media,
      commentCount: remaining.length,
      comments: remaining,
    );
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
    final m = _memory;
    final myId = WoScope.of(context).user?.id;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: wo.bg,
        appBar: AppBar(
          title: const Text('回忆'),
          actions: [
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _edit,
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    WoTokens.space4,
                    WoTokens.space4,
                    WoTokens.space4,
                    WoTokens.space5,
                  ),
                  children: [
                    if (m.hasMedia) ...[
                      MemoryMediaGrid(
                        media: m.media,
                        radius: WoTokens.cardRadius,
                        onTapMedia: (i) => _openGallery(m, i),
                      ),
                      const SizedBox(height: WoTokens.space4),
                    ],
                    // 日期胶囊
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: wo.memory,
                          borderRadius: BorderRadius.circular(WoTokens.chipRadius),
                        ),
                        child: Text(
                          '${m.eventDate.month} 月 ${m.eventDate.day} 日 · '
                          '${memoryDateLabel(m.eventDate)}',
                          style: t.labelSmall?.copyWith(
                            color: wo.memoryInk,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: WoTokens.space3),
                    Text(
                      m.mood != null ? '${m.mood} ${m.title}' : m.title,
                      style: t.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: WoTokens.space3),
                    _MetaLine(memory: m),
                    if (m.body != null && m.body!.isNotEmpty) ...[
                      const SizedBox(height: WoTokens.space4),
                      Text(
                        m.body!,
                        style: t.bodyLarge?.copyWith(height: 1.7),
                      ),
                    ],
                    const SizedBox(height: WoTokens.space5),
                    Divider(color: wo.hairline, height: 1),
                    const SizedBox(height: WoTokens.space4),
                    _CommentsSection(
                      comments: m.comments,
                      myId: myId,
                      onDelete: _deleteComment,
                    ),
                  ],
                ),
              ),
              _CommentInput(
                controller: _commentController,
                sending: _sending,
                onSend: _sendComment,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.memory});
  final Memory memory;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final m = memory;
    return Row(
      children: [
        if (m.authorName != null) ...[
          MemberAvatar(
            url: m.authorAvatarUrl,
            emoji: m.authorEmoji ?? '👤',
            size: 22,
          ),
          const SizedBox(width: 6),
          Text(m.authorName!, style: t.bodyMedium?.copyWith(color: wo.fgMid)),
        ],
        if (m.location != null && m.location!.isNotEmpty) ...[
          const SizedBox(width: WoTokens.space3),
          Icon(Icons.place_outlined, size: 15, color: wo.fgDim),
          const SizedBox(width: 3),
          Text(m.location!, style: t.bodyMedium?.copyWith(color: wo.fgMid)),
        ],
        if (m.visibility == 'private') ...[
          const SizedBox(width: WoTokens.space3),
          Icon(Icons.lock_outline, size: 15, color: wo.fgDim),
          const SizedBox(width: 3),
          Text('只我自己', style: t.bodySmall?.copyWith(color: wo.fgDim)),
        ],
      ],
    );
  }
}

class _CommentsSection extends StatelessWidget {
  const _CommentsSection({
    required this.comments,
    required this.myId,
    required this.onDelete,
  });

  final List<MemoryComment> comments;
  final String? myId;
  final ValueChanged<MemoryComment> onDelete;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    if (comments.isEmpty) {
      return Text(
        '还没有留言，留一句给 TA 吧',
        style: t.bodySmall?.copyWith(color: wo.fgDim),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final c in comments)
          Padding(
            padding: const EdgeInsets.only(bottom: WoTokens.space3),
            child: _CommentBubble(
              comment: c,
              isMine: c.authorId != null && c.authorId == myId,
              onDelete: () => onDelete(c),
            ),
          ),
      ],
    );
  }
}

class _CommentBubble extends StatelessWidget {
  const _CommentBubble({
    required this.comment,
    required this.isMine,
    required this.onDelete,
  });

  final MemoryComment comment;
  final bool isMine;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final c = comment;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MemberAvatar(
          url: c.authorAvatarUrl,
          emoji: c.authorEmoji ?? '👤',
          size: 28,
        ),
        const SizedBox(width: WoTokens.space2),
        Flexible(
          child: GestureDetector(
            onLongPress: isMine ? onDelete : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: wo.bgTint,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.authorName ?? '匿名',
                    style: t.labelSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(c.body, style: t.bodyMedium?.copyWith(height: 1.5)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CommentInput extends StatelessWidget {
  const _CommentInput({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Container(
      padding: EdgeInsets.fromLTRB(
        WoTokens.space4,
        WoTokens.space2,
        WoTokens.space3,
        WoTokens.space2 + MediaQuery.of(context).viewInsets.bottom * 0,
      ),
      decoration: BoxDecoration(
        color: wo.bg,
        border: Border(top: BorderSide(color: wo.hairline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: wo.bgTint,
                borderRadius: BorderRadius.circular(22),
              ),
              child: TextField(
                controller: controller,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: '写一句…',
                  border: InputBorder.none,
                  counterText: '',
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: WoTokens.space2),
          GestureDetector(
            onTap: sending ? null : onSend,
            child: CircleAvatar(
              radius: 20,
              backgroundColor: wo.accent,
              child: sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send, size: 18, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
