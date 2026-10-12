import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';

/// 恢复码仅在验证已有密码后签发，不把未验证手机号当成找回凭据。
class RecoveryPage extends StatefulWidget {
  const RecoveryPage({super.key, this.enroll = false});
  final bool enroll;

  @override
  State<RecoveryPage> createState() => _RecoveryPageState();
}

class _RecoveryPageState extends State<RecoveryPage> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _generated;
  String? _expires;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    _generated = null;
    super.dispose();
  }

  bool get _valid => widget.enroll
      ? _password.text.isNotEmpty
      : RegExp(r'^1[3-9]\d{9}$').hasMatch(_phone.text) &&
          _code.text.trim().isNotEmpty &&
          _password.text.length >= 6 &&
          _password.text == _confirm.text;

  Future<void> _submit({bool logoutAll = false}) async {
    if (_busy || (!logoutAll && !_valid)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final session = WoScope.of(context);
    final router = GoRouter.of(context);
    try {
      if (logoutAll) {
        await session.logout(all: true);
        if (mounted) router.go(WoRoutes.login);
      } else if (widget.enroll) {
        final data = await session.api.createRecoveryCode(_password.text);
        if (!mounted) return;
        _password.clear();
        setState(() {
          _generated = data['recovery_code'] as String;
          _expires = data['expires_at'] as String;
        });
      } else {
        await session.api.resetPassword(
            phone: _phone.text,
            recoveryCode: _code.text.trim(),
            newPassword: _password.text,);
        await session.clearAuth();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          WoSnackBar(content: Text('密码已重置，所有旧会话已撤销，请重新登录')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = switch (e) {
              ApiException a => a.message,
              NetworkException a => a.message,
              _ => '操作失败，请重试',
            },);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => WoScaffold(
        appBar: WoAppBar(title: Text(widget.enroll ? '恢复码与会话撤销' : '找回账号')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.enroll
                ? '输入当前密码生成一次性恢复码，请离线妥善保存。有效期一年，重新生成会替换旧码；改密或找回后需重新生成。恢复码不会保存在 App 中。'
                : '使用此前验证密码后保存的恢复码找回。手机号不是身份凭据。没有恢复码或未设密码的旧账号，请联系管理员按独立身份材料线下核验迁移；不能仅凭手机号、家庭资料或旧会话设密。',),
            const SizedBox(height: WoTokens.space5),
            if (!widget.enroll) ...[
              _field(_phone, '手机号', phone: true),
              const SizedBox(height: WoTokens.space3),
              _field(_code, '一次性恢复码', secret: true, maxLength: 128),
              const SizedBox(height: WoTokens.space3),
            ],
            _field(_password, widget.enroll ? '当前密码' : '新密码（至少 6 位）',
                secret: true,),
            if (!widget.enroll) ...[
              const SizedBox(height: WoTokens.space3),
              _field(_confirm, '确认新密码', secret: true),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: WoTokens.space3),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),),
              ),
            const SizedBox(height: WoTokens.space5),
            WoFilledButton(
                onPressed: _busy || !_valid ? null : () => _submit(),
                child: Text(_busy
                    ? '处理中…'
                    : widget.enroll
                        ? '生成 / 替换恢复码'
                        : '重置密码',),),
            if (_generated != null) ...[
              const SizedBox(height: WoTokens.space5),
              const Text('仅本次展示，请保存后再离开。'),
              SelectableText(_generated!,
                  key: const Key('generated-recovery-code'),),
              Text('到期时间：$_expires'),
            ],
            if (widget.enroll) ...[
              const SizedBox(height: WoTokens.space8),
              const Text('退出所有设备将立即撤销包括本机在内的所有会话。网络失败时可重试。'),
              const SizedBox(height: WoTokens.space3),
              OutlinedButton(
                  onPressed: _busy ? null : () => _submit(logoutAll: true),
                  child: const Text('退出所有设备'),),
            ],
          ],),
        ),
      );

  Widget _field(TextEditingController controller, String label,
          {bool secret = false, bool phone = false, int maxLength = 64,}) =>
      WoTextField(
        controller: controller,
        obscureText: secret,
        enabled: !_busy,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: phone ? TextInputType.phone : TextInputType.text,
        maxLength: phone ? 11 : maxLength,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(labelText: label, counterText: ''),
      );
}
