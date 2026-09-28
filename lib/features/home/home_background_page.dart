import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/api_client.dart';
import '../../data/image_pick.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_cinema.dart';
import 'family_home_background.dart';
import 'home_tagline.dart';

class HomeBackgroundPage extends StatefulWidget {
  const HomeBackgroundPage({super.key, required this.family, this.pickImage});

  final Family family;
  final Future<Uint8List?> Function()? pickImage;

  @override
  State<HomeBackgroundPage> createState() => _HomeBackgroundPageState();
}

class _HomeBackgroundPageState extends State<HomeBackgroundPage> {
  Uint8List? _selected;
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await (widget.pickImage?.call() ??
          pickAndCompressImage(maxEdge: 1600));
      if (bytes != null && mounted) setState(() => _selected = bytes);
    } catch (error) {
      if (mounted) setState(() => _error = '无法读取图片，请重试或检查相册权限');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save({bool reset = false}) async {
    if (_busy || (!reset && _selected == null)) return;
    final session = WoScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = reset
          ? await session.api.resetFamilyBackground(widget.family.id)
          : await session.api
              .uploadFamilyBackground(widget.family.id, bytes: _selected!);
      session.updateFamilySnapshot(updated);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = switch (error) {
            ApiException e => e.message,
            NetworkException e => e.message,
            _ => '保存失败，请重试',
          };
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final canEdit =
        widget.family.myRole == 'owner' || widget.family.myRole == 'admin';
    return PopScope(
      canPop: !_busy,
      child: WoScaffold(
        appBar: WoAppBar(title: const Text('首页背景')),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.all(WoTokens.space5),
            children: [
              Text(
                '${widget.family.name} · 全家共享',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: WoTokens.space3),
              SizedBox(
                height: 205,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(WoTokens.cardRadius),
                  child: WoCinemaBackdrop(
                    background: FamilyHomeBackground(
                      url: widget.family.backgroundUrl,
                      preview: _selected,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const HomeTagline(),
                          const SizedBox(height: 8),
                          const Text(
                            '柴米油盐，都是我们的浪漫。',
                            style: TextStyle(
                              color: Color(0xFFF2D0A9),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              Text(
                canEdit
                    ? '建议选择横向照片。图片会居中裁切，保存后当前家庭的家人都能看到。'
                    : '首页背景由主理人或管理员设置，全家共享。',
                style: TextStyle(color: wo.fgMid),
              ),
              const SizedBox(height: WoTokens.space5),
              if (canEdit) ...[
                WoOutlinedButton.icon(
                  onPressed: _busy ? null : _pick,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Text(_selected == null ? '从相册选择' : '重新选择'),
                ),
                const SizedBox(height: WoTokens.space3),
                WoFilledButton(
                  onPressed: _busy || _selected == null ? null : () => _save(),
                  child: Text(_busy ? '处理中…' : '保存背景'),
                ),
                if (widget.family.backgroundUrl != null) ...[
                  const SizedBox(height: WoTokens.space3),
                  WoTextButton(
                    onPressed: _busy ? null : () => _save(reset: true),
                    child: const Text('恢复默认背景'),
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: WoTokens.space3),
                Semantics(
                  liveRegion: true,
                  child: Text(_error!, style: TextStyle(color: wo.danger)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
