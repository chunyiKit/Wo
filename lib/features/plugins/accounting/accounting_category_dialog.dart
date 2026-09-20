import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_api.dart';
import '../../../theme/wo_tokens.dart';

/// 新增成功才关闭；失败保留输入，便于修改或重试。
class AccountingCategoryDialog extends StatefulWidget {
  const AccountingCategoryDialog({
    super.key,
    required this.api,
    required this.familyId,
    required this.categories,
  });

  final WoApi api;
  final String familyId;
  final List<ExpenseCategory> categories;

  @override
  State<AccountingCategoryDialog> createState() =>
      _AccountingCategoryDialogState();
}

class _AccountingCategoryDialogState extends State<AccountingCategoryDialog> {
  final _name = TextEditingController();
  String _emoji = '💰';
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final label = _name.text.trim();
    if (label.isEmpty) {
      setState(() => _error = '请输入分类名称');
      return;
    }
    if (widget.categories.any((c) => c.label == label)) {
      setState(() => _error = '分类名称已存在');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final category = await widget.api.createAccountingCategory(
        widget.familyId,
        label: label,
        emoji: _emoji,
      );
      if (mounted) Navigator.of(context).pop(category);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = switch (error) {
            ApiException e => e.message,
            NetworkException e => e.message,
            _ => '新增失败，请重试',
          };
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return PopScope(
      canPop: !_saving,
      child: WoAlertDialog(
        title: const Text('新增分类'),
        scrollable: true,
        content: SizedBox(
          width: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('保存后全家可用，取消记账也会保留此分类。', style: TextStyle(color: wo.fgMid)),
              const SizedBox(height: WoTokens.space4),
              WoTextField(
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                maxLength: 20,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  labelText: '分类名称',
                  hintText: '例如：旅行、医疗、学习',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              const Text('分类图标'),
              const SizedBox(height: WoTokens.space2),
              Wrap(
                spacing: WoTokens.space2,
                runSpacing: WoTokens.space2,
                children: [
                  for (final emoji in const [
                    '💰',
                    '✈️',
                    '🏥',
                    '📚',
                    '🏠',
                    '🎁',
                    '🎮',
                    '🏃',
                    '👶',
                    '👕',
                    '💄',
                    '🚌',
                    '🍎',
                    '🌷',
                    '🎬',
                    '🛠️',
                  ])
                    Semantics(
                      label: '图标 $emoji',
                      selected: _emoji == emoji,
                      child: ChoiceChip(
                        label:
                            Text(emoji, style: const TextStyle(fontSize: 20)),
                        selected: _emoji == emoji,
                        showCheckmark: false,
                        onSelected: _saving
                            ? null
                            : (_) => setState(() => _emoji = emoji),
                      ),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: WoTokens.space3),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          WoTextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          WoFilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '保存中…' : '保存分类'),
          ),
        ],
      ),
    );
  }
}
