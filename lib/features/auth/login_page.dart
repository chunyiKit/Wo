import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';

/// 手机号登录 / 注册。
///
/// 暂无短信验证码：输入手机号点继续，后端查到就登录、查不到就注册。验证码步骤
/// 等接口就绪后再补在这一步之后。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phone = TextEditingController();
  bool _busy = false;

  bool get _valid {
    final v = _phone.text;
    return v.length == 11 && v.startsWith('1');
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (!_valid || _busy) return;
    setState(() => _busy = true);
    final session = WoScope.of(context);
    final router = GoRouter.of(context);
    try {
      await session.login(_phone.text);
      if (!mounted) return;
      // 登录后：有家庭进首页，否则去创建/加入。
      router.go(
        session.currentFamily != null ? WoRoutes.home : WoRoutes.joinLanding,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
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
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(WoTokens.space6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('手机号登录', style: t.displaySmall),
              const SizedBox(height: WoTokens.space2),
              Text(
                '没注册过的号码会直接为你创建账号。',
                style: t.bodyMedium?.copyWith(color: wo.fgMid),
              ),
              const SizedBox(height: WoTokens.space8),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                autofocus: true,
                maxLength: 11,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _continue(),
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
              const SizedBox(height: WoTokens.space6),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: (_valid && !_busy) ? _continue : null,
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('继续'),
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              Center(
                child: Text(
                  '短信验证码功能即将上线',
                  style: t.bodySmall?.copyWith(color: wo.fgDim),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
