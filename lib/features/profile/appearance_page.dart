import 'package:flutter/material.dart';

import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_cinema.dart';

/// 外观设置：浅色 / 深色 / 跟随系统。选择即时生效并持久化（见 [WoSession.setThemeMode]）。
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = WoScope.of(context);
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    return WoScaffold(
      appBar: WoAppBar(title: const Text('外观')),
      body: SafeArea(
        top: false,
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: session.themeMode,
          builder: (context, mode, _) => RadioGroup<ThemeMode>(
            groupValue: mode,
            onChanged: (v) {
              if (v != null) session.setThemeMode(v);
            },
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: WoTokens.space2),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: WoCinemaMasthead(
                    title: '日落影院',
                    subtitle: '用光影，把平凡的日子收藏。',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    WoTokens.space5,
                    WoTokens.space3,
                    WoTokens.space5,
                    WoTokens.space2,
                  ),
                  child: Text(
                    '主题',
                    style: t.bodySmall?.copyWith(color: wo.fgMid),
                  ),
                ),
                const _Option(
                  value: ThemeMode.light,
                  title: '暖纸 · 浅色',
                  subtitle: '始终使用浅色外观',
                  icon: Icons.light_mode_outlined,
                ),
                const _Option(
                  value: ThemeMode.dark,
                  title: '影院 · 深色',
                  subtitle: '酒棕底色与琥珀微光，推荐外观',
                  icon: Icons.dark_mode_outlined,
                ),
                const _Option(
                  value: ThemeMode.system,
                  title: '跟随系统',
                  subtitle: '随系统设置自动切换',
                  icon: Icons.brightness_auto_outlined,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.value,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final ThemeMode value;
  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return RadioListTile<ThemeMode>(
      value: value,
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      controlAffinity: ListTileControlAffinity.trailing,
    );
  }
}
