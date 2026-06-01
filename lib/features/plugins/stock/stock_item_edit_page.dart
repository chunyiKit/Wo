import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';

/// 囤货新增 / 编辑页。[existing] 为空 = 新增。保存成功后 `Navigator.pop(true)`。
class StockItemEditPage extends StatefulWidget {
  const StockItemEditPage({super.key, this.existing});

  final StockItem? existing;

  @override
  State<StockItemEditPage> createState() => _StockItemEditPageState();
}

class _StockItemEditPageState extends State<StockItemEditPage> {
  static const _emojis = [
    '📦',
    '🧻',
    '🧴',
    '🧼',
    '🥫',
    '🍚',
    '🧂',
    '🛢️',
    '🥛',
    '🧊',
    '🪥',
    '💊',
    '🔋',
    '💡',
    '🧺',
    '🐾',
  ];

  late String _emoji;
  late final TextEditingController _name;
  late final TextEditingController _qty;
  late final TextEditingController _unit;
  late final TextEditingController _lowAt;
  late final TextEditingController _note;

  bool _submitting = false;
  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final it = widget.existing;
    _emoji = it?.emoji ?? '📦';
    _name = TextEditingController(text: it?.name ?? '');
    _qty = TextEditingController(text: (it?.qty ?? 1).toString());
    _unit = TextEditingController(text: it?.unit ?? '');
    _lowAt = TextEditingController(text: it?.lowAt?.toString() ?? '');
    _note = TextEditingController(text: it?.note ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _unit.dispose();
    _lowAt.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;

    final qty = int.tryParse(_qty.text.trim()) ?? 0;
    final unit = _unit.text.trim();
    final lowText = _lowAt.text.trim();
    final lowAt = lowText.isEmpty ? null : int.tryParse(lowText);
    final note = _note.text.trim();

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      if (_isEditing) {
        await session.api.updateStockItem(
          familyId,
          widget.existing!.id,
          name: name,
          emoji: _emoji,
          qty: qty,
          unit: unit.isEmpty ? null : unit,
          lowAt: lowAt,
          note: note.isEmpty ? null : note,
        );
      } else {
        await session.api.createStockItem(
          familyId,
          name: name,
          emoji: _emoji,
          qty: qty,
          unit: unit.isEmpty ? null : unit,
          lowAt: lowAt,
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
    final t = Theme.of(context).textTheme;
    final canSave = _name.text.trim().isNotEmpty && !_submitting;

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: Text(_isEditing ? '编辑囤货' : '加囤货')),
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
                  labelText: '名称',
                  hintText: '比如「卫生纸」「洗衣液」',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qty,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '现有数量'),
                    ),
                  ),
                  const SizedBox(width: WoTokens.space3),
                  Expanded(
                    child: TextField(
                      controller: _unit,
                      maxLength: 16,
                      decoration: const InputDecoration(
                        labelText: '单位（可选）',
                        hintText: '卷 / 瓶 / 包',
                        counterText: '',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: WoTokens.space2),
              TextField(
                controller: _lowAt,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '低量提醒阈值（可选）',
                  hintText: '剩到几个时在首页告急，留空则不提醒',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '备注（可选）',
                  hintText: '放在哪、常买的牌子……',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: WoTokens.space4),
              Text(
                '提示：设了阈值后，数量降到阈值及以下会在首页提醒补货。',
                style: t.labelSmall?.copyWith(color: wo.fgDim),
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
