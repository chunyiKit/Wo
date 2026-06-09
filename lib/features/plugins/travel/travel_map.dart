import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import '../../../widgets/wo_network_image.dart';
import 'travel_city_page.dart';

// ── 投影：等距圆柱 + cos(midLat) 横向校正，把 [lng,lat] 投到固定地图坐标系 ──
// 固定中国范围(不含南海诸岛那条远在 ~3°N 的九段线,否则大陆会被压扁)。
const double _lngMin = 73.0, _lngMax = 135.5, _latMin = 17.5, _latMax = 53.8;
const double _mapW = 1000.0;
final double _cosMid = math.cos(((_latMin + _latMax) / 2) * math.pi / 180);
final double _scaleX = _mapW / (_lngMax - _lngMin);
final double _scaleY = _scaleX / _cosMid;
final double _mapH = (_latMax - _latMin) * _scaleY;

Offset _project(double lng, double lat) =>
    Offset((lng - _lngMin) * _scaleX, (_latMax - lat) * _scaleY);

/// 解析一次的地图数据：省界 Path(地图坐标系)+ 城市投影点。
class TravelMapData {
  TravelMapData(this.landPath, this.cities);
  final Path landPath;
  final List<({String name, Offset p})> cities;
}

Future<TravelMapData>? _cached;

Future<TravelMapData> loadTravelMapData() => _cached ??= _load();

List<TravelCity>? _citiesCache;

/// 读取地级市列表(带经纬度),用于「添加记录」的城市选择 + 搜索。结果缓存。
Future<List<TravelCity>> loadTravelCities() async {
  if (_citiesCache != null) return _citiesCache!;
  final str = await rootBundle.loadString('assets/maps/china_cities.json');
  _citiesCache = [
    for (final e in jsonDecode(str) as List)
      TravelCity.fromJson(e as Map<String, dynamic>),
  ];
  return _citiesCache!;
}

Future<TravelMapData> _load() async {
  final provStr =
      await rootBundle.loadString('assets/maps/china_provinces.json');
  final prov = jsonDecode(provStr) as Map<String, dynamic>;
  final path = Path()..fillType = PathFillType.evenOdd;
  for (final p in prov['provinces'] as List) {
    final name = (p['name'] as String?) ?? '';
    if (name.contains('南海')) continue; // 跳过九段线,避免把视图拉得过高
    for (final ring in p['rings'] as List) {
      final pts = ring as List;
      var first = true;
      for (final pt in pts) {
        final o =
            _project((pt[0] as num).toDouble(), (pt[1] as num).toDouble());
        if (first) {
          path.moveTo(o.dx, o.dy);
          first = false;
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      path.close();
    }
  }
  final cityStr = await rootBundle.loadString('assets/maps/china_cities.json');
  final cities = [
    for (final e in jsonDecode(cityStr) as List)
      (
        name: (e['name'] as String?) ?? '',
        p: _project(
          (e['lng'] as num).toDouble(),
          (e['lat'] as num).toDouble(),
        ),
      ),
  ];
  return TravelMapData(path, cities);
}

/// 一座「去过」的城市(把该城市的所有旅行记录聚合而来)。
class _Visited {
  _Visited(this.name, this.point, this.trips);
  final String name;
  final Offset point; // 地图坐标
  final List<TravelTrip> trips; // 该城市全部记录(按时间倒序)
  TravelTrip get cover => trips.first; // 最近一段作封面
}

/// 可拖动 / 缩放的真实中国地图。去过的城市用 accent 实心点 + 光环;放大越阈值后
/// 城市旁浮出照片缩略图(点击进该城市图集),用 accent 虚线连回城市点。
class TravelMap extends StatefulWidget {
  const TravelMap({super.key, required this.trips, this.onChanged});

  final List<TravelTrip> trips;

  /// 在城市图集里删除记录后回调,让外层刷新地图数据。
  final VoidCallback? onChanged;

  @override
  State<TravelMap> createState() => _TravelMapState();
}

class _TravelMapState extends State<TravelMap> {
  TravelMapData? _data;
  // 省界预渲染成一张纹理(只做一次):平移缩放时只贴图,不每帧三角化矢量 Path,
  // 否则在 Impeller/Vulkan(部分 Adreno 机型)上会因巨型缓冲分配失败而原生崩溃。
  ui.Image? _landImage;
  Brightness? _landBrightness;
  bool _renderingLand = false;
  static const double _supersample = 2.0; // 离屏渲染倍率,放大时更清晰

  // view: 地图坐标 → 屏幕 = (tx + x*scale, ty + y*scale)
  double _scale = 1, _tx = 0, _ty = 0;
  Size _viewport = Size.zero;
  bool _inited = false;

  // 手势基准
  double _gScale = 1;
  Offset _gFocalMap = Offset.zero;

  double get _fit =>
      math.min(_viewport.width / _mapW, _viewport.height / _mapH);
  double get _minScale => _fit * 0.85;
  double get _maxScale => _fit * 5.0;
  double get _thumbThreshold => _fit * 1.5;

  @override
  void initState() {
    super.initState();
    loadTravelMapData().then((d) {
      if (mounted) setState(() => _data = d);
    });
  }

  void _fitView() {
    _scale = _fit;
    _tx = (_viewport.width - _mapW * _scale) / 2;
    _ty = (_viewport.height - _mapH * _scale) / 2;
  }

  /// 把省界 Path 一次性光栅化成纹理(按当前明暗主题)。异步,完成后 setState。
  Future<void> _ensureLand(TravelMapData data, bool isDark) async {
    final b = isDark ? Brightness.dark : Brightness.light;
    if (_renderingLand || (_landImage != null && _landBrightness == b)) return;
    _renderingLand = true;
    final w = (_mapW * _supersample).round();
    final h = (_mapH * _supersample).round();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    c.scale(_supersample);
    final land = isDark ? const Color(0xFF1E2A25) : const Color(0xFFDCE8E2);
    final stroke = isDark ? const Color(0xFF33463D) : const Color(0xFFB9D0C5);
    c.drawPath(data.landPath, Paint()..color = land);
    c.drawPath(
      data.landPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = stroke
        ..strokeWidth = 1.1
        ..strokeJoin = StrokeJoin.round,
    );
    final img = await rec.endRecording().toImage(w, h);
    if (!mounted) {
      img.dispose();
      return;
    }
    setState(() {
      _landImage?.dispose();
      _landImage = img;
      _landBrightness = b;
      _renderingLand = false;
    });
  }

  @override
  void dispose() {
    _landImage?.dispose();
    super.dispose();
  }

  void _zoomAround(Offset screen, double factor) {
    final ns = (_scale * factor).clamp(_minScale, _maxScale);
    final k = ns / _scale;
    setState(() {
      _tx = screen.dx - (screen.dx - _tx) * k;
      _ty = screen.dy - (screen.dy - _ty) * k;
      _scale = ns;
    });
  }

  Offset _toScreen(Offset mapPt) =>
      Offset(_tx + mapPt.dx * _scale, _ty + mapPt.dy * _scale);

  List<_Visited> _visited() {
    // 按城市聚合(trips 已按时间倒序),每城一个标记 + 该城全部记录。
    final byCity = <String, List<TravelTrip>>{};
    final order = <String>[];
    for (final t in widget.trips) {
      final list = byCity[t.cityName];
      if (list == null) {
        order.add(t.cityName);
        byCity[t.cityName] = [t];
      } else {
        list.add(t);
      }
    }
    return [
      for (final city in order)
        _Visited(
          city,
          _project(byCity[city]!.first.cityLng, byCity[city]!.first.cityLat),
          byCity[city]!,
        ),
    ];
  }

  Future<void> _openCity(_Visited v) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TravelCityPage(cityName: v.name, trips: v.trips),
      ),
    );
    if (changed == true) widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final api = WoScope.api(context);
    final data = _data;

    return LayoutBuilder(
      builder: (context, constraints) {
        final vp = Size(constraints.maxWidth, constraints.maxHeight);
        if (vp != _viewport) {
          _viewport = vp;
          if (!_inited && vp.width > 0 && data != null) {
            _fitView();
            _inited = true;
          }
        }
        if (data == null) {
          return ColoredBox(
            color: isDark ? const Color(0xFF11201B) : const Color(0xFFEAF1EE),
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        if (!_inited && vp.width > 0) {
          _fitView();
          _inited = true;
        }
        // 首帧 / 主题切换时一次性把省界渲染成纹理(内部去重,不会每帧重做)。
        _ensureLand(data, isDark);

        final showThumbs = _scale >= _thumbThreshold;
        final visited = _visited();

        // 手势层只包住地图;缩略图与控件作为兄弟放在最上层(可点击),
        // 避免缩放识别器在竞技场里抢走它们的点击。
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onScaleStart: (d) {
                  _gScale = _scale;
                  _gFocalMap = Offset(
                    (d.localFocalPoint.dx - _tx) / _scale,
                    (d.localFocalPoint.dy - _ty) / _scale,
                  );
                },
                onScaleUpdate: (d) {
                  setState(() {
                    _scale = (_gScale * d.scale).clamp(_minScale, _maxScale);
                    // 让起始焦点对应的地图点始终停在当前焦点下(同时平移+缩放)。
                    _tx = d.localFocalPoint.dx - _gFocalMap.dx * _scale;
                    _ty = d.localFocalPoint.dy - _gFocalMap.dy * _scale;
                  });
                },
                // 底图:海面 + 省界 + 城市点/名 + 去过城市连接虚线
                child: CustomPaint(
                  painter: _MapPainter(
                    data: data,
                    landImage: _landImage,
                    scale: _scale,
                    tx: _tx,
                    ty: _ty,
                    isDark: isDark,
                    wo: wo,
                    visited: visited,
                    showThumbs: showThumbs,
                    labelThreshold: _fit * 1.25,
                  ),
                ),
              ),
            ),
            // 缩略图卡片(恒定尺寸,可点击进城市图集)
            if (showThumbs)
              for (final v in visited) _thumbnail(api, wo, v),
            _controls(wo),
          ],
        );
      },
    );
  }

  Widget _thumbnail(api, WoColors wo, _Visited v) {
    final anchor = _toScreen(v.point) + const Offset(48, -42);
    final cover = v.cover;
    return Positioned(
      left: anchor.dx - 42,
      top: anchor.dy - 30,
      child: GestureDetector(
        onTap: () => _openCity(v),
        child: Container(
          width: 84,
          decoration: BoxDecoration(
            color: wo.bgElev,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x382A1E14),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 54,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    WoNetworkImage(
                      url: '${api.baseUrl}${cover.imageUrl}',
                      headers: api.imageHeaders,
                      placeholderColor: wo.travel,
                      decodeWidth: 84,
                    ),
                    if (cover.isGenerating)
                      Container(
                        color: Colors.black.withValues(alpha: 0.4),
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    if (v.trips.length > 1)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${v.trips.length}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
                child: Text(
                  v.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: wo.fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(WoColors wo) {
    Widget btn(String s, VoidCallback onTap, {bool border = false}) => InkWell(
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: border
                  ? Border(bottom: BorderSide(color: wo.hairline))
                  : null,
            ),
            child: Text(
              s,
              style: TextStyle(
                fontSize: 20,
                color: wo.fg,
                fontWeight: FontWeight.w300,
              ),
            ),
          ),
        );
    return Positioned(
      right: 14,
      bottom: 150,
      child: Column(
        children: [
          Material(
            color: wo.bgElev,
            borderRadius: BorderRadius.circular(14),
            elevation: 2,
            child: Column(
              children: [
                btn(
                  '＋',
                  () => _zoomAround(_viewport.center(Offset.zero), 1.45),
                  border: true,
                ),
                btn('－', () => _zoomAround(_viewport.center(Offset.zero), 0.7)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Material(
            color: wo.bgElev,
            borderRadius: BorderRadius.circular(12),
            elevation: 2,
            child: InkWell(
              onTap: () => setState(_fitView),
              child: SizedBox(
                width: 40,
                height: 40,
                child: Icon(Icons.my_location_outlined, size: 18, color: wo.fg),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.data,
    required this.landImage,
    required this.scale,
    required this.tx,
    required this.ty,
    required this.isDark,
    required this.wo,
    required this.visited,
    required this.showThumbs,
    required this.labelThreshold,
  });

  final TravelMapData data;
  final ui.Image? landImage;
  final double scale, tx, ty, labelThreshold;
  final bool isDark, showThumbs;
  final WoColors wo;
  final List<_Visited> visited;

  Offset _toScreen(Offset p) => Offset(tx + p.dx * scale, ty + p.dy * scale);

  @override
  void paint(Canvas canvas, Size size) {
    final sea = isDark ? const Color(0xFF11201B) : const Color(0xFFEAF1EE);
    canvas.drawRect(Offset.zero & size, Paint()..color = sea);

    // 省界:贴预渲染好的纹理(只是缩放采样,GPU 廉价;不每帧三角化矢量,避免
    // Impeller/Vulkan 巨型分配崩溃)。裁剪到视口,进一步限定绘制区域。
    final img = landImage;
    if (img != null) {
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      final dst = Rect.fromLTWH(tx, ty, _mapW * scale, _mapH * scale);
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        dst,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    }

    final visitedNames = {for (final v in visited) v.name};
    // 放大后才显示背景城市的「点」(给地理参照),但**不显示名字**——否则 509 个
    // 城市名全标出来会非常拥挤。只有「去过的」城市才标名(+点+照片)。
    final showDots = scale >= labelThreshold;
    final rect = Offset.zero & size;

    // 城市点(恒定屏幕尺寸,裁剪到视口)。
    for (final c in data.cities) {
      final s = _toScreen(c.p);
      if (!rect.inflate(40).contains(s)) continue;
      final isVisited = visitedNames.contains(c.name);
      if (!isVisited && !showDots) continue; // 缩小时只显示去过的
      _dot(canvas, s, isVisited);
      if (isVisited) _label(canvas, c.name, s, true); // 名字只给去过的城市
    }
    // 去过但名字不在 cities 资源里的城市,也要画点/名。
    for (final v in visited) {
      if (data.cities.any((c) => c.name == v.name)) continue;
      final s = _toScreen(v.point);
      if (!rect.inflate(40).contains(s)) continue;
      _dot(canvas, s, true);
      _label(canvas, v.name, s, true);
    }

    // 缩略图连接虚线(在缩略图卡之下)。
    if (showThumbs) {
      final dash = Paint()
        ..style = PaintingStyle.stroke
        ..color = wo.accent
        ..strokeWidth = 1.5;
      for (final v in visited) {
        final s = _toScreen(v.point);
        final anchor = s + const Offset(48, -42);
        _dashLine(canvas, s, anchor, dash);
        canvas.drawCircle(anchor, 3, Paint()..color = wo.accent);
      }
    }
  }

  void _dot(Canvas canvas, Offset s, bool visited) {
    if (visited) {
      canvas.drawCircle(
        s,
        7,
        Paint()..color = wo.accent.withValues(alpha: 0.18),
      );
      canvas.drawCircle(s, 4.5, Paint()..color = wo.accent);
      canvas.drawCircle(
        s,
        4.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = isDark ? wo.bgElev : Colors.white,
      );
    } else {
      canvas.drawCircle(s, 2.4, Paint()..color = wo.fgDim);
    }
  }

  void _label(Canvas canvas, String name, Offset s, bool visited) {
    final tp = TextPainter(
      text: TextSpan(
        text: name,
        style: TextStyle(
          fontSize: visited ? 12 : 10.5,
          fontWeight: visited ? FontWeight.w700 : FontWeight.w500,
          color: wo.fg,
          shadows: isDark
              ? const [Shadow(color: Colors.black87, blurRadius: 3)]
              : const [Shadow(color: Color(0xE6FFFFFF), blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(s.dx - tp.width / 2, s.dy + 5));
  }

  void _dashLine(Canvas canvas, Offset a, Offset b, Paint p) {
    const dash = 3.0, gap = 3.0;
    final total = (b - a).distance;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      final start = a + dir * d;
      final end = a + dir * math.min(d + dash, total);
      canvas.drawLine(start, end, p);
      d += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.scale != scale ||
      old.tx != tx ||
      old.ty != ty ||
      old.isDark != isDark ||
      old.showThumbs != showThumbs ||
      old.landImage != landImage ||
      old.visited.length != visited.length;
}
