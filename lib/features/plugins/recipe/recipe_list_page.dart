import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';
import '../../../widgets/wo_card.dart';
import 'recipe_edit_page.dart';
import 'recipe_detail_page.dart';
import 'recipe_style.dart';

/// 菜谱首页：分类筛选 + 封面卡片双列网格浏览。
class RecipeListPage extends StatefulWidget {
  const RecipeListPage({super.key});

  @override
  State<RecipeListPage> createState() => _RecipeListPageState();
}

class _RecipeListPageState extends State<RecipeListPage> {
  // `_future` 只驱动首屏 spinner;数据缓存进 `_items`,之后的增删改静默就地替换,
  // 不闪——见 CLAUDE.md「列表页刷新不能闪一下」。
  late Future<List<Recipe>> _future;
  List<Recipe>? _items;
  bool _loaded = false;

  // null = 全部。仅做内存筛选，避免每次切分类都打一次网络。
  String? _category;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  Future<List<Recipe>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <Recipe>[])
        : session.api.recipes(familyId);
  }

  void _store(List<Recipe> list) {
    if (mounted) setState(() => _items = list);
  }

  Future<void> _retry() {
    setState(() {
      _items = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  Future<void> _refreshSilently() async {
    try {
      final list = await _fetch();
      if (mounted) setState(() => _items = list);
    } catch (_) {
      // 拉取失败就继续显示旧数据,不打断操作。
    }
    // 列表变化会影响首页卡片预览,刷新一次 bootstrap。
    if (mounted) await WoScope.of(context).refresh();
  }

  Future<void> _openEditor() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RecipeEditPage()),
    );
    if (changed == true) await _refreshSilently();
  }

  Future<void> _openDetail(Recipe r) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => RecipeDetailPage(recipe: r)),
    );
    if (changed == true) await _refreshSilently();
  }

  List<Recipe> _filter(List<Recipe> all) => _category == null
      ? all
      : all.where((r) => r.category == _category).toList();

  // 数据里实际出现过的分类，按推荐顺序排，其余追加在后面。
  List<String> _categoriesOf(List<Recipe> all) {
    final present =
        all.map((r) => r.category).where((c) => c.isNotEmpty).toSet();
    final ordered = [
      for (final c in kRecipeCategories)
        if (present.contains(c)) c,
    ];
    final extras = present.where((c) => !kRecipeCategories.contains(c));
    return [...ordered, ...extras];
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('菜谱')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openEditor,
        icon: const Icon(Icons.add),
        label: const Text('加菜谱'),
      ),
      body: SafeArea(
        child: _items != null
            ? _buildBody(context, _items!)
            : AsyncView<List<Recipe>>(
                future: _future,
                onRetry: _retry,
                builder: _buildBody,
              ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, List<Recipe> all) {
    if (all.isEmpty) return _Empty(onAdd: _openEditor);
    final cats = _categoriesOf(all);
    final items = _filter(all);
    return Column(
      children: [
        _CategoryBar(
          categories: cats,
          selected: _category,
          onSelect: (c) => setState(() => _category = c),
        ),
        Expanded(
          child: items.isEmpty
              ? const _EmptyCategory()
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    WoTokens.space4,
                    WoTokens.space2,
                    WoTokens.space4,
                    100,
                  ),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: WoTokens.space4,
                    crossAxisSpacing: WoTokens.space4,
                    childAspectRatio: 0.74,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, i) => _RecipeCard(
                    recipe: items[i],
                    onTap: () => _openDetail(items[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 顶部横向分类筛选：全部 + 数据里出现过的菜系。
class _CategoryBar extends StatelessWidget {
  const _CategoryBar({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final cats = <(String?, String)>[
      (null, '全部'),
      for (final c in categories) (c, c),
    ];
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: WoTokens.space4),
        itemCount: cats.length,
        separatorBuilder: (_, __) => const SizedBox(width: WoTokens.space2),
        itemBuilder: (_, i) {
          final (value, label) = cats[i];
          return _CategoryChip(
            label: label,
            selected: value == selected,
            onTap: () => onSelect(value),
          );
        },
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: WoTokens.space4),
        decoration: BoxDecoration(
          color: selected ? wo.accent : wo.bgElev,
          borderRadius: BorderRadius.circular(WoTokens.chipRadius),
          border: Border.all(color: selected ? wo.accent : wo.hairline),
        ),
        child: Text(
          label,
          style: t.labelLarge?.copyWith(
            color: selected ? Colors.white : wo.fgMid,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 单个菜谱卡片：封面（emoji 占位）+ 名称 + 时长/难度。
class _RecipeCard extends StatelessWidget {
  const _RecipeCard({required this.recipe, required this.onTap});

  final Recipe recipe;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return WoCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1.25,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(WoTokens.cardRadius),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RecipeCover(recipe: recipe),
                  if (recipe.category.isNotEmpty)
                    Positioned(
                      left: WoTokens.space2,
                      top: WoTokens.space2,
                      child: _CategoryTag(label: recipe.category),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WoTokens.space3,
              WoTokens.space3,
              WoTokens.space3,
              WoTokens.space4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  recipe.name,
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: WoTokens.space2),
                Row(
                  children: [
                    Icon(Icons.schedule, size: 14, color: wo.fgDim),
                    const SizedBox(width: 3),
                    Text(
                      recipe.minutes > 0 ? '${recipe.minutes}分钟' : '—',
                      style: t.labelSmall?.copyWith(color: wo.fgMid),
                    ),
                    const Spacer(),
                    DifficultyDots(level: recipe.difficulty),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTag extends StatelessWidget {
  const _CategoryTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: WoTokens.space2, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(WoTokens.chipRadius),
      ),
      child: Text(
        label,
        style: t.labelSmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🍳', style: TextStyle(fontSize: 48)),
            const SizedBox(height: WoTokens.space4),
            Text('还没有菜谱', style: t.titleMedium),
            const SizedBox(height: WoTokens.space2),
            Text(
              '把家里的拿手菜记下来，全家一起看着做。',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: WoTokens.space5),
            FilledButton(onPressed: onAdd, child: const Text('添加第一道菜')),
          ],
        ),
      ),
    );
  }
}

class _EmptyCategory extends StatelessWidget {
  const _EmptyCategory();

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🍽️', style: TextStyle(fontSize: 40)),
            const SizedBox(height: WoTokens.space3),
            Text(
              '这个分类还没有菜谱',
              style: t.bodyMedium?.copyWith(color: wo.fgMid),
            ),
          ],
        ),
      ),
    );
  }
}
