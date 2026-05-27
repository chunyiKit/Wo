import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/member_avatar.dart';
import '../../../widgets/wo_card.dart';
import 'recipe_edit_page.dart';
import 'recipe_style.dart';

/// 菜谱详情页：封面 + 元信息 + 食材清单 + 步骤。
///
/// 编辑 / 删除后把最新状态带回列表（`Navigator.pop(true)` 触发列表刷新）。
class RecipeDetailPage extends StatefulWidget {
  const RecipeDetailPage({super.key, required this.recipe});

  final Recipe recipe;

  @override
  State<RecipeDetailPage> createState() => _RecipeDetailPageState();
}

class _RecipeDetailPageState extends State<RecipeDetailPage> {
  late Recipe _recipe;

  // 本页对菜谱做过改动（编辑/删除）→ 返回时通知列表刷新。
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _recipe = widget.recipe;
  }

  Future<void> _edit() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => RecipeEditPage(existing: _recipe)),
    );
    if (saved != true || !mounted) return;
    _changed = true;
    // 重新拉一次拿到最新内容（编辑页只回传成功与否）。
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      final fresh = await session.api.recipe(familyId, _recipe.id);
      if (mounted) setState(() => _recipe = fresh);
    } catch (_) {
      // 拉取失败不致命，返回列表时仍会整体刷新。
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除菜谱'),
        content: Text('确定删除「${_recipe.name}」吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final nav = Navigator.of(context);
    try {
      await session.api.deleteRecipe(familyId, _recipe.id);
      if (mounted) nav.pop(true);
    } catch (e) {
      if (mounted) _toast(e);
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
    final r = _recipe;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: wo.bg,
        appBar: AppBar(
          title: Text(r.name),
          actions: [
            IconButton(
              tooltip: '编辑',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _edit,
            ),
            IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              WoTokens.space4,
              WoTokens.space4,
              WoTokens.space4,
              WoTokens.space8,
            ),
            children: [
              _Cover(recipe: r),
              const SizedBox(height: WoTokens.space4),
              _MetaRow(recipe: r),
              if (r.note != null && r.note!.isNotEmpty) ...[
                const SizedBox(height: WoTokens.space4),
                WoCard(
                  color: wo.bgTint,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('💡', style: TextStyle(fontSize: 18)),
                      const SizedBox(width: WoTokens.space2),
                      Expanded(
                        child: Text(
                          r.note!,
                          style: t.bodyMedium?.copyWith(color: wo.fgMid),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: WoTokens.space5),
              _SectionTitle(
                icon: Icons.egg_alt_outlined,
                title: '食材',
                trailing: r.servings != null ? '${r.servings} 人份' : null,
              ),
              const SizedBox(height: WoTokens.space3),
              if (r.ingredients.isEmpty)
                _EmptyHint(text: '还没填食材')
              else
                WoCard(
                  child: Column(
                    children: [
                      for (var i = 0; i < r.ingredients.length; i++) ...[
                        if (i > 0) Divider(height: WoTokens.space4, color: wo.hairline),
                        _IngredientRow(item: r.ingredients[i]),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: WoTokens.space5),
              _SectionTitle(icon: Icons.format_list_numbered, title: '步骤'),
              const SizedBox(height: WoTokens.space3),
              if (r.steps.isEmpty)
                _EmptyHint(text: '还没填步骤')
              else
                for (var i = 0; i < r.steps.length; i++) ...[
                  _StepRow(index: i + 1, text: r.steps[i]),
                  const SizedBox(height: WoTokens.space3),
                ],
              if (r.creatorName != null) ...[
                const SizedBox(height: WoTokens.space4),
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('由 ', style: t.bodySmall?.copyWith(color: wo.fgDim)),
                      MemberAvatar(
                        url: r.creatorAvatarUrl,
                        emoji: r.creatorEmoji ?? '👤',
                        size: 16,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${r.creatorName} 添加',
                        style: t.bodySmall?.copyWith(color: wo.fgDim),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.recipe});
  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(WoTokens.cardRadius),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: RecipeCover(recipe: recipe, emojiSize: 88),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.recipe});
  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        if (recipe.category.isNotEmpty) ...[
          _Pill(text: recipe.category),
          const SizedBox(width: WoTokens.space2),
        ],
        Icon(Icons.schedule, size: 16, color: wo.fgMid),
        const SizedBox(width: 4),
        Text(
          recipe.minutes > 0 ? '${recipe.minutes} 分钟' : '未填时长',
          style: t.bodyMedium?.copyWith(color: wo.fgMid),
        ),
        const Spacer(),
        Text(
          difficultyLabel(recipe.difficulty),
          style: t.bodyMedium?.copyWith(color: wo.fgMid),
        ),
        const SizedBox(width: WoTokens.space2),
        DifficultyDots(level: recipe.difficulty),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: WoTokens.space3, vertical: 4),
      decoration: BoxDecoration(
        color: wo.accentSoft,
        borderRadius: BorderRadius.circular(WoTokens.chipRadius),
      ),
      child: Text(
        text,
        style: t.labelMedium?.copyWith(
          color: wo.accentDeep,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title, this.trailing});
  final IconData icon;
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: wo.accentDeep),
        const SizedBox(width: WoTokens.space2),
        Text(title, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const Spacer(),
        if (trailing != null)
          Text(trailing!, style: t.bodySmall?.copyWith(color: wo.fgMid)),
      ],
    );
  }
}

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({required this.item});
  final RecipeIngredient item;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(child: Text(item.name, style: t.bodyLarge)),
        Text(
          item.amount,
          style: t.bodyMedium?.copyWith(color: wo.fgMid),
        ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.index, required this.text});
  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: wo.accent,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$index',
            style: t.labelMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: WoTokens.space3),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(text, style: t.bodyLarge?.copyWith(height: 1.4)),
          ),
        ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Text(text, style: t.bodyMedium?.copyWith(color: wo.fgDim));
  }
}
