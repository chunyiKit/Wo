import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';

/// 输入邀请码：WO-XXXX-XXXX 分段输入。先预览家庭，确认后接受加入。
class JoinByCodePage extends StatefulWidget {
  const JoinByCodePage({super.key});

  @override
  State<JoinByCodePage> createState() => _JoinByCodePageState();
}

class _JoinByCodePageState extends State<JoinByCodePage> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  bool _busy = false;

  bool get _filled => _a.text.length == 4 && _b.text.length == 4;
  String get _code => '${_a.text}${_b.text}';

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _join() async {
    if (!_filled || _busy) return;
    setState(() => _busy = true);
    final session = WoScope.of(context);
    try {
      final InvitationPreview preview =
          await session.api.previewInvitation(_code);
      if (!mounted) return;
      final confirmed = await _confirm(preview);
      if (confirmed != true) {
        setState(() => _busy = false);
        return;
      }
      final family = await session.api.acceptInvitation(_code);
      await session.switchFamily(family.id);
      if (mounted) {
        _toast('已加入「${family.name}」');
        GoRouter.of(context).go(WoRoutes.home);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(
          switch (e) {
            ApiException a => a.message,
            NetworkException a => a.message,
            _ => '加入失败',
          },
        );
      }
    }
  }

  Future<bool?> _confirm(InvitationPreview p) {
    final t = Theme.of(context).textTheme;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(p.familyEmoji, style: const TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space3),
            Text(
              '加入「${p.familyName}」？',
              style: t.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space2),
            Text(
              [
                '${p.memberCount} 位成员',
                if (p.inviterName != null) '${p.inviterName} 邀请你',
              ].join(' · '),
              style: t.bodySmall?.copyWith(color: ctx.wo.fgMid),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('加入'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('输入邀请码'),
        actions: [
          IconButton(
            tooltip: '扫码',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: () => context.push(WoRoutes.joinByScan),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(WoTokens.space6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '邀请码格式：WO-XXXX-XXXX',
                style: t.bodyMedium?.copyWith(color: wo.fgMid),
              ),
              const SizedBox(height: WoTokens.space6),
              Row(
                children: [
                  Text('WO -', style: t.titleLarge?.copyWith(color: wo.fgMid)),
                  const SizedBox(width: WoTokens.space2),
                  Expanded(child: _codeField(_a)),
                  const SizedBox(width: WoTokens.space2),
                  Text('-', style: t.titleLarge?.copyWith(color: wo.fgMid)),
                  const SizedBox(width: WoTokens.space2),
                  Expanded(child: _codeField(_b)),
                ],
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: (_filled && !_busy) ? _join : null,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_filled ? '加入这个家' : '请输入完整邀请码'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _codeField(TextEditingController c) {
    return TextField(
      controller: c,
      textAlign: TextAlign.center,
      maxLength: 4,
      textCapitalization: TextCapitalization.characters,
      onChanged: (_) => setState(() {}),
      decoration: const InputDecoration(counterText: '', hintText: 'XXXX'),
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        letterSpacing: 4,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
