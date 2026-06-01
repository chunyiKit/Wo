import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';

/// 推荐的菜系分类（用户也可自己写新的）。
const kRecipeCategories = ['早餐', '午餐', '晚餐', '汤羹', '烘焙', '小食'];

/// 难度文案：1 简单 / 2 中等 / 3 有点难。
String difficultyLabel(int level) => switch (level) {
      1 => '简单',
      2 => '中等',
      _ => '有点难',
    };

/// 封面占位底色。没有真实图片时，按菜名稳定地从暖色系里挑一个，
/// 让列表里相邻卡片颜色有变化又不会每次刷新都变。
const _tints = [
  Color(0xFFFCE4D4), // 暖橙
  Color(0xFFE8D4A8), // 焦糖
  Color(0xFFF0C4B4), // 蜜桃
  Color(0xFFD6DCC8), // 抹茶
  Color(0xFFE8DCC8), // 奶咖
];

Color recipeTintFor(String key) => _tints[key.hashCode.abs() % _tints.length];

Color recipeTint(Recipe r) =>
    recipeTintFor(r.name.isNotEmpty ? r.name : r.emoji);

/// 菜谱封面：有上传照片就显示照片（带版本缓存），否则回退到 emoji + 暖色底。
///
/// 照片地址里带 `?v=版本号`，cached_network_image 以完整 URL 为缓存键，
/// 版本变化即视为新图，自动刷新本地缓存。
class RecipeCover extends StatelessWidget {
  const RecipeCover({
    super.key,
    required this.recipe,
    this.emojiSize = 52,
  });

  final Recipe recipe;
  final double emojiSize;

  @override
  Widget build(BuildContext context) {
    final emoji = _EmojiCover(recipe: recipe, size: emojiSize);
    if (!recipe.hasCover) return emoji;

    final api = WoScope.api(context);
    final url = api.recipeCoverUrl(recipe);
    if (url == null) return emoji;

    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: api.imageHeaders,
      fit: BoxFit.cover,
      // 完整 URL（含 ?v=）即缓存键，无需自定义 cacheKey。
      placeholder: (_, __) => _EmojiCover(recipe: recipe, size: emojiSize),
      errorWidget: (_, __, ___) => _EmojiCover(recipe: recipe, size: emojiSize),
    );
  }
}

class _EmojiCover extends StatelessWidget {
  const _EmojiCover({required this.recipe, required this.size});
  final Recipe recipe;
  final double size;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: recipeTint(recipe)),
      child: Center(
        child: Text(recipe.emoji, style: TextStyle(fontSize: size)),
      ),
    );
  }
}

/// 难度用 1–3 个点表示。
class DifficultyDots extends StatelessWidget {
  const DifficultyDots({super.key, required this.level});

  final int level; // 1..3

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 3; i++)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i <= level ? wo.accent : wo.hairline,
              ),
            ),
          ),
      ],
    );
  }
}
