import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/wo_network_image.dart';

/// 选择一段「回忆」来与旅行关联(1 对 1)。按回忆的地点(location)/标题模糊搜索;
/// [seedQuery] 用于进场预填(添加页传当前选中的城市 / 具体地点)。返回所选 [Memory]。
Future<Memory?> showMemoryLinkSheet(
  BuildContext context, {
  String? seedQuery,
}) {
  return showModalBottomSheet<Memory>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _MemoryLinkSheet(seedQuery: seedQuery),
  );
}

class _MemoryLinkSheet extends StatefulWidget {
  const _MemoryLinkSheet({this.seedQuery});
  final String? seedQuery;

  @override
  State<_MemoryLinkSheet> createState() => _MemoryLinkSheetState();
}

class _MemoryLinkSheetState extends State<_MemoryLinkSheet> {
  List<Memory>? _all; // null = 首屏加载中
  bool _failed = false;
  late final TextEditingController _searchCtrl =
      TextEditingController(text: widget.seedQuery?.trim() ?? '');
  late String _q = _searchCtrl.text;

  WoSession get _session => WoScope.of(context);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await _session.api.memories(_session.currentFamilyId!);
      if (mounted) setState(() => _all = list);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// 过滤 + 排序:location 命中优先、其次标题命中;空查询按原顺序(时间倒序)全列。
  List<Memory> _filtered() {
    final all = _all ?? const <Memory>[];
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return all;
    bool inLoc(Memory m) => (m.location ?? '').toLowerCase().contains(q);
    bool inTitle(Memory m) => m.title.toLowerCase().contains(q);
    final loc = [for (final m in all) if (inLoc(m)) m];
    final titleOnly = [
      for (final m in all)
        if (!inLoc(m) && inTitle(m)) m,
    ];
    return [...loc, ...titleOnly];
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final list = _filtered();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color: wo.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: wo.hairline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Text('关联回忆',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: wo.fg,),),
                  const Spacer(),
                  Text('按地点搜索',
                      style: TextStyle(fontSize: 12, color: wo.fgDim),),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
              child: TextField(
                autofocus: _q.isEmpty,
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: '搜索回忆(地点 / 标题)',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: wo.bgTint,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(child: _body(wo, list)),
          ],
        ),
      ),
    );
  }

  Widget _body(WoColors wo, List<Memory> list) {
    if (_failed) {
      return _Hint(wo: wo, text: '加载回忆失败,请稍后再试', onRetry: () {
        setState(() => _failed = false);
        _load();
      },);
    }
    if (_all == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if ((_all ?? const []).isEmpty) {
      return _Hint(wo: wo, text: '还没有回忆。先去「回忆」里记一段吧');
    }
    if (list.isEmpty) {
      return _Hint(wo: wo, text: '没有匹配的回忆');
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: list.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) => _row(wo, list[i]),
    );
  }

  Widget _row(WoColors wo, Memory m) {
    final cover = m.media.where((e) => !e.isVideo).isNotEmpty
        ? m.media.firstWhere((e) => !e.isVideo)
        : null;
    return InkWell(
      onTap: () => Navigator.of(context).pop(m),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 56,
                height: 56,
                child: cover != null
                    ? WoNetworkImage(
                        url: _session.api.memoryMediaUrl(cover),
                        headers: _session.api.imageHeaders,
                        placeholderColor: wo.memory,
                        decodeWidth: 120,
                      )
                    : Container(
                        color: wo.memory.withValues(alpha: 0.25),
                        alignment: Alignment.center,
                        child: const Text('📸', style: TextStyle(fontSize: 22)),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    m.title.isEmpty ? '一段回忆' : m.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: wo.fg,),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (m.location != null && m.location!.isNotEmpty) ...[
                        Icon(Icons.place_outlined, size: 13, color: wo.fgDim),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            m.location!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: wo.fgMid),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        _fmtDate(m.eventDate),
                        style: TextStyle(fontSize: 12, color: wo.fgDim),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: wo.fgDim),
          ],
        ),
      ),
    );
  }
}

String _fmtDate(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

class _Hint extends StatelessWidget {
  const _Hint({required this.wo, required this.text, this.onRetry});
  final WoColors wo;
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: TextStyle(color: wo.fgMid, fontSize: 14)),
          if (onRetry != null) ...[
            const SizedBox(height: 10),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}
