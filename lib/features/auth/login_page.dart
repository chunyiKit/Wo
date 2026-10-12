import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_cinema.dart';
import 'recovery_page.dart';

/// 手机号与密码登录 / 注册。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  static const _minPasswordLen = 6;

  bool get _valid {
    final v = _phone.text;
    return v.length == 11 &&
        v.startsWith('1') &&
        _password.text.length >= _minPasswordLen;
  }

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (!_valid || _busy) return;
    setState(() => _busy = true);
    final session = WoScope.of(context);
    final router = GoRouter.of(context);
    try {
      await session.login(_phone.text, _password.text);
      if (!mounted) return;
      // 登录后：有家庭进首页，否则去创建/加入。
      router.go(
        session.currentFamily != null ? WoRoutes.home : WoRoutes.joinLanding,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          WoSnackBar(
            content: Text(
              switch (e) {
                ApiException a => a.message,
                NetworkException a => a.message,
                _ => '登录失败',
              },
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return WoScaffold(
      backgroundColor: wo.bg,
      appBar: WoAppBar(backgroundColor: Colors.transparent),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const WoCinemaMasthead(
                title: '欢迎回到窝',
                subtitle: '每一个平凡的今天，都值得收藏。',
              ),
              const SizedBox(height: 28),
              Text('手机号登录', style: t.displaySmall),
              const SizedBox(height: WoTokens.space2),
              Text(
                '新号码会创建账号；已有账号需原密码。手机号仅为登录标识，尚未验证归属。',
                style: t.bodyMedium?.copyWith(color: wo.fgMid),
              ),
              const SizedBox(height: WoTokens.space8),
              WoTextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                autofocus: false,
                maxLength: 11,
                onChanged: (_) => setState(() {}),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(11),
                ],
                decoration: const InputDecoration(
                  labelText: '手机号',
                  hintText: '请输入 11 位手机号',
                  prefixText: '+86  ',
                  counterText: '',
                ),
                style: t.titleLarge,
              ),
              const SizedBox(height: WoTokens.space4),
              WoTextField(
                controller: _password,
                obscureText: _obscure,
                maxLength: 64,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _continue(),
                decoration: InputDecoration(
                  labelText: '密码',
                  hintText: '至少 $_minPasswordLen 位',
                  counterText: '',
                  suffixIcon: WoIconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: WoTokens.space6),
              SizedBox(
                width: double.infinity,
                child: WoFilledButton(
                  onPressed: (_valid && !_busy) ? _continue : null,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: WoProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('继续'),
                ),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => const RecoveryPage(),),
                        ),
                child: const Text('忘记密码 / 旧账号迁移'),
              ),
              const SizedBox(height: WoTokens.space4),
              Center(
                child: Text(
                  '请妥善保管密码，登录后可在「设置 · 修改密码」中更改',
                  style: t.bodySmall?.copyWith(color: wo.fgDim),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
