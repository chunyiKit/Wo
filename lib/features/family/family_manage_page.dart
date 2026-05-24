import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/async_view.dart';
import '../../widgets/wo_card.dart';

/// 家庭管理：GET /families/{id} + /families/{id}/members。
class FamilyManagePage extends StatefulWidget {
  const FamilyManagePage({super.key});

  @override
  State<FamilyManagePage> createState() => _FamilyManagePageState();
}

class _FamilyManagePageState extends State<FamilyManagePage> {
  Future<(Family, List<Member>)>? _future;
  String? _familyId;

  Future<(Family, List<Member>)> _load(String familyId) async {
    final api = WoScope.api(context);
    final results = await Future.wait([
      api.getFamily(familyId),
      api.members(familyId),
    ]);
    return (results[0] as Family, results[1] as List<Member>);
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final familyId = WoScope.of(context).currentFamilyId;

    if (familyId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('家庭管理')),
        body: Center(
          child: Text('还没有家庭', style: t.titleMedium?.copyWith(color: wo.fgMid)),
        ),
      );
    }

    // 当前家庭变化（切换家庭）时重建 future。
    if (_familyId != familyId) {
      _familyId = familyId;
      _future = _load(familyId);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('家庭管理')),
      body: SafeArea(
        top: false,
        child: AsyncView<(Family, List<Member>)>(
          future: _future!,
          onRetry: () => setState(() => _future = _load(familyId)),
          builder: (context, data) {
            final family = data.$1;
            final members = data.$2;
            return ListView(
              padding: const EdgeInsets.all(WoTokens.space5),
              children: [
                WoCard(
                  color: wo.accentSoft,
                  padding: const EdgeInsets.all(WoTokens.space6),
                  child: Row(
                    children: [
                      Text(family.emoji, style: const TextStyle(fontSize: 40)),
                      const SizedBox(width: WoTokens.space4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(family.name, style: t.titleLarge),
                            Text(
                              [
                                if (family.slogan != null &&
                                    family.slogan!.isNotEmpty)
                                  family.slogan!,
                                if (family.createdAt != null)
                                  '创建于 ${_ymd(family.createdAt!)}',
                              ].join(' · '),
                              style: t.bodySmall?.copyWith(color: wo.fgMid),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: WoTokens.space5),
                Row(
                  children: [
                    Text('成员 · ${family.memberCount}', style: t.titleMedium),
                    const Spacer(),
                    if (family.myRole == 'owner' || family.myRole == 'admin')
                      FilledButton.tonal(
                        onPressed: () => context.push(WoRoutes.familyInvite),
                        child: const Text('+ 邀请'),
                      ),
                  ],
                ),
                const SizedBox(height: WoTokens.space2),
                for (final m in members) _member(context, m),
                const SizedBox(height: WoTokens.space5),
                Text('设置', style: t.titleMedium),
                const SizedBox(height: WoTokens.space2),
                WoCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: const [
                      ListTile(
                        title: Text('家庭名称'),
                        trailing: Icon(Icons.chevron_right),
                      ),
                      Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        title: Text('家庭标语'),
                        trailing: Icon(Icons.chevron_right),
                      ),
                      Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        title: Text('家庭通知'),
                        trailing: Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: WoTokens.space5),
                if (family.myRole != 'owner')
                  TextButton(
                    onPressed: () {},
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.redAccent),
                    child: const Text('离开家庭'),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _member(BuildContext context, Member m) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final pending = m.status == 'pending';
    return Padding(
      padding: const EdgeInsets.only(bottom: WoTokens.space2),
      child: WoCard(
        padding: const EdgeInsets.symmetric(
          horizontal: WoTokens.space4,
          vertical: WoTokens.space3,
        ),
        child: Row(
          children: [
            Text(m.avatarEmoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: WoTokens.space3),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      m.displayName,
                      style: t.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (pending) ...[
                    const SizedBox(width: 6),
                    Text(
                      '· 待接受',
                      style: t.bodySmall?.copyWith(color: wo.fgDim),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: WoTokens.space3,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: wo.bgTint,
                borderRadius: BorderRadius.circular(WoTokens.chipRadius),
              ),
              child: Text(_roleLabel(m.role), style: t.labelSmall),
            ),
          ],
        ),
      ),
    );
  }
}

String _roleLabel(String role) => switch (role) {
      'owner' => '主理人 👑',
      'admin' => '管理员',
      'child' => '孩子',
      'pet' => '宠物',
      _ => '家人',
    };

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
