import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/async_view.dart';

/// 看电影插件首页:两个 tab 「想看 / 看过」,右下角 FAB 新增。
///
/// 简单的备忘——每条电影只有片名 + 备注 + 是否看过三件事。点行编辑、长按
/// 删除、左侧圆圈一点切换看过 / 未看;看过的会在状态切换时由后端自动打时间戳。
class MovieListPage extends StatefulWidget {
  const MovieListPage({super.key});

  @override
  State<MovieListPage> createState() => _MovieListPageState();
}

class _MovieListPageState extends State<MovieListPage> {
  // 任一 tab 内增改删都通过这个计数器触发 _MoviesView 的重拉,避免互相耦合。
  int _reloadToken = 0;

  void _bumpReload() => setState(() => _reloadToken++);

  Future<void> _openCreateSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _MovieEditSheet(),
    );
    if (created == true) _bumpReload();
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: wo.bg,
        appBar: AppBar(
          title: const Text('看电影'),
          bottom: TabBar(
            indicatorColor: wo.movie,
            tabs: const [
              Tab(text: '想看'),
              Tab(text: '看过'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _MoviesView(
                watched: false,
                reloadToken: _reloadToken,
                onChanged: _bumpReload,
              ),
              _MoviesView(
                watched: true,
                reloadToken: _reloadToken,
                onChanged: _bumpReload,
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _openCreateSheet,
          backgroundColor: wo.movie,
          foregroundColor: wo.fg,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

/// 单个 tab 的电影列表。[watched] 决定拉哪一组;[reloadToken] 变化时重拉;
/// [onChanged] 被子项调用以通知父级让另一个 tab 也刷新。
class _MoviesView extends StatefulWidget {
  const _MoviesView({
    required this.watched,
    required this.reloadToken,
    required this.onChanged,
  });

  final bool watched;
  final int reloadToken;
  final VoidCallback onChanged;

  @override
  State<_MoviesView> createState() => _MoviesViewState();
}

class _MoviesViewState extends State<_MoviesView> {
  // `_future` 只驱动首屏 spinner;数据缓存进 `_movies`,之后的刷新(增删改、
  // 轮询、联动)静默就地替换,不闪——见 CLAUDE.md「列表页刷新不能闪一下」。
  // 尤其轮询:旧实现每 5 秒重置 _future,补充期间整列反复闪。
  late Future<List<Movie>> _future;
  List<Movie>? _movies;
  bool _loaded = false;

  // While any movie is still being enriched (ai_status == pending), poll a few
  // times so the intro / rating / poster appear without a manual refresh.
  Timer? _pollTimer;
  int _pollsLeft = 0;
  static const _maxPolls = 6;
  static const _pollInterval = Duration(seconds: 5);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _future = _fetch()..then(_store);
    }
  }

  @override
  void didUpdateWidget(covariant _MoviesView old) {
    super.didUpdateWidget(old);
    if (old.reloadToken != widget.reloadToken) {
      // A create/edit elsewhere may have added a pending movie — re-arm polling.
      _pollsLeft = _maxPolls;
      _refreshSilently();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<List<Movie>> _fetch() {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    return familyId == null
        ? Future.value(const <Movie>[])
        : session.api.movies(familyId, watched: widget.watched);
  }

  void _store(List<Movie> list) {
    if (!mounted) return;
    setState(() => _movies = list);
    _maybePoll(list);
  }

  /// 首屏加载失败后的重试:清空数据,回到 spinner 重新拉。
  Future<void> _retryFirstLoad() {
    setState(() {
      _movies = null;
      _future = _fetch()..then(_store);
    });
    return _future;
  }

  /// 刷新:保留当前列表,后台静默拉取后就地替换,不闪 spinner。
  Future<void> _refreshSilently() async {
    try {
      final list = await _fetch();
      _store(list);
    } catch (_) {
      // 拉取失败就继续显示旧数据。
    }
  }

  /// Called after a list resolves: if anything is still enriching, schedule the
  /// next poll; otherwise stop. Self-limiting via [_pollsLeft].
  void _maybePoll(List<Movie> list) {
    final anyPending = list.any((m) => m.aiPending);
    _pollTimer?.cancel();
    if (!anyPending) {
      _pollsLeft = 0;
      return;
    }
    if (_pollsLeft <= 0) _pollsLeft = _maxPolls;
    _pollsLeft -= 1;
    if (_pollsLeft <= 0) return;
    _pollTimer = Timer(_pollInterval, () {
      if (mounted) _refreshSilently();
    });
  }

  Future<void> _toggleWatched(Movie m) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.updateMovie(familyId, m.id, watched: !m.watched);
      widget.onChanged();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _retryEnrich(Movie m) async {
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.enrichMovie(familyId, m.id);
      _pollsLeft = _maxPolls; // re-arm polling for the new pending state
      await _refreshSilently();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  Future<void> _openEditSheet(Movie m) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MovieEditSheet(existing: m),
    );
    if (changed == true) widget.onChanged();
  }

  Future<void> _confirmDelete(Movie m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除电影'),
        content: Text('确定删除「${m.title}」吗?'),
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
    if (ok != true || !mounted) return;
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    try {
      await session.api.deleteMovie(familyId, m.id);
      widget.onChanged();
    } catch (e) {
      if (mounted) _toast(e);
    }
  }

  void _toast(Object e) {
    final msg = switch (e) {
      ApiException ex => ex.message,
      NetworkException ex => ex.message,
      _ => '操作失败',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cached = _movies;
    return cached != null
        ? _buildList(context, cached)
        : AsyncView<List<Movie>>(
            future: _future,
            onRetry: _retryFirstLoad,
            builder: _buildList,
          );
  }

  Widget _buildList(BuildContext context, List<Movie> list) {
    if (list.isEmpty) {
      return _Empty(watched: widget.watched);
    }
    return RefreshIndicator(
      onRefresh: _refreshSilently,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          WoTokens.space3,
          WoTokens.space3,
          WoTokens.space3,
          100, // 给 FAB 留空间
        ),
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: WoTokens.space2),
        itemBuilder: (_, i) => _MovieRow(
          movie: list[i],
          onTap: () => _openEditSheet(list[i]),
          onLongPress: () => _confirmDelete(list[i]),
          onToggle: () => _toggleWatched(list[i]),
          onRetry: () => _retryEnrich(list[i]),
        ),
      ),
    );
  }
}

class _MovieRow extends StatelessWidget {
  const _MovieRow({
    required this.movie,
    required this.onTap,
    required this.onLongPress,
    required this.onToggle,
    required this.onRetry,
  });

  final Movie movie;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggle;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Material(
      color: wo.bgElev,
      borderRadius: BorderRadius.circular(WoTokens.cardRadius),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(WoTokens.cardRadius),
        child: Padding(
          padding: const EdgeInsets.all(WoTokens.space3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Poster(movie: movie),
              const SizedBox(width: WoTokens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      movie.title,
                      style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: movie.watched ? wo.fgMid : wo.fg,
                        decoration:
                            movie.watched ? TextDecoration.lineThrough : null,
                        decorationColor: wo.fgDim,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    _AiLine(movie: movie, onRetry: onRetry),
                    if (movie.intro != null && movie.intro!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        movie.intro!,
                        style: t.bodySmall
                            ?.copyWith(color: wo.fgMid, height: 1.35),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (movie.note != null && movie.note!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        movie.note!,
                        style: t.bodySmall?.copyWith(color: wo.fgDim),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: WoTokens.space2),
              // 看过 / 想看 切换圆圈。拦截 tap,长按仍交给外层删除。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onToggle,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: movie.watched ? wo.movie : Colors.transparent,
                    border: Border.all(
                      color: movie.watched ? wo.movie : wo.fgDim,
                      width: 2,
                    ),
                  ),
                  child: movie.watched
                      ? Icon(Icons.check, size: 18, color: wo.fg)
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 海报缩略图（2:3 比例）。有海报显示真图,没有则用占位;补充中显示转圈。
class _Poster extends StatelessWidget {
  const _Poster({required this.movie});
  final Movie movie;

  static const double _w = 56;
  static const double _h = 80;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final radius = BorderRadius.circular(8);
    Widget placeholder({Widget? child}) => Container(
          width: _w,
          height: _h,
          decoration: BoxDecoration(color: wo.bgTint, borderRadius: radius),
          alignment: Alignment.center,
          child: child ?? const Text('🎬', style: TextStyle(fontSize: 24)),
        );

    if (movie.posterUrl != null && movie.posterUrl!.isNotEmpty) {
      final api = WoScope.api(context);
      return ClipRRect(
        borderRadius: radius,
        child: CachedNetworkImage(
          imageUrl: '${api.baseUrl}${movie.posterUrl!}',
          httpHeaders: api.imageHeaders,
          width: _w,
          height: _h,
          fit: BoxFit.cover,
          placeholder: (_, __) => placeholder(),
          errorWidget: (_, __, ___) => placeholder(),
        ),
      );
    }
    if (movie.aiPending) {
      return placeholder(
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return placeholder();
  }
}

/// 编辑弹层顶部的只读 AI 信息块：海报 + 评分 + 完整简介 + 状态。
class _AiInfoBlock extends StatelessWidget {
  const _AiInfoBlock({required this.movie});
  final Movie movie;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(WoTokens.space3),
      decoration: BoxDecoration(
        color: wo.bgTint,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Poster(movie: movie),
          const SizedBox(width: WoTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (movie.doubanRating != null) ...[
                  Row(
                    children: [
                      const Icon(
                        Icons.star_rounded,
                        size: 16,
                        color: Color(0xFFE0A800),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${movie.doubanRating!.toStringAsFixed(1)} 豆瓣',
                        style: t.labelMedium?.copyWith(
                          color: wo.fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                if (movie.aiPending)
                  Text('AI 补充中…', style: t.bodySmall?.copyWith(color: wo.fgMid))
                else if (movie.aiFailed)
                  Text(
                    'AI 补充失败',
                    style: t.bodySmall?.copyWith(color: wo.fgMid),
                  )
                else if (movie.intro != null && movie.intro!.isNotEmpty)
                  Text(
                    movie.intro!,
                    style: t.bodySmall?.copyWith(color: wo.fgMid, height: 1.4),
                  )
                else
                  Text('暂无简介', style: t.bodySmall?.copyWith(color: wo.fgDim)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 评分 + AI 状态行：⭐评分 / 「AI 补充中…」/「补充失败 · 重试」。
class _AiLine extends StatelessWidget {
  const _AiLine({required this.movie, required this.onRetry});
  final Movie movie;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    if (movie.aiPending) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: wo.movie),
          ),
          const SizedBox(width: 6),
          Text('AI 补充中…', style: t.labelSmall?.copyWith(color: wo.fgMid)),
        ],
      );
    }

    if (movie.aiFailed) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onRetry,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.refresh, size: 14, color: wo.movie),
            const SizedBox(width: 4),
            Text(
              '补充失败 · 点此重试',
              style: t.labelSmall?.copyWith(
                color: wo.movie,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    if (movie.doubanRating != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 16, color: Color(0xFFE0A800)),
          const SizedBox(width: 2),
          Text(
            '${movie.doubanRating!.toStringAsFixed(1)} 豆瓣',
            style: t.labelMedium?.copyWith(
              color: wo.fg,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.watched});
  final bool watched;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🎬', style: TextStyle(fontSize: 48)),
          const SizedBox(height: WoTokens.space2),
          Text(
            watched ? '还没看过任何一部' : '还没想看的',
            style: t.bodyMedium?.copyWith(color: wo.fgMid),
          ),
        ],
      ),
    );
  }
}

/// 新建 / 编辑电影的底部弹层。返回 true 表示有改动,父级据此重拉列表。
class _MovieEditSheet extends StatefulWidget {
  const _MovieEditSheet({this.existing});

  /// 非空表示编辑现有项;空表示新建。
  final Movie? existing;

  @override
  State<_MovieEditSheet> createState() => _MovieEditSheetState();
}

class _MovieEditSheetState extends State<_MovieEditSheet> {
  late final TextEditingController _title;
  late final TextEditingController _note;
  late bool _watched;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    _note = TextEditingController(text: widget.existing?.note ?? '');
    _watched = widget.existing?.watched ?? false;
  }

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写片名')),
      );
      return;
    }
    setState(() => _saving = true);
    final session = WoScope.of(context);
    final familyId = session.currentFamilyId;
    if (familyId == null) return;
    final nav = Navigator.of(context);
    try {
      final note = _note.text.trim();
      if (widget.existing == null) {
        await session.api.createMovie(
          familyId,
          title: title,
          note: note.isEmpty ? null : note,
        );
      } else {
        await session.api.updateMovie(
          familyId,
          widget.existing!.id,
          title: title,
          note: note,
          watched: _watched,
        );
      }
      if (mounted) nav.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _toast(e);
      }
    }
  }

  void _toast(Object e) {
    final msg = switch (e) {
      ApiException ex => ex.message,
      NetworkException ex => ex.message,
      _ => '保存失败',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final isEdit = widget.existing != null;
    return Padding(
      // 让弹层在键盘弹起时不被挡。
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            WoTokens.space4,
            WoTokens.space4,
            WoTokens.space4,
            WoTokens.space3,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isEdit ? '编辑电影' : '新增电影',
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (!isEdit) ...[
                const SizedBox(height: WoTokens.space2),
                Text(
                  '只填片名就行,保存后 AI 会自动补上简介、豆瓣评分和海报。',
                  style: t.labelSmall?.copyWith(color: wo.fgMid),
                ),
              ],
              if (isEdit && widget.existing!.aiStatus != 'none') ...[
                const SizedBox(height: WoTokens.space3),
                _AiInfoBlock(movie: widget.existing!),
              ],
              const SizedBox(height: WoTokens.space3),
              TextField(
                controller: _title,
                autofocus: !isEdit,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: '片名',
                  hintText: '例:瞬息全宇宙',
                ),
              ),
              const SizedBox(height: WoTokens.space2),
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  labelText: '备注(可选)',
                  hintText: '哪里看到的 / 谁推荐的 / 简单想说几句',
                ),
              ),
              if (isEdit) ...[
                const SizedBox(height: WoTokens.space2),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('已经看过了'),
                  value: _watched,
                  activeColor: wo.movie,
                  onChanged: (v) => setState(() => _watched = v),
                ),
              ],
              const SizedBox(height: WoTokens.space3),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: WoTokens.space3),
                  Expanded(
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: wo.movie,
                        foregroundColor: wo.fg,
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
