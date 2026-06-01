import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';

/// 采买新增 / 编辑页。[existing] 为空 = 新增。保存成功后 `Navigator.pop(true)`。
class BuyItemEditPage extends StatefulWidget {
  const BuyItemEditPage({super.key, this.existing});

  final BuyItem? existing;

  @override
  State<BuyItemEditPage> createState() => _BuyItemEditPageState();
}

class _BuyItemEditPageState extends State<BuyItemEditPage> {
  static const _emojis = [
    '🛒',
    '🧻',
    '🥬',
    '🍎',
    '🥛',
    '🍞',
    '🥚',
    '🧴',
    '🍗',
    '🐟',
    '🧂',
    '🍚',
    '🧼',
    '💊',
    '🔋',
    '🐾',
  ];

  late String _emoji;
  late final TextEditingController _name;
  late final TextEditingController _wantQty;
  late final TextEditingController _note;

  bool _submitting = false;
  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final b = widget.existing;
    _emoji = b?.emoji ?? '🛒';
    _name = TextEditingController(text: b?.name ?? '');
    _wantQty = TextEditingController(text: b?.wantQty ?? '');
    _note = TextEditingController(text: b?.note ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _wantQty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final wantQty = _wantQty.text.trim();
    final note = _note.text.trim();

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      if (_isEditing) {
        await session.api.updateBuyItem(
          familyId,
          widget.existing!.id,
          name: name,
          emoji: _emoji,
          wantQty: wantQty.isEmpty ? null : wantQty,
          note: note.isEmpty ? null : note,
        );
      } else {
        await session.api.createBuyItem(
          familyId,
          name: name,
          emoji: _emoji,
          wantQty: wantQty.isEmpty ? null : wantQty,
          note: note.isEmpty ? null : note,
        );
      }
      if (mounted) nav.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        _toast(e);
      }
    }
  }

  void _toast(Object error) {
    final msg = switch (error) {
      ApiException e => e.message,
      NetworkException e => e.message,
      _ => '操作失败',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final canSave = _name.text.trim().isNotEmpty && !_submitting;

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: Text(_isEditing ? '编辑采买' : '加采买')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 52,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _emojis.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: WoTokens.space2),
                  itemBuilder: (_, i) {
                    final e = _emojis[i];
                    final sel = e == _emoji;
                    return GestureDetector(
                      onTap: () => setState(() => _emoji = e),
                      child: Container(
                        width: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: sel
                              ? wo.stock.withValues(alpha: 0.45)
                              : wo.bgTint,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: sel ? wo.stock : Colors.transparent,
                            width: 1.5,
                          ),
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 26)),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              TextField(
                controller: _name,
                maxLength: 64,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '要买什么',
                  hintText: '比如「鸡蛋」「酱油」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              TextField(
                controller: _wantQty,
                maxLength: 32,
                decoration: const InputDecoration(
                  labelText: '想买多少（可选）',
                  hintText: '2 瓶 / 一大袋',
                  counterText: '',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  hintText: '牌子、规格、去哪买……',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              FilledButton(
                onPressed: canSave ? _save : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isEditing ? '保存' : '添加'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
