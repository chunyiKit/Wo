import 'dart:typed_data';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'memory_media.dart';
import 'memory_media_pick.dart';
import 'memory_save_draft.dart';

/// 回忆新增 / 编辑页。
///
/// [existing] 为空 = 新增；非空 = 编辑。保存成功后 `Navigator.pop(true)`。
/// 媒体的增删都先在本地暂存，点保存时：先存正文，再删除被移除的旧媒体、
/// 上传新选的照片/视频。
class MemoryEditPage extends StatefulWidget {
  const MemoryEditPage({super.key, this.existing});

  final Memory? existing;

  @override
  State<MemoryEditPage> createState() => _MemoryEditPageState();
}

class _MemoryEditPageState extends State<MemoryEditPage> {
  static const _moods = ['😍', '🥹', '🤤', '😌', '😆', '🥰', '😭', '🤔'];
  static const _visibilities = <(String, String)>[
    ('family', '🏡 全家'),
    ('private', '🔒 只我自己'),
    ('couple', '💞 我和 TA'),
  ];
  static const _maxMedia = 9;

  late final TextEditingController _title;
  late final TextEditingController _body;
  late final TextEditingController _location;
  late String _mood; // '' = 未选
  late String _visibility;
  late DateTime _eventDate;

  // 编辑模式下从后端带来的旧媒体（减去用户标记删除的）。
  late List<MemoryMedia> _existingMedia;
  final Set<String> _removedMediaIds = {};
  // 新选、待上传的照片字节与视频。
  final List<Uint8List> _pendingPhotos = [];
  final List<PickedVideo> _pendingVideos = [];

  late MemorySaveDraft _draft;
  MemoryDraftStore? _draftStore;
  final Map<Uint8List, MemoryDraftAttachment> _attachments = {};
  bool _restoring = true;
  bool _restoreStarted = false;
  bool Function()? _isScopeCurrent;

  bool _picking = false;
  bool _submitting = false;

  // 新建时，第一张照片的 EXIF 拍摄日期会自动填进日期；
  // 这俩标记保证只填一次、且不覆盖用户手动改过的日期。
  bool _eventDateManuallySet = false;
  bool _autoFilledDateFromPhoto = false;

  bool get _isEditing => widget.existing != null;

  int get _mediaCount =>
      _existingMedia.length + _pendingPhotos.length + _pendingVideos.length;

  @override
  void initState() {
    super.initState();
    final m = widget.existing;
    _draft = MemorySaveDraft(memoryId: m?.id);
    _title = TextEditingController(text: m?.title ?? '');
    _body = TextEditingController(text: m?.body ?? '');
    _location = TextEditingController(text: m?.location ?? '');
    _mood = m?.mood ?? '';
    _visibility = m?.visibility ?? 'family';
    _eventDate = m?.eventDate ?? DateTime.now();
    _existingMedia = List.of(m?.media ?? const <MemoryMedia>[]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoreStarted) return;
    _restoreStarted = true;
    _restoreDraft();
  }

  Future<void> _restoreDraft() async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    final userId = session.user?.id;
    if (familyId == null || userId == null) return;
    final server = session.api.baseUrl;
    final token = session.api.authToken;
    final devUser = session.api.userId;
    _isScopeCurrent = () =>
        session.currentFamilyId == familyId &&
        session.user?.id == userId &&
        session.api.baseUrl == server &&
        session.api.authToken == token &&
        session.api.userId == devUser;
    try {
      final root = await getApplicationSupportDirectory();
      final scope = MemoryDraftStore.scope(
        session.api.baseUrl,
        userId,
        familyId,
        widget.existing?.id,
      );
      final store = MemoryDraftStore(
        Directory('${root.path}/memory_drafts/$scope'),
      );
      final restored = await store.read();
      if (!mounted) return;
      if (!_isScopeCurrent!()) {
        _toastMsg('登录身份或家庭已改变，请返回后重试');
        return;
      }
      setState(() {
        _draftStore = store;
        if (restored != null) {
          _draft = restored;
          _title.text = restored.fields['title'] as String;
          _body.text = restored.fields['body'] as String? ?? '';
          _location.text = restored.fields['location'] as String? ?? '';
          _mood = restored.fields['mood'] as String? ?? '';
          _visibility = restored.fields['visibility'] as String;
          _eventDate = DateTime.parse(restored.fields['event_date'] as String);
          _eventDateManuallySet = true;
          _existingMedia = List.of(restored.existingMedia);
          _removedMediaIds.addAll(restored.removedMediaIds);
          for (final a in restored.attachments) {
            _attachments[a.bytes] = a;
            if (a.filename == 'photo.jpg') {
              _pendingPhotos.add(a.bytes);
            } else {
              _pendingVideos.add(
                PickedVideo(
                  bytes: a.bytes,
                  filename: a.filename,
                  durationMs: a.durationMs,
                ),
              );
            }
          }
        }
        _restoring = false;
      });
      if (restored != null) _toastMsg('已恢复未完成的保存，可继续重试');
    } catch (e) {
      if (mounted) _toastMsg('无法恢复保存草稿，请返回后重试');
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<void> _addMedia() async {
    if (_picking) return;
    if (_mediaCount >= _maxMedia) {
      _toastMsg('最多 $_maxMedia 个');
      return;
    }
    final choice = await showWoModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            WoListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('照片'),
              onTap: () => Navigator.of(ctx).pop('photo'),
            ),
            WoListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('视频'),
              onTap: () => Navigator.of(ctx).pop('video'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    setState(() => _picking = true);
    try {
      if (choice == 'photo') {
        final remaining = _maxMedia - _mediaCount;
        final result = await pickAndCompressMemoryPhotos(limit: remaining);
        if (!result.isEmpty && mounted) {
          setState(() {
            _pendingPhotos.addAll(result.photos.take(remaining));
            // 仅新建、用户没手动改过日期、且还没自动填过时，用第一张照片的
            // EXIF 拍摄日期填日期；编辑已有回忆不触发。
            if (!_isEditing &&
                !_eventDateManuallySet &&
                !_autoFilledDateFromPhoto &&
                result.firstCapturedAt != null) {
              _eventDate = result.firstCapturedAt!;
              _autoFilledDateFromPhoto = true;
            }
          });
        }
      } else {
        final video = await pickMemoryVideo();
        if (video != null && mounted) setState(() => _pendingVideos.add(video));
      }
    } catch (e) {
      if (mounted) _toast(e);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      useRootNavigator: false,
      initialDate: _eventDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) {
      setState(() {
        _eventDate = picked;
        _eventDateManuallySet = true;
      });
    }
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty || _submitting || _picking || _restoring) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    final store = _draftStore;
    if (familyId == null || store == null) return;
    if (!(_isScopeCurrent?.call() ?? false)) {
      _toastMsg('登录身份或家庭已改变，请返回后重试');
      return;
    }

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      _draft.fields = {
        'title': title,
        'body': _body.text.trim(),
        'mood': _mood,
        'location': _location.text.trim(),
        'visibility': _visibility,
        'event_date': _eventDate.toIso8601String(),
      };
      _draft.existingMedia = List.of(_existingMedia);
      _draft.removedMediaIds.addAll(_removedMediaIds);
      final selected = [
        for (final bytes in _pendingPhotos)
          _attachments.putIfAbsent(
            bytes,
            () => MemoryDraftAttachment(bytes: bytes, filename: 'photo.jpg'),
          ),
        for (final v in _pendingVideos)
          _attachments.putIfAbsent(
            v.bytes,
            () => MemoryDraftAttachment(
              bytes: v.bytes,
              filename: v.filename,
              durationMs: v.durationMs,
            ),
          ),
      ];
      // 已尝试过的附件即使响应丢失，也必须在用户移除后删除服务端副本。
      for (final old in _draft.attachments) {
        if (!selected.contains(old)) _draft.removedMediaIds.add(old.id);
      }
      _draft.attachments
        ..clear()
        ..addAll(selected);
      if (await _draft.save(
            session.api,
            familyId,
            store,
            isScopeCurrent: _isScopeCurrent,
          ) &&
          mounted) {
        nav.pop(true);
      }
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
    _toastMsg(msg);
  }

  void _toastMsg(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final canSave =
        _title.text.trim().isNotEmpty &&
        !_submitting &&
        !_restoring &&
        !_picking;

    return PopScope(
      canPop: !_submitting,
      child: WoScaffold(
        backgroundColor: wo.bg,
        appBar: WoAppBar(
          title: Text(_isEditing ? '编辑回忆' : '新的回忆'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: WoTokens.space2),
              child: WoTextButton(
                onPressed: canSave ? _save : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: WoProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: AbsorbPointer(
            absorbing: _submitting || _restoring,
            child: ListView(
              padding: const EdgeInsets.all(WoTokens.space4),
              children: [
                _MediaPicker(
                  existing: _existingMedia,
                  pendingPhotos: _pendingPhotos,
                  pendingVideos: _pendingVideos,
                  busy: _picking,
                  count: _mediaCount,
                  max: _maxMedia,
                  onAdd: _addMedia,
                  onRemoveExisting: (m) => setState(() {
                    _existingMedia.remove(m);
                    _removedMediaIds.add(m.id);
                  }),
                  onRemovePhoto: (i) =>
                      setState(() => _pendingPhotos.removeAt(i)),
                  onRemoveVideo: (i) =>
                      setState(() => _pendingVideos.removeAt(i)),
                ),
                const SizedBox(height: WoTokens.space4),
                WoTextField(
                  controller: _title,
                  maxLength: 80,
                  onChanged: (_) => setState(() {}),
                  style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    hintText: '给这一刻起个标题',
                    counterText: '',
                    border: InputBorder.none,
                  ),
                ),
                Divider(color: wo.hairline, height: 1),
                const SizedBox(height: WoTokens.space3),
                WoTextField(
                  controller: _body,
                  maxLength: 2000,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    hintText: '今天发生了什么？',
                    counterText: '',
                    border: InputBorder.none,
                  ),
                ),
                const SizedBox(height: WoTokens.space4),
                _MetaRow(
                  icon: Icons.calendar_today_outlined,
                  label: '日期',
                  value:
                      '${memoryDateLabel(_eventDate)} · '
                      '${_eventDate.year}-${_eventDate.month}-${_eventDate.day}',
                  onTap: _pickDate,
                ),
                const SizedBox(height: WoTokens.space2),
                _LocationRow(controller: _location),
                const SizedBox(height: WoTokens.space4),
                Text('心情', style: t.titleSmall),
                const SizedBox(height: WoTokens.space2),
                Wrap(
                  spacing: WoTokens.space2,
                  children: [
                    for (final mood in _moods)
                      GestureDetector(
                        onTap: () =>
                            setState(() => _mood = _mood == mood ? '' : mood),
                        child: Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _mood == mood ? wo.accentSoft : wo.bgTint,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: _mood == mood
                                  ? wo.accent
                                  : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            mood,
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: WoTokens.space4),
                Text('谁能看到', style: t.titleSmall),
                const SizedBox(height: WoTokens.space2),
                Wrap(
                  spacing: WoTokens.space2,
                  children: [
                    for (final (value, label) in _visibilities)
                      WoChoiceChip(
                        label: Text(label),
                        selected: _visibility == value,
                        onSelected: (_) => setState(() => _visibility = value),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 九宫格媒体上传区：旧媒体 + 新照片 + 新视频 + 「＋」添加格。每格可删。
class _MediaPicker extends StatelessWidget {
  const _MediaPicker({
    required this.existing,
    required this.pendingPhotos,
    required this.pendingVideos,
    required this.busy,
    required this.count,
    required this.max,
    required this.onAdd,
    required this.onRemoveExisting,
    required this.onRemovePhoto,
    required this.onRemoveVideo,
  });

  final List<MemoryMedia> existing;
  final List<Uint8List> pendingPhotos;
  final List<PickedVideo> pendingVideos;
  final bool busy;
  final int count;
  final int max;
  final VoidCallback onAdd;
  final ValueChanged<MemoryMedia> onRemoveExisting;
  final ValueChanged<int> onRemovePhoto;
  final ValueChanged<int> onRemoveVideo;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    final tiles = <Widget>[
      for (final m in existing)
        _Tile(
          onRemove: () => onRemoveExisting(m),
          badge: m.isVideo ? (m.durationLabel ?? '视频') : null,
          child: MemoryMediaTile(media: m, radius: 14),
        ),
      for (var i = 0; i < pendingPhotos.length; i++)
        _Tile(
          onRemove: () => onRemovePhoto(i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.memory(pendingPhotos[i], fit: BoxFit.cover),
          ),
        ),
      for (var i = 0; i < pendingVideos.length; i++)
        _Tile(
          onRemove: () => onRemoveVideo(i),
          badge: pendingVideos[i].durationMs != null
              ? _fmt(pendingVideos[i].durationMs!)
              : '视频',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              color: wo.memory,
              child: const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  size: 36,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      if (count < max) _AddTile(busy: busy, onTap: onAdd),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GridView.count(
          crossAxisCount: 3,
          mainAxisSpacing: WoTokens.space2,
          crossAxisSpacing: WoTokens.space2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: tiles,
        ),
        const SizedBox(height: WoTokens.space2),
        Text(
          '$count / $max · 照片或短视频',
          style: t.labelSmall?.copyWith(color: wo.fgDim),
        ),
      ],
    );
  }

  static String _fmt(int ms) {
    final total = (ms / 1000).round();
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.child, required this.onRemove, this.badge});

  final Widget child;
  final VoidCallback onRemove;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (badge != null)
            Positioned(
              left: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  badge!,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return AspectRatio(
      aspectRatio: 1,
      child: GestureDetector(
        onTap: busy ? null : onTap,
        child: DottedBorderBox(
          color: wo.hairline,
          child: busy
              ? const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: WoProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add, color: wo.fgMid),
                    const SizedBox(height: 4),
                    Text(
                      '照片 / 视频',
                      style: t.labelSmall?.copyWith(color: wo.fgMid),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// 虚线边框的占位框（用 DecoratedBox 的实线近似——Flutter 没内置虚线，
/// 这里用浅色实线圆角框即可，视觉上够轻。）
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({super.key, required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color, width: 1.5),
      ),
      child: child,
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(WoTokens.space3),
        decoration: BoxDecoration(
          color: wo.bgTint,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: wo.fgMid),
            const SizedBox(width: WoTokens.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: t.labelSmall?.copyWith(color: wo.fgMid)),
                  const SizedBox(height: 1),
                  Text(value, style: t.bodyMedium),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: wo.fgDim),
          ],
        ),
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: WoTokens.space3),
      decoration: BoxDecoration(
        color: wo.bgTint,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.place_outlined, size: 18, color: wo.fgMid),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: WoTextField(
              controller: controller,
              maxLength: 80,
              decoration: const InputDecoration(
                hintText: '在哪里？（可选）',
                counterText: '',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
