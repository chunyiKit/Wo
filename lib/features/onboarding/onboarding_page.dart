import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';
import '../../theme/wo_typography.dart';
import '../../widgets/wo_cinema.dart';

/// 摄影开场：分页讲述家庭、插件和多个家的真实能力。
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});
  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _controller = PageController();
  int _index = 0;
  static const _steps = [
    ('把日子\n过成电影', '柴米油盐，都是浪漫。\n和家人一起，收藏生活的每一帧。'),
    ('小家的事\n都放在窝里', '记账、日程、回忆、家务……\n按需挑选插件，生活自有章法。'),
    ('心有所属\n不止一个家', '和爱人的窝，和爸妈的窝。\n轻轻切换，每个家都有自己的故事。'),
  ];
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_index == 2) {
      context.go(WoRoutes.login);
      return;
    }
    _controller.nextPage(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 480),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => WoScaffold(
        body: WoCinemaBackdrop(
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(26, 16, 16, 0),
                  child: Row(
                    children: [
                      const Text(
                        'WO / 我们的生活',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFFFFD7A9),
                          letterSpacing: 2,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => context.go(WoRoutes.login),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFFFEAD0),
                        ),
                        child: const Text('跳过'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: _steps.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (_, i) => SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(28, 50, 28, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '0${i + 1}  /  03',
                            style: const TextStyle(
                              color: Color(0xFFE9C9A7),
                              fontSize: 12,
                              letterSpacing: 3,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            _steps[i].$1,
                            style: WoTypography.editorial(
                              const Color(0xFFFFEAD0),
                              size: 42,
                            ),
                          ),
                          const SizedBox(height: 24),
                          Text(
                            _steps[i].$2,
                            style: const TextStyle(
                              color: Color(0xFFFFEAD0),
                              fontSize: 14,
                              height: 1.9,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 18, 28, 30),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < 3; i++)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 280),
                              width: i == _index ? 28 : 6,
                              height: 4,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: i == _index
                                    ? const Color(0xFFF2B779)
                                    : const Color(0x667E6250),
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _next,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFF2B779),
                            foregroundColor: const Color(0xFF2A170B),
                          ),
                          child: Text(_index == 2 ? '开启我们的故事' : '继续'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
