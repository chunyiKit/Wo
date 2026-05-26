import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../data/models.dart';
import '../../data/wo_session.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/async_view.dart';
import '../../widgets/wo_card.dart';

/// 邀请成员：POST /families/{id}/invitations 生成一份邀请，
/// 在三种渠道（面对面 / 链接 / 邀请码）下展示同一邀请的二维码 / 链接 / 码。
class FamilyInvitePage extends StatefulWidget {
  const FamilyInvitePage({super.key});

  @override
  State<FamilyInvitePage> createState() => _FamilyInvitePageState();
}

class _FamilyInvitePageState extends State<FamilyInvitePage> {
  int _seg = 0;
  static const _tabs = ['面对面', '链接', '邀请码'];

  // 可邀请的加入身份（owner 不可邀请，需通过转移接管）。
  static const _roles = <(String, String)>[
    ('member', '家人'),
    ('admin', '管理员'),
    ('child', '孩子'),
    ('pet', '宠物'),
  ];

  Future<InvitationResult>? _future;
  String? _familyId;
  String _role = 'member';

  void _regen(BuildContext context, String familyId) {
    _future = WoScope.api(context).createInvitation(familyId, role: _role);
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final familyId = WoScope.of(context).currentFamilyId;

    if (familyId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('邀请成员')),
        body: Center(
          child: Text('还没有家庭', style: t.titleMedium?.copyWith(color: wo.fgMid)),
        ),
      );
    }
    if (_familyId != familyId) {
      _familyId = familyId;
      _regen(context, familyId);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('邀请成员')),
      body: SafeArea(
        top: false,
        child: AsyncView<InvitationResult>(
          future: _future!,
          onRetry: () => setState(() => _regen(context, familyId)),
          builder: (context, inv) => ListView(
            padding: const EdgeInsets.all(WoTokens.space5),
            children: [
              SegmentedButton<int>(
                segments: [
                  for (var i = 0; i < _tabs.length; i++)
                    ButtonSegment(value: i, label: Text(_tabs[i])),
                ],
                selected: {_seg},
                onSelectionChanged: (s) => setState(() => _seg = s.first),
              ),
              const SizedBox(height: WoTokens.space6),
              if (_seg == 0) _faceToFace(context, t, wo, inv),
              if (_seg == 1) _link(context, t, wo, inv),
              if (_seg == 2) _code(context, t, wo, inv),
              const SizedBox(height: WoTokens.space6),
              WoCard(
                padding: const EdgeInsets.all(WoTokens.space5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('加入身份', style: t.titleMedium),
                    const SizedBox(height: WoTokens.space2),
                    Text(
                      '选择对方加入后的身份，换身份会重新生成邀请。',
                      style: t.bodyMedium?.copyWith(color: wo.fgMid),
                    ),
                    const SizedBox(height: WoTokens.space3),
                    Wrap(
                      spacing: WoTokens.space2,
                      children: [
                        for (final r in _roles)
                          ChoiceChip(
                            label: Text(r.$2),
                            selected: _role == r.$1,
                            onSelected: (_) {
                              if (_role == r.$1) return;
                              setState(() {
                                _role = r.$1;
                                _regen(context, familyId);
                              });
                            },
                          ),
                      ],
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

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  Widget _faceToFace(
    BuildContext context,
    TextTheme t,
    WoColors wo,
    InvitationResult inv,
  ) {
    return WoCard(
      padding: const EdgeInsets.all(WoTokens.space6),
      child: Column(
        children: [
          Container(
            width: 200,
            height: 200,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(WoTokens.space3),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: inv.qrPayload,
              size: 176,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: WoTokens.space4),
          Text('请对方扫码加入', style: t.titleMedium),
          const SizedBox(height: 4),
          SelectableText(
            inv.qrPayload,
            style: t.bodySmall?.copyWith(color: wo.fgMid),
            textAlign: TextAlign.center,
          ),
          if (inv.expiresAt != null) ...[
            const SizedBox(height: 4),
            Text(
              '有效期至 ${_hm(inv.expiresAt!)}',
              style: t.bodySmall?.copyWith(color: wo.fgDim),
            ),
          ],
        ],
      ),
    );
  }

  Widget _link(
    BuildContext context,
    TextTheme t,
    WoColors wo,
    InvitationResult inv,
  ) {
    return WoCard(
      padding: const EdgeInsets.all(WoTokens.space5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              inv.link,
              style: t.bodyLarge?.copyWith(color: wo.accentDeep),
            ),
          ),
          FilledButton.tonal(
            onPressed: () => _copy(inv.link, '链接'),
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  Widget _code(
    BuildContext context,
    TextTheme t,
    WoColors wo,
    InvitationResult inv,
  ) {
    return WoCard(
      padding: const EdgeInsets.all(WoTokens.space6),
      child: Column(
        children: [
          SelectableText(
            inv.code,
            style: t.displaySmall?.copyWith(
              color: wo.accentDeep,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: WoTokens.space2),
          Text('把这串码发给对方', style: t.bodySmall?.copyWith(color: wo.fgMid)),
          const SizedBox(height: WoTokens.space4),
          FilledButton.tonal(
            onPressed: () => _copy(inv.code, '邀请码'),
            child: const Text('复制邀请码'),
          ),
        ],
      ),
    );
  }
}

String _hm(DateTime d) =>
    '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
