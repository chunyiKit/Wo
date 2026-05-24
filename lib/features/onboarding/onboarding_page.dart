import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';

/// Onboarding 3 屏：家 → 插件 → 多家庭。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _controller = PageController();
  int _index = 0;

  static const _steps = <_Step>[
    _Step(
      eyebrow: '家 · 是这里的单位',
      title: '家是单位',
      description: '一家人共享日程、记账、相册、清单——所有功能围绕家庭运转。',
      emoji: '🏡',
    ),
    _Step(
      eyebrow: '想要什么功能，装什么插件',
      title: '插件化',
      description: '日程 / 记账 / 相册 / 清单 / 纪念日 …… 按需启用，随时增删。',
      emoji: '🧩',
    ),
    _Step(
      eyebrow: '和爱人的窝，和爸妈的窝',
      title: '多家庭',
      description: '一个账号可加入多个家庭，自由切换；每个家庭都是独立的小世界。',
      emoji: '🏘️',
    ),
  ];

  void _next() {
    if (_index == _steps.length - 1) {
      context.go(WoRoutes.login);
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: wo.bg,
      body: SafeArea(
        child: Column(
          children: [
            // 顶部进度 + 跳过
            Padding(
              padding: const EdgeInsets.all(WoTokens.space5),
              child: Row(
                children: [
                  for (var i = 0; i < _steps.length; i++) ...[
                    Expanded(
                      child: Container(
                        height: 3,
                        decoration: BoxDecoration(
                          color: i <= _index ? wo.accent : wo.hairline,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    if (i < _steps.length - 1)
                      const SizedBox(width: WoTokens.space2),
                  ],
                  const SizedBox(width: WoTokens.space4),
                  TextButton(
                    onPressed: () => context.go(WoRoutes.login),
                    child: Text(
                      '跳过',
                      style: t.labelLarge?.copyWith(color: wo.fgMid),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _steps.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) => _OnboardingSlide(step: _steps[i]),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(
                WoTokens.space6,
                WoTokens.space4,
                WoTokens.space6,
                WoTokens.space8,
              ),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _next,
                      child: Text(
                        _index == _steps.length - 1 ? '现在开始' : '继续',
                      ),
                    ),
                  ),
                  if (_index == _steps.length - 1) ...[
                    const SizedBox(height: WoTokens.space2),
                    TextButton(
                      onPressed: () => context.go(WoRoutes.login),
                      child: const Text('已经有账号？登录'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardingSlide extends StatelessWidget {
  const _OnboardingSlide({required this.step});
  final _Step step;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: WoTokens.space6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          Container(
            width: 200,
            height: 200,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: wo.accentSoft,
              borderRadius: BorderRadius.circular(60),
            ),
            child: Text(step.emoji, style: const TextStyle(fontSize: 96)),
          ),
          const Spacer(),
          Text(
            step.eyebrow,
            style: t.labelLarge?.copyWith(color: wo.accentDeep),
          ),
          const SizedBox(height: WoTokens.space2),
          Text(step.title, style: t.displaySmall),
          const SizedBox(height: WoTokens.space3),
          Text(step.description, style: t.bodyLarge?.copyWith(color: wo.fgMid)),
          const SizedBox(height: WoTokens.space8),
        ],
      ),
    );
  }
}

class _Step {
  const _Step({
    required this.eyebrow,
    required this.title,
    required this.description,
    required this.emoji,
  });
  final String eyebrow;
  final String title;
  final String description;
  final String emoji;
}
