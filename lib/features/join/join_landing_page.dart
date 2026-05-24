import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';

/// 加入 / 创建家庭入口选择页。
class JoinLandingPage extends StatelessWidget {
  const JoinLandingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(WoTokens.space6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('开始你的窝', style: t.displaySmall),
              const SizedBox(height: WoTokens.space2),
              Text(
                '加入已有家庭，或者从头创建一个新窝。',
                style: t.bodyLarge?.copyWith(color: wo.fgMid),
              ),
              const SizedBox(height: WoTokens.space8),
              WoCard(
                color: wo.accentSoft,
                padding: const EdgeInsets.all(WoTokens.space6),
                onTap: () => context.push(WoRoutes.joinByCode),
                child: Row(
                  children: [
                    const Text('🤝', style: TextStyle(fontSize: 36)),
                    const SizedBox(width: WoTokens.space4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('加入已有家庭', style: t.titleLarge),
                          const SizedBox(height: 4),
                          Text(
                            '通过邀请码或二维码加入',
                            style: t.bodyMedium?.copyWith(color: wo.fgMid),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: wo.fgMid),
                  ],
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              WoCard(
                padding: const EdgeInsets.all(WoTokens.space6),
                onTap: () => context.push(WoRoutes.createFamily),
                child: Row(
                  children: [
                    const Text('🏡', style: TextStyle(fontSize: 36)),
                    const SizedBox(width: WoTokens.space4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('创建一个新家', style: t.titleLarge),
                          const SizedBox(height: 4),
                          Text(
                            '从零开始建立你的窝',
                            style: t.bodyMedium?.copyWith(color: wo.fgMid),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: wo.fgMid),
                  ],
                ),
              ),
              const Spacer(),
              Center(
                child: TextButton(
                  onPressed: () => context.go(WoRoutes.home),
                  child: const Text('先逛逛 →'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
