import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';

/// 片库:浏览 TMDB 电影,按「类型」多选 + 排序筛选,点开详情可加入「想看」。
///
/// 数据来自 TMDB 的 discover 接口(经后端代理),海报由 TMDB 图床直出。结果里
/// 已在本家庭片单的会标记「已在片单」。返回上一页时列表页会静默刷新。
class MovieDiscoverPage extends StatefulWidget {
  const MovieDiscoverPage({super.key});

  @override
  State<MovieDiscoverPage> createState() => _MovieDiscoverPageState();
}

/// 排序选项:展示名 → 后端 sort key。
const _sortOptions = <(String, String)>[
  ('热门', 'popular'),
  ('高分', 'rating'),
  ('最新', 'newest'),
];

class _MovieDiscoverPageState extends State<MovieDiscoverPage> {
  final _scroll = ScrollController();

  List<MovieGenre> _genres = const [];
  final Set<int> _selectedGenres = {};
  String _sort = 'popular';

  List<DiscoverMovie> _results = const [];
  int _page = 1;
  bool _hasMore = true;

  // 首屏:加载中 / 失败;翻页:加载更多。
  bool _loadingFirst = true;
  Object? _firstError;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadGenres();
    _loadFirst();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String? get _familyId => WoScope.of(context).currentFamilyId;

  Future<void> _loadGenres() async {
    final fid = _familyId;
    if (fid == null) return;
    try {
      final genres = await WoScope.api(context).movieGenres(fid);
      if (mounted) setState(() => _genres = genres);
    } catch (_) {
      // 类型加载失败不致命——仍可不限类型浏览。
    }
  }

  Future<List<DiscoverMovie>> _fetch(int page) {
    final fid = _familyId;
    if (fid == null) return Future.value(const []);
    return WoScope.api(context).movieDiscover(
      fid,
      genreIds: _selectedGenres.toList(),
      sort: _sort,
      page: page,
    );
  }

  /// 首屏 / 改筛选后重新拉第 1 页。
  Future<void> _loadFirst() async {
    setState(() {
      _loadingFirst = true;
      _firstError = null;
    });
    try {
      final list = await _fetch(1);
      if (!mounted) return;
      setState(() {
        _results = list;
        _page = 1;
        _hasMore = list.isNotEmpty;
        _loadingFirst = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _firstError = e;
        _loadingFirst = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loadingFirst) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final list = await _fetch(next);
      if (!mounted) return;
      setState(() {
        _page = next;
        _results = [..._results, ...list];
        _hasMore = list.isNotEmpty && next < 500;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  void _toggleGenre(int id) {
    setState(() {
      if (!_selectedGenres.remove(id)) _selectedGenres.add(id);
    });
    _loadFirst();
  }

  void _changeSort(String sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    _loadFirst();
  }

  /// 打开详情弹层;若用户在弹层里加入了片单,把该结果标记为已添加。
  Future<void> _openDetail(DiscoverMovie movie) async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DiscoverDetailSheet(movie: movie),
    );
    if (added == true && mounted) {
      setState(() {
        _results = [
          for (final m in _results)
            m.tmdbId == movie.tmdbId ? m.copyWith(alreadyAdded: true) : m,
        ];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(title: const Text('片库')),
      body: SafeArea(
        child: Column(
          children: [
            _FilterBar(
              genres: _genres,
              selected: _selectedGenres,
              sort: _sort,
              onToggleGenre: _toggleGenre,
              onChangeSort: _changeSort,
            ),
            const Divider(height: 1),
            Expanded(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    if (_loadingFirst) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_firstError != null) {
      return _ErrorRetry(error: _firstError!, onRetry: _loadFirst);
    }
    if (_results.isEmpty) {
      return Center(
        child:
            Text('没有符合条件的电影', style: t.bodyMedium?.copyWith(color: wo.fgMid)),
      );
    }

    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(WoTokens.space3),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.5,
              mainAxisSpacing: WoTokens.space3,
              crossAxisSpacing: WoTokens.space3,
            ),
            delegate: SliverChildBuilderDelegate(
              (_, i) => _DiscoverCard(
                movie: _results[i],
                onTap: () => _openDetail(_results[i]),
              ),
              childCount: _results.length,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: WoTokens.space4),
            child: Center(
              child: _loadingMore
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : (!_hasMore
                      ? Text(
                          '没有更多了',
                          style: t.labelSmall?.copyWith(color: wo.fgDim),
                        )
                      : const SizedBox.shrink()),
            ),
          ),
        ),
      ],
    );
  }
}

/// 顶部筛选区:排序(单选)+ 类型(多选)。类型多时内部纵向滚动,不挤占网格。
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.genres,
    required this.selected,
    required this.sort,
    required this.onToggleGenre,
    required this.onChangeSort,
  });

  final List<MovieGenre> genres;
  final Set<int> selected;
  final String sort;
  final void Function(int id) onToggleGenre;
  final void Function(String sort) onChangeSort;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WoTokens.space3,
        WoTokens.space3,
        WoTokens.space3,
        WoTokens.space2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final (label, key) in _sortOptions) ...[
                ChoiceChip(
                  label: Text(label),
                  selected: sort == key,
                  selectedColor: wo.movie.withValues(alpha: 0.18),
                  onSelected: (_) => onChangeSort(key),
                ),
                const SizedBox(width: WoTokens.space2),
              ],
            ],
          ),
          if (genres.isNotEmpty) ...[
            const SizedBox(height: WoTokens.space2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 168),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: WoTokens.space2,
                  runSpacing: WoTokens.space2,
                  children: [
                    for (final g in genres)
                      FilterChip(
                        label: Text(g.name),
                        selected: selected.contains(g.id),
                        selectedColor: wo.movie.withValues(alpha: 0.18),
                        checkmarkColor: wo.movie,
                        onSelected: (_) => onToggleGenre(g.id),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 网格里的一张片卡:海报(2:3)+ 片名 + 评分;已在片单的角标提示。
class _DiscoverCard extends StatelessWidget {
  const _DiscoverCard({required this.movie, required this.onTap});

  final DiscoverMovie movie;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(10);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _PosterImage(url: movie.posterUrl),
                  if (movie.alreadyAdded)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: wo.movie,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '已在片单',
                          style: t.labelSmall?.copyWith(
                            color: wo.fg,
                            fontWeight: FontWeight.w600,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            movie.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.labelMedium?.copyWith(color: wo.fg),
          ),
          if (movie.rating != null && movie.rating! > 0)
            Row(
              children: [
                const Icon(
                  Icons.star_rounded,
                  size: 13,
                  color: Color(0xFFE0A800),
                ),
                const SizedBox(width: 2),
                Text(
                  movie.rating!.toStringAsFixed(1),
                  style: t.labelSmall?.copyWith(color: wo.fgMid),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 海报图(空 / 失败回退到 🎬 占位)。[url] 是后端缩略图代理的相对地址,
/// 拼上 baseUrl + 鉴权头加载——手机不直连 TMDB 图床。
class _PosterImage extends StatelessWidget {
  const _PosterImage({required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    Widget placeholder() => Container(
          color: wo.bgTint,
          alignment: Alignment.center,
          child: const Text('🎬', style: TextStyle(fontSize: 28)),
        );
    if (url == null || url!.isEmpty) return placeholder();
    final api = WoScope.api(context);
    return CachedNetworkImage(
      imageUrl: '${api.baseUrl}${url!}',
      httpHeaders: api.imageHeaders,
      fit: BoxFit.cover,
      placeholder: (_, __) => placeholder(),
      errorWidget: (_, __, ___) => placeholder(),
    );
  }
}

/// 详情底部弹层:大海报 + 片名 + 年份·评分 + 简介,底部「加入想看 / 已在片单」。
/// 加入成功后 pop(true)。
class _DiscoverDetailSheet extends StatefulWidget {
  const _DiscoverDetailSheet({required this.movie});
  final DiscoverMovie movie;

  @override
  State<_DiscoverDetailSheet> createState() => _DiscoverDetailSheetState();
}

class _DiscoverDetailSheetState extends State<_DiscoverDetailSheet> {
  bool _adding = false;

  Future<void> _add() async {
    final session = WoScope.of(context);
    final fid = session.currentFamilyId;
    if (fid == null) return;
    setState(() => _adding = true);
    final nav = Navigator.of(context);
    try {
      await session.api.addMovieFromTmdb(fid, widget.movie.tmdbId);
      if (mounted) nav.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _adding = false);
      final msg = switch (e) {
        ApiException ex => ex.message,
        NetworkException ex => ex.message,
        _ => '加入失败',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final m = widget.movie;
    final meta = [
      if (m.year != null) m.year!,
      if (m.rating != null && m.rating! > 0)
        '★ ${m.rating!.toStringAsFixed(1)}',
    ].join('  ·  ');

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(WoTokens.space4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 100,
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: _PosterImage(url: m.posterUrl),
                    ),
                  ),
                ),
                const SizedBox(width: WoTokens.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.title,
                        style: t.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          meta,
                          style: t.labelMedium?.copyWith(color: wo.fgMid),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: WoTokens.space3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Text(
                  (m.overview != null && m.overview!.isNotEmpty)
                      ? m.overview!
                      : '暂无简介',
                  style: t.bodyMedium?.copyWith(color: wo.fgMid, height: 1.5),
                ),
              ),
            ),
            const SizedBox(height: WoTokens.space4),
            if (m.alreadyAdded)
              OutlinedButton(
                onPressed: null,
                child: const Text('已在片单'),
              )
            else
              FilledButton.icon(
                onPressed: _adding ? null : _add,
                style: FilledButton.styleFrom(
                  backgroundColor: wo.movie,
                  foregroundColor: wo.fg,
                ),
                icon: _adding
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: const Text('加入想看'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 首屏加载失败的占位:提示 + 重试(TMDB 未配置 / 不可达时常见)。
class _ErrorRetry extends StatelessWidget {
  const _ErrorRetry({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;
    final msg = switch (error) {
      ApiException ex => ex.message,
      NetworkException ex => ex.message,
      _ => '加载失败',
    };
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(msg, style: t.bodyMedium?.copyWith(color: wo.fgMid)),
          const SizedBox(height: WoTokens.space3),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
