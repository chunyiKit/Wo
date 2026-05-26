import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';
import 'join_flow.dart';

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

  Future<void> _join() async {
    if (!_filled || _busy) return;
    setState(() => _busy = true);
    final ok = await joinFamilyWithCode(context, _code);
    if (!ok && mounted) setState(() => _busy = false);
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
