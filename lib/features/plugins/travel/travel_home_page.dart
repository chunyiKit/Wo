import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'travel_add_page.dart';
import 'travel_map.dart';

/// 旅行首页:全屏可拖动/缩放的真实中国地图 + 玻璃浮顶栏 + 「＋记录」FAB。
class TravelListPage extends StatefulWidget {
  const TravelListPage({super.key});

  @override
  State<TravelListPage> createState() => _TravelListPageState();
}

class _TravelListPageState extends State<TravelListPage> {
  List<TravelTrip>? _trips;
  late final WoSession _session;
  bool _loaded = false;
  bool _pollScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _session = WoScope.of(context);
    _fetch();
  }

  Future<void> _fetch() async {
    final fid = _session.currentFamilyId;
    if (fid == null) {
      if (mounted) setState(() => _trips = const []);
      return;
    }
    try {
      final list = await _session.api.travelTrips(fid);
      if (mounted) {
        setState(() => _trips = list);
        _maybePoll();
      }
    } catch (_) {
      if (mounted) setState(() => _trips ??= const []);
    }
  }

  /// 有记录正在后台生成时,过几秒静默再拉一次,直到都出图(轮询不闪)。
  void _maybePoll() {
    if (_pollScheduled) return;
    if (!(_trips ?? const <TravelTrip>[]).any((t) => t.isGenerating)) return;
    _pollScheduled = true;
    Future.delayed(const Duration(seconds: 5), () {
      _pollScheduled = false;
      if (mounted) _fetch();
    });
  }

  Future<void> _openAdd() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const TravelAddPage()),
    );
    if (changed == true) await _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final trips = _trips ?? const <TravelTrip>[];
    final cityCount = {for (final t in trips) t.cityName}.length;

    return Scaffold(
      backgroundColor: wo.bg,
      body: Stack(
        children: [
          Positioned.fill(child: TravelMap(trips: trips, onChanged: _fetch)),

          // 玻璃浮顶栏
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Row(
              children: [
                _glass(
                  wo,
                  child: IconButton(
                    icon:
                        Icon(Icons.arrow_back_ios_new, size: 18, color: wo.fg),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _glass(
                    wo,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Text(
                          '旅行',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: wo.fg,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(width: 1, height: 16, color: wo.hairline),
                        const SizedBox(width: 8),
                        Text(
                          '去过 $cityCount 城 · ${trips.length} 段',
                          style: TextStyle(fontSize: 12, color: wo.fgMid),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 底部提示
          Positioned(
            left: 14,
            bottom: 24,
            child: _glass(
              wo,
              height: null,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              radius: 100,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('👆', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Text(
                    '双指放大查看城市照片',
                    style: TextStyle(fontSize: 12, color: wo.fgMid),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAdd,
        icon: const Icon(Icons.add),
        label: const Text('记录'),
      ),
    );
  }

  Widget _glass(
    WoColors wo, {
    required Widget child,
    EdgeInsets? padding,
    double? height = 40,
    double radius = 14,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        height: height,
        padding: padding,
        decoration: BoxDecoration(
          color: wo.bgElev.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(radius),
          boxShadow: WoTokens.cardShadow,
        ),
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}
