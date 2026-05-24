import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  Future<InvitationResult>? _future;
  String? _familyId;

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
      _future = WoScope.api(context).createInvitation(familyId);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('邀请成员')),
      body: SafeArea(
        top: false,
        child: AsyncView<InvitationResult>(
          future: _future!,
          onRetry: () => setState(
            () => _future = WoScope.api(context).createInvitation(familyId),
          ),
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
                      '通过邀请加入的成员默认身份为「家人」，可在「家庭管理」里调整为管理员。',
                      style: t.bodyMedium?.copyWith(color: wo.fgMid),
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
            decoration: BoxDecoration(
              color: wo.bgTint,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.qr_code_2, size: 160),
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
