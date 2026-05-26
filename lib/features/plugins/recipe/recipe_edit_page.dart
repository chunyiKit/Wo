import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'recipe_image.dart';
import 'recipe_style.dart';

/// 菜谱新增 / 编辑页。
///
/// [existing] 为空 = 新增；非空 = 编辑。保存成功后 `Navigator.pop(true)`。
class RecipeEditPage extends StatefulWidget {
  const RecipeEditPage({super.key, this.existing});

  final Recipe? existing;

  @override
  State<RecipeEditPage> createState() => _RecipeEditPageState();
}

class _RecipeEditPageState extends State<RecipeEditPage> {
  static const _emojis = [
    '🍳', '🍅', '🥩', '🍗', '🍲', '🥣', '🍜', '🍚',
    '🥗', '🍰', '🥟', '🌶️', '🐟', '🦐', '🥦', '🍢',
  ];

  late String _emoji;
  late String _category;
  late int _difficulty;
  late final TextEditingController _name;
  late final TextEditingController _minutes;
  late final TextEditingController _servings;
  late final TextEditingController _note;

  // 动态食材行：每行一对（名称、用量）控制器。
  final List<(TextEditingController, TextEditingController)> _ingredients = [];
  // 动态步骤行。
  final List<TextEditingController> _steps = [];

  // 新选的封面（已压缩，待保存后上传）。null = 没选新图。
  Uint8List? _pendingCoverBytes;
  // 编辑模式下，用户主动移除了原有封面 → 保存后调用删除接口。
  bool _removeCover = false;
  bool _picking = false;

  // 家庭共享的标签清单（后端加载，可增删）。
  List<String> _tags = [];
  bool _tagsLoading = true;
  bool _tagsLoaded = false;

  bool _submitting = false;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    _emoji = r?.emoji ?? '🍳';
    _category = r?.category ?? '';
    _difficulty = r?.difficulty ?? 1;
    _name = TextEditingController(text: r?.name ?? '');
    _minutes = TextEditingController(
      text: (r?.minutes ?? 0) > 0 ? '${r!.minutes}' : '',
    );
    _servings = TextEditingController(
      text: r?.servings != null ? '${r!.servings}' : '',
    );
    _note = TextEditingController(text: r?.note ?? '');

    for (final ing in r?.ingredients ?? const <RecipeIngredient>[]) {
      _ingredients.add(
        (
          TextEditingController(text: ing.name),
          TextEditingController(text: ing.amount),
        ),
      );
    }
    if (_ingredients.isEmpty) _addIngredient();

    for (final s in r?.steps ?? const <String>[]) {
      _steps.add(TextEditingController(text: s));
    }
    if (_steps.isEmpty) _addStep();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_tagsLoaded) {
      _tagsLoaded = true;
      _loadTags();
    }
  }

  Future<void> _loadTags() async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) {
      if (mounted) setState(() => _tagsLoading = false);
      return;
    }
    try {
      final tags = await session.api.recipeTags(familyId);
      if (mounted) {
        setState(() {
          _tags = tags;
          _tagsLoading = false;
        });
      }
    } catch (_) {
      // 加载失败不致命：至少还能用当前分类。失败时回退到推荐默认集。
      if (mounted) {
        setState(() {
          _tags = List.of(kRecipeCategories);
          _tagsLoading = false;
        });
      }
    }
  }

  // 展示用的标签集：后端清单 + 当前分类（即便它已被移出清单也保留可见）。
  List<String> get _displayTags => [
        ..._tags,
        if (_category.isNotEmpty && !_tags.contains(_category)) _category,
      ];

  Future<void> _addTag() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 16,
          decoration: const InputDecoration(hintText: '比如「夜宵」「下午茶」'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      final tags = await session.api.addRecipeTag(familyId, name);
      if (mounted) {
        setState(() {
          _tags = tags;
          _category = name; // 新建后顺手选中
        });
      }
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _deleteTag(String tag) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除标签'),
        content: Text('确定删除标签「$tag」吗？已用这个分类的菜谱不受影响。'),
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
    try {
      final tags = await session.api.deleteRecipeTag(familyId, tag);
      if (mounted) {
        setState(() {
          _tags = tags;
          if (_category == tag) _category = '';
        });
      }
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _minutes.dispose();
    _servings.dispose();
    _note.dispose();
    for (final (n, a) in _ingredients) {
      n.dispose();
      a.dispose();
    }
    for (final s in _steps) {
      s.dispose();
    }
    super.dispose();
  }

  void _addIngredient() => setState(
        () => _ingredients.add(
          (TextEditingController(), TextEditingController()),
        ),
      );

  void _removeIngredient(int i) {
    final (n, a) = _ingredients[i];
    n.dispose();
    a.dispose();
    setState(() => _ingredients.removeAt(i));
  }

  void _addStep() => setState(() => _steps.add(TextEditingController()));

  void _removeStep(int i) {
    _steps[i].dispose();
    setState(() => _steps.removeAt(i));
  }

  // 当前是否有封面照片可显示（新选的 or 编辑时未被移除的旧图）。
  bool get _showsExistingCover =>
      _isEditing &&
      widget.existing!.hasCover &&
      _pendingCoverBytes == null &&
      !_removeCover;

  bool get _hasAnyCover => _pendingCoverBytes != null || _showsExistingCover;

  Future<void> _pickCover() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final bytes = await pickAndCompressCover();
      if (bytes != null && mounted) {
        setState(() {
          _pendingCoverBytes = bytes;
          _removeCover = false;
        });
      }
    } catch (e) {
      if (mounted) _toast(e);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _clearCover() {
    setState(() {
      if (_pendingCoverBytes != null) {
        _pendingCoverBytes = null; // 撤销刚选的新图
      } else if (_isEditing && widget.existing!.hasCover) {
        _removeCover = true; // 标记移除旧图（保存时删）
      }
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _submitting) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;

    final ingredients = [
      for (final (n, a) in _ingredients)
        if (n.text.trim().isNotEmpty)
          RecipeIngredient(name: n.text.trim(), amount: a.text.trim()),
    ];
    final steps = [
      for (final s in _steps)
        if (s.text.trim().isNotEmpty) s.text.trim(),
    ];
    final minutes = int.tryParse(_minutes.text.trim()) ?? 0;
    final servings = int.tryParse(_servings.text.trim());
    final note = _note.text.trim();

    setState(() => _submitting = true);
    final nav = Navigator.of(context);
    try {
      // 先存菜谱本体，拿到 id 后再处理封面（新建时此前没有 id 可上传）。
      final Recipe saved;
      if (_isEditing) {
        saved = await session.api.updateRecipe(
          familyId,
          widget.existing!.id,
          name: name,
          emoji: _emoji,
          category: _category,
          minutes: minutes,
          difficulty: _difficulty,
          servings: servings,
          note: note.isEmpty ? null : note,
          ingredients: ingredients,
          steps: steps,
        );
      } else {
        saved = await session.api.createRecipe(
          familyId,
          name: name,
          emoji: _emoji,
          category: _category,
          minutes: minutes,
          difficulty: _difficulty,
          servings: servings,
          note: note.isEmpty ? null : note,
          ingredients: ingredients,
          steps: steps,
        );
      }

      if (_pendingCoverBytes != null) {
        await session.api
            .uploadRecipeCover(familyId, saved.id, bytes: _pendingCoverBytes!);
      } else if (_removeCover) {
        await session.api.deleteRecipeCover(familyId, saved.id);
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
      appBar: AppBar(title: Text(_isEditing ? '编辑菜谱' : '加菜谱')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(WoTokens.space5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 封面照片：选了照片用照片，否则用下面挑的 emoji。
              _CoverPicker(
                pendingBytes: _pendingCoverBytes,
                existing: _showsExistingCover ? widget.existing : null,
                emoji: _emoji,
                tint: recipeTintFor(
                  _name.text.trim().isNotEmpty ? _name.text.trim() : _emoji,
                ),
                busy: _picking,
                hasCover: _hasAnyCover,
                onPick: _pickCover,
                onClear: _clearCover,
              ),
              const SizedBox(height: WoTokens.space5),
              // emoji 选择
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
                          color: sel ? wo.accentSoft : wo.bgTint,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: sel ? wo.accent : Colors.transparent,
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
                  labelText: '菜名',
                  hintText: '比如「番茄炒蛋」',
                ),
              ),
              const SizedBox(height: WoTokens.space3),
              Row(
                children: [
                  Text('分类', style: t.titleSmall),
                  const SizedBox(width: WoTokens.space2),
                  Text(
                    '长按标签可删除',
                    style: t.bodySmall?.copyWith(color: wo.fgDim),
                  ),
                ],
              ),
              const SizedBox(height: WoTokens.space2),
              if (_tagsLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: WoTokens.space2),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Wrap(
                  spacing: WoTokens.space2,
                  runSpacing: WoTokens.space2,
                  children: [
                    for (final c in _displayTags)
                      GestureDetector(
                        onLongPress: () => _deleteTag(c),
                        child: ChoiceChip(
                          label: Text(c),
                          selected: _category == c,
                          onSelected: (_) => setState(
                            () => _category = _category == c ? '' : c,
                          ),
                        ),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: const Text('新建标签'),
                      onPressed: _addTag,
                    ),
                  ],
                ),
              const SizedBox(height: WoTokens.space4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _minutes,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '时长',
                        suffixText: '分钟',
                      ),
                    ),
                  ),
                  const SizedBox(width: WoTokens.space4),
                  Expanded(
                    child: TextField(
                      controller: _servings,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '份量',
                        suffixText: '人份',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: WoTokens.space4),
              Text('难度', style: t.titleSmall),
              const SizedBox(height: WoTokens.space2),
              Row(
                children: [
                  for (var d = 1; d <= 3; d++) ...[
                    Expanded(
                      child: ChoiceChip(
                        label: Center(child: Text(difficultyLabel(d))),
                        selected: _difficulty == d,
                        onSelected: (_) => setState(() => _difficulty = d),
                      ),
                    ),
                    if (d < 3) const SizedBox(width: WoTokens.space2),
                  ],
                ],
              ),
              const SizedBox(height: WoTokens.space5),
              _RowHeader(
                title: '食材',
                onAdd: _addIngredient,
              ),
              const SizedBox(height: WoTokens.space2),
              for (var i = 0; i < _ingredients.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: WoTokens.space2),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _ingredients[i].$1,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '食材',
                          ),
                        ),
                      ),
                      const SizedBox(width: WoTokens.space2),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _ingredients[i].$2,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '用量',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.remove_circle_outline, color: wo.fgDim),
                        onPressed: _ingredients.length > 1
                            ? () => _removeIngredient(i)
                            : null,
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: WoTokens.space4),
              _RowHeader(title: '步骤', onAdd: _addStep),
              const SizedBox(height: WoTokens.space2),
              for (var i = 0; i < _steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: WoTokens.space2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Text(
                          '${i + 1}.',
                          style: t.titleMedium?.copyWith(color: wo.accentDeep),
                        ),
                      ),
                      const SizedBox(width: WoTokens.space2),
                      Expanded(
                        child: TextField(
                          controller: _steps[i],
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: '这一步做什么',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.remove_circle_outline, color: wo.fgDim),
                        onPressed:
                            _steps.length > 1 ? () => _removeStep(i) : null,
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: WoTokens.space4),
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '小贴士（可选）',
                  hintText: '火候、替代食材、家人口味……',
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

class _RowHeader extends StatelessWidget {
  const _RowHeader({required this.title, required this.onAdd});
  final String title;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Text(title, style: t.titleSmall),
        const Spacer(),
        TextButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加'),
        ),
      ],
    );
  }
}

/// 封面照片选择区：16:9 预览 + 选图/移除按钮。
///
/// 预览优先级：新选的图 [pendingBytes] > 编辑时保留的旧图 [existing] > emoji 占位。
class _CoverPicker extends StatelessWidget {
  const _CoverPicker({
    required this.pendingBytes,
    required this.existing,
    required this.emoji,
    required this.tint,
    required this.busy,
    required this.hasCover,
    required this.onPick,
    required this.onClear,
  });

  final Uint8List? pendingBytes;
  final Recipe? existing;
  final String emoji;
  final Color tint;
  final bool busy;
  final bool hasCover;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    Widget preview;
    if (pendingBytes != null) {
      preview = Image.memory(pendingBytes!, fit: BoxFit.cover);
    } else if (existing != null) {
      preview = RecipeCover(recipe: existing!, emojiSize: 64);
    } else {
      preview = DecoratedBox(
        decoration: BoxDecoration(color: tint),
        child: Center(child: Text(emoji, style: const TextStyle(fontSize: 64))),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(WoTokens.cardRadius),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                preview,
                if (busy)
                  ColoredBox(
                    color: Colors.black.withValues(alpha: 0.25),
                    child: const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: WoTokens.space2),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : onPick,
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text(hasCover ? '换封面照片' : '上传封面照片'),
              ),
            ),
            if (hasCover) ...[
              const SizedBox(width: WoTokens.space2),
              TextButton(
                onPressed: busy ? null : onClear,
                child: Text('改用 emoji', style: TextStyle(color: wo.fgMid)),
              ),
            ],
          ],
        ),
        if (!hasCover)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '没上传照片时，用下面挑的 emoji 当封面',
              style: t.bodySmall?.copyWith(color: wo.fgDim),
            ),
          ),
      ],
    );
  }
}
