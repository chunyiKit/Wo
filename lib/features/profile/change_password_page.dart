import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';

/// 修改登录密码。需输入原密码 + 新密码（两次）。
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  static const _minLen = 6;

  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _valid =>
      _old.text.isNotEmpty &&
      _new.text.length >= _minLen &&
      _confirm.text == _new.text;

  Future<void> _submit() async {
    if (_busy) return;
    if (_new.text != _confirm.text) {
      _toast('两次输入的新密码不一致');
      return;
    }
    if (_new.text.length < _minLen) {
      _toast('新密码至少 $_minLen 位');
      return;
    }
    setState(() => _busy = true);
    final session = WoScope.of(context);
    final nav = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await session.api.changePassword(
        oldPassword: _old.text,
        newPassword: _new.text,
      );
      messenger.showSnackBar(const SnackBar(content: Text('密码已修改')));
      nav.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(
          switch (e) {
            ApiException a => a.message,
            NetworkException a => a.message,
            _ => '修改失败',
          },
        );
      }
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('修改密码')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(_old, '原密码'),
              const SizedBox(height: WoTokens.space3),
              _field(_new, '新密码（至少 $_minLen 位）'),
              const SizedBox(height: WoTokens.space3),
              _field(_confirm, '确认新密码'),
              const SizedBox(height: WoTokens.space5),
              FilledButton(
                onPressed: (_valid && !_busy) ? _submit : null,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String label) => TextField(
        controller: c,
        obscureText: _obscure,
        maxLength: 64,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: label,
          counterText: '',
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      );
}
