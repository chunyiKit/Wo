import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'stock_request_key.dart';

/// 囤货新增 / 编辑页。[existing] 为空 = 新增。保存成功后 `Navigator.pop(true)`。
class StockItemEditPage extends StatefulWidget {
  const StockItemEditPage({super.key, this.existing, this.stocktake = false});

  final StockItem? existing;
  final bool stocktake;

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
  bool _stocktakeRequired = false;
  final _requestKey = StockRequestKey();
  bool get _isStocktake => WoScope.api(context).isLocal && (widget.stocktake || _stocktakeRequired || widget.existing?.quantityConflict == true);
  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final it = widget.existing;
    _emoji = it?.emoji ?? '📦';
    _name = TextEditingController(text: it?.name ?? '');
    _qty = TextEditingController(text: it?.quantityConflict == true ? '' : (it?.qty ?? 1).toString());
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

    final qty = int.tryParse(_qty.text.trim());
    if (qty == null || qty < 0 || qty > 1000000000) { _toast(ApiException('VALIDATION_ERROR', '请填写0至10亿的整数数量')); return; }
    final unit = _unit.text.trim();
    final lowText = _lowAt.text.trim();
    final lowAt = lowText.isEmpty ? null : int.tryParse(lowText);
    if (lowText.isNotEmpty && (lowAt == null || lowAt < 0 || lowAt > 1000000000)) { _toast(ApiException('VALIDATION_ERROR', '告急阈值须为非负整数')); return; }
    final note = _note.text.trim();

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      final stocktake = _isStocktake;
      if (stocktake) {
        final confirmed = await showWoDialog<bool>(context: context, builder: (ctx) => WoAlertDialog(
          title: const Text('确认盘点数量'),
          content: Text('请确认刚盘点「$name」的实际数量为 $qty${unit.isEmpty ? '' : ' $unit'}。历史数量记录会保留。'),
          actions: [WoTextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('再核对一下')),
            WoFilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('确认实际数量'))]));
        if (confirmed != true || !mounted) { if (mounted) setState(() => _submitting = false); return; }
      }
      final clientId = session.api.isLocal ? _requestKey.forBody([familyId, widget.existing?.id, name, _emoji, qty, unit, lowAt, note, stocktake]) : null;
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
          baseQty: !stocktake && session.api.isLocal ? widget.existing!.rawQty : null,
          confirmStocktake: stocktake, clientId: clientId,
        );
      } else {
        await session.api.createStockItem(
          familyId,
          name: name,
          emoji: _emoji,
          qty: qty,
          unit: unit.isEmpty ? null : unit,
          lowAt: lowAt,
          note: note.isEmpty ? null : note, clientId: clientId,
        );
      }
      if (mounted) nav.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          if (e is ApiException && e.code == 'STOCK_QUANTITY_CONFLICT' && session.api.isLocal) _stocktakeRequired = true;
        });
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
    ScaffoldMessenger.of(context).showSnackBar(WoSnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final canSave = _name.text.trim().isNotEmpty && !_submitting;

    return WoScaffold(
      backgroundColor: wo.bg,
      appBar: WoAppBar(title: Text(_isStocktake ? '盘点囤货' : _isEditing ? '编辑囤货' : '加囤货')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_isStocktake) ...[
                Text('请盘点实际数量后填写。原显示账面数量：${widget.existing?.rawQty ?? 0}；常规加减暂停，保存前需要明确确认。',
                  style: t.bodyMedium?.copyWith(color: wo.warning)),
                const SizedBox(height: WoTokens.space3),
              ],
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
              WoTextField(
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
                    child: WoTextField(
                      controller: _qty,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: _isStocktake ? '盘点实际数量' : '现有数量'),
                    ),
                  ),
                  const SizedBox(width: WoTokens.space3),
                  Expanded(
                    child: WoTextField(
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
              WoTextField(
                controller: _lowAt,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '低量提醒阈值（可选）',
                  hintText: '剩到几个时在首页告急，留空则不提醒',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              WoTextField(
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
              WoFilledButton(
                onPressed: canSave ? _save : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: WoProgressIndicator(strokeWidth: 2),
                      )
                    : Text(_isStocktake ? '核对并确认盘点' : _isEditing ? '保存' : '添加'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
