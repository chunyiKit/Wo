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

  /// 把当前菜谱的食材打包加入「囤货铺」的采买清单——选要加哪些 + 全选,然后一次
  /// 性发 N 个 createBuyItem。即使用户没装囤货铺这条 API 也照样接受写入(只检查
  /// 家庭成员身份),装上了就能看到。
  Future<void> _openBuySheet() async {
    final r = _recipe;
    if (r.ingredients.isEmpty) return;
    final picked = await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BuySelectSheet(ingredients: r.ingredients),
    );
    if (picked == null || picked.isEmpty || !mounted) return;

    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('正在加入采买清单…'),
        duration: Duration(seconds: 30),
      ),
    );

    // 食材一般 ≤ 15 条,并发发出去比串行快;任一失败也不阻塞其它。
    final note = '来自菜谱「${r.name}」';
    int ok = 0;
    int fail = 0;
    await Future.wait(
      picked.map((idx) async {
        final ing = r.ingredients[idx];
        try {
          await session.api.createBuyItem(
            familyId,
            name: ing.name,
            emoji: '🛒',
            wantQty: ing.amount.isEmpty ? null : ing.amount,
            note: note,
          );
          ok++;
        } catch (_) {
          fail++;
        }
      }),
    );
    messenger.hideCurrentSnackBar();
    if (!mounted) return;
    final text = fail == 0 ? '已加入采买清单($ok 项)' : '已加入 $ok 项,$fail 项失败';
    messenger.showSnackBar(SnackBar(content: Text(text)));
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
                // 有食材时才显示「加入采买」入口——空列表点了也没东西可挑。
                action: r.ingredients.isEmpty
                    ? null
                    : TextButton.icon(
                        onPressed: _openBuySheet,
                        icon:
                            const Icon(Icons.shopping_cart_outlined, size: 16),
                        label: const Text('加入采买'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: WoTokens.space2,
                          ),
                          minimumSize: const Size(0, 32),
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: wo.accentDeep,
                        ),
                      ),
              ),
              const SizedBox(height: WoTokens.space3),
              if (r.ingredients.isEmpty)
                _EmptyHint(text: '还没填食材')
              else
                WoCard(
                  child: Column(
                    children: [
                      for (var i = 0; i < r.ingredients.length; i++) ...[
                        if (i > 0)
                          Divider(height: WoTokens.space4, color: wo.hairline),
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
  const _SectionTitle({
    required this.icon,
    required this.title,
    this.trailing,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? trailing;

  /// 可选的右侧动作按钮（如「加入采买」），跟 [trailing] 文字并存——文字在左、
  /// 按钮在右——按钮为空时仅展示 [trailing]。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(icon, size: 18, color: wo.accentDeep),
        const SizedBox(width: WoTokens.space2),
        Text(title,
            style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const Spacer(),
        if (trailing != null)
          Text(trailing!, style: t.bodySmall?.copyWith(color: wo.fgMid)),
        if (action != null) ...[
          if (trailing != null) const SizedBox(width: WoTokens.space2),
          action!,
        ],
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

/// 选要加入采买清单的食材。用户取消返回 null;确认返回选中的下标列表。
///
/// 弹层自身限定最大高度为屏幕 75%——食材多的菜谱(20+ 条)需要滚动而不是挤死;
/// 一行一个 CheckboxListTile 展示「名字 + 数量」,顶部一个「全选 / 全不选」按钮。
class _BuySelectSheet extends StatefulWidget {
  const _BuySelectSheet({required this.ingredients});
  final List<RecipeIngredient> ingredients;

  @override
  State<_BuySelectSheet> createState() => _BuySelectSheetState();
}

class _BuySelectSheetState extends State<_BuySelectSheet> {
  late final Set<int> _selected;

  @override
  void initState() {
    super.initState();
    // 默认全选——最常见的意图是「这道菜要做,把缺的全加进采买」,默认勾上少
    // 一步操作;不想要某项再去掉就行。
    _selected = {for (var i = 0; i < widget.ingredients.length; i++) i};
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == widget.ingredients.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll([for (var i = 0; i < widget.ingredients.length; i++) i]);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final all = _selected.length == widget.ingredients.length;
    final none = _selected.isEmpty;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏 + 全选/全不选切换。
            Padding(
              padding: const EdgeInsets.fromLTRB(
                WoTokens.space4,
                WoTokens.space4,
                WoTokens.space2,
                WoTokens.space2,
              ),
              child: Row(
                children: [
                  Text(
                    '加入采买清单',
                    style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _toggleAll,
                    child: Text(all ? '全不选' : '全选'),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: wo.hairline),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.ingredients.length,
                itemBuilder: (_, i) {
                  final ing = widget.ingredients[i];
                  final sel = _selected.contains(i);
                  return CheckboxListTile(
                    value: sel,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected.add(i);
                      } else {
                        _selected.remove(i);
                      }
                    }),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(ing.name),
                    subtitle: ing.amount.isEmpty ? null : Text(ing.amount),
                    dense: true,
                  );
                },
              ),
            ),
            Divider(height: 1, color: wo.hairline),
            Padding(
              padding: const EdgeInsets.all(WoTokens.space3),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: WoTokens.space3),
                  Expanded(
                    child: FilledButton(
                      onPressed: none
                          ? null
                          : () => Navigator.of(context).pop(
                                _selected.toList()..sort(),
                              ),
                      child: Text(
                        none ? '加入采买' : '加入采买 (${_selected.length})',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
