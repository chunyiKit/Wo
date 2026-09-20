import 'package:flutter/material.dart';

import '../theme/wo_tokens.dart';
import '../theme/wo_typography.dart';

/// 品牌摄影只用于开场与章节封面，表单和长列表保持纯色以保证可读性。
class WoCinemaBackdrop extends StatelessWidget {
  const WoCinemaBackdrop({
    super.key,
    required this.child,
    this.alignment = const Alignment(.35, -.25),
  });
  final Widget child;
  final Alignment alignment;
  static const asset = 'assets/images/sunset-cinema.png';

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            asset,
            fit: BoxFit.cover,
            alignment: alignment,
            errorBuilder: (_, __, ___) =>
                const ColoredBox(color: Color(0xFF533021)),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, .42, .72, 1],
                colors: [
                  Color(0x5522110D),
                  Color(0x1122110D),
                  Color(0x5522110D),
                  Color(0xEE160F0D),
                ],
              ),
            ),
          ),
          child,
        ],
      );
}

class WoCinemaHeading extends StatelessWidget {
  const WoCinemaHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });
  final String title;
  final String subtitle;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 2,
                    color: wo.accentDeep,
                  ),
                ),
                const SizedBox(height: 7),
                Text(title, style: WoTypography.editorial(wo.fg, size: 24)),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 一次性入场，不随数据刷新重放；系统减少动画时直接展示。
class WoCinemaEntrance extends StatelessWidget {
  const WoCinemaEntrance({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(
          begin: MediaQuery.disableAnimationsOf(context) ? 1 : 0,
          end: 1,
        ),
        duration: const Duration(milliseconds: 650),
        curve: Curves.easeOutCubic,
        child: child,
        builder: (_, value, child) => Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 16 * (1 - value)),
            child: child,
          ),
        ),
      );
}

IconData woPluginIcon(String id) => switch (id) {
      'accounting' => Icons.account_balance_wallet_outlined,
      'anniversary' => Icons.auto_awesome_outlined,
      'memory' || 'photo' => Icons.photo_library_outlined,
      'chore' => Icons.check_circle_outline,
      'stock' => Icons.inventory_2_outlined,
      'recipe' => Icons.restaurant_outlined,
      'movie' => Icons.local_movies_outlined,
      'calendar' => Icons.calendar_month_outlined,
      'subscription' => Icons.credit_card_outlined,
      'plant' => Icons.spa_outlined,
      'retirement' => Icons.beach_access_outlined,
      'expiry' => Icons.timelapse_outlined,
      'travel' => Icons.explore_outlined,
      'pet' => Icons.pets_outlined,
      'chat' => Icons.forum_outlined,
      _ => Icons.widgets_outlined,
    };

class WoCinemaMasthead extends StatelessWidget {
  const WoCinemaMasthead({
    super.key,
    required this.title,
    required this.subtitle,
    this.height = 188,
  });
  final String title;
  final String subtitle;
  final double height;
  @override
  Widget build(BuildContext context) => SizedBox(
        height:
            height * MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.5),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: WoCinemaBackdrop(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: WoTypography.editorial(
                      const Color(0xFFFFEAD0),
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFFE9C9A7),
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// 空状态沿用细线图标与日落光晕，不用巨型 emoji 占满页面。
class WoEmptyMark extends StatelessWidget {
  const WoEmptyMark({super.key, this.icon = Icons.wb_twilight_outlined});
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [wo.accentSoft, wo.accentSoft.withValues(alpha: .12)],
        ),
        border: Border.all(color: wo.hairline, width: .7),
      ),
      child: Icon(icon, size: 32, color: wo.accentDeep),
    );
  }
}
