import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_client.dart';
import '../../data/wo_session.dart';
import '../../navigation/wo_routes.dart';
import '../../theme/wo_tokens.dart';
import '../../widgets/wo_card.dart';

/// 创建新家：实时预览卡 + emoji 网格 + 名字 + 标语。
/// 提交 POST /families，成功后自动切到新家并进首页。
class CreateFamilyPage extends StatefulWidget {
  const CreateFamilyPage({super.key});

  @override
  State<CreateFamilyPage> createState() => _CreateFamilyPageState();
}

class _CreateFamilyPageState extends State<CreateFamilyPage> {
  static const _emojis = [
    '🏡',
    '🌿',
    '🌸',
    '☕️',
    '🐱',
    '🐶',
    '🎈',
    '🌙',
    '🍊',
    '🍞',
    '📚',
    '🎨',
  ];

  String _emoji = '🏡';
  final _name = TextEditingController(text: '');
  final _slogan = TextEditingController(text: '');
  bool _submitting = false;

  @override
  void dispose() {
    _name.dispose();
    _slogan.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final session = WoScope.of(context);
    final router = GoRouter.of(context);
    try {
      final family = await session.api.createFamily(
        name: name,
        slogan: _slogan.text.trim(),
        emoji: _emoji,
      );
      // 新家设为当前并刷新首屏缓存。
      await session.switchFamily(family.id);
      if (mounted) router.go(WoRoutes.home);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              switch (e) {
                ApiException a => a.message,
                NetworkException a => a.message,
                _ => '创建失败',
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
      appBar: AppBar(title: const Text('创建新家')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              WoCard(
                padding: const EdgeInsets.all(WoTokens.space6),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: wo.accentSoft,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(_emoji, style: const TextStyle(fontSize: 28)),
                    ),
                    const SizedBox(width: WoTokens.space4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _name.text.isEmpty ? '你的家' : _name.text,
                            style: t.titleLarge,
                          ),
                          if (_slogan.text.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              _slogan.text,
                              style: t.bodySmall?.copyWith(color: wo.fgMid),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: WoTokens.space6),
              Text('挑一个 emoji', style: t.titleMedium),
              const SizedBox(height: WoTokens.space3),
              GridView.count(
                crossAxisCount: 6,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: WoTokens.space2,
                mainAxisSpacing: WoTokens.space2,
                children: [
                  for (final e in _emojis)
                    GestureDetector(
                      onTap: () => setState(() => _emoji = e),
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: e == _emoji ? wo.accentSoft : wo.bgTint,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: e == _emoji ? wo.accent : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 24)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: WoTokens.space6),
              TextField(
                controller: _name,
                maxLength: 16,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '家的名字',
                  hintText: '比如「老陈和小林的窝」',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _slogan,
                maxLength: 24,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '家的标语（可选）',
                  hintText: '一句话形容你们的窝',
                ),
              ),
              const SizedBox(height: WoTokens.space6),
              FilledButton(
                onPressed:
                    (_name.text.trim().isEmpty || _submitting) ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('建好我的窝'),
              ),
              const SizedBox(height: WoTokens.space2),
              Text(
                '你将成为这个家的「主理人 👑」',
                style: t.bodySmall?.copyWith(color: wo.fgMid),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
