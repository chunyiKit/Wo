import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';

import '../../../data/api_client.dart';
import '../../../data/models.dart';
import '../../../data/wo_session.dart';
import '../../../theme/wo_tokens.dart';
import 'travel_map.dart';

/// 添加旅行记录:选城市 → 填具体地点(可选)→ 传一张图 → 保存。
/// 保存后后台自动用默认提示词(+地点)图生图、好了替换成生成图(原图不保留)。
class TravelAddPage extends StatefulWidget {
  const TravelAddPage({super.key});

  @override
  State<TravelAddPage> createState() => _TravelAddPageState();
}

class _TravelAddPageState extends State<TravelAddPage> {
  Uint8List? _bytes;
  TravelCity? _city;
  final _place = TextEditingController();
  final _caption = TextEditingController();
  bool _busy = false;

  WoSession get _session => WoScope.of(context);

  @override
  void dispose() {
    _place.dispose();
    _caption.dispose();
    super.dispose();
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final raw = await picked.readAsBytes();
    final compressed = await FlutterImageCompress.compressWithList(
      raw,
      minWidth: 1600,
      minHeight: 1600,
      quality: 86,
      format: CompressFormat.jpeg,
    );
    if (mounted) setState(() => _bytes = Uint8List.fromList(compressed));
  }

  Future<void> _pickCity() async {
    final city = await showModalBottomSheet<TravelCity>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _CityPickerSheet(),
    );
    if (city != null && mounted) setState(() => _city = city);
  }

  Future<void> _save() async {
    if (_busy) return;
    if (_city == null) {
      _toast('先选一个城市');
      return;
    }
    if (_bytes == null) {
      _toast('先选一张照片');
      return;
    }
    setState(() => _busy = true);
    try {
      await _session.api.createTravelTrip(
        _session.currentFamilyId!,
        imageBytes: _bytes!,
        cityName: _city!.name,
        lng: _city!.lng,
        lat: _city!.lat,
        place: _place.text.trim(),
        caption: _caption.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        final msg = switch (e) {
          ApiException ex => ex.message,
          NetworkException ex => ex.message,
          _ => '保存失败,请稍后再试',
        };
        _toast(msg);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final t = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: wo.bg,
      appBar: AppBar(
        title: const Text('新的旅行'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
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
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
          children: [
            _cityRow(wo, t),
            const SizedBox(height: 12),
            _placeField(wo, t),
            const SizedBox(height: 16),
            _imageBlock(wo),
            const SizedBox(height: 16),
            _captionField(wo, t),
            const SizedBox(height: 18),
            _hint(wo, t),
          ],
        ),
      ),
    );
  }

  Widget _hint(WoColors wo, TextTheme t) => Container(
        padding: const EdgeInsets.all(WoTokens.space3),
        decoration: BoxDecoration(
          color: wo.bgTint,
          borderRadius: BorderRadius.circular(WoTokens.space3),
        ),
        child: Row(
          children: [
            const Text('✨', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '保存后会自动把照片生成一张「色彩漫游」旅行记录图,稍等片刻在地图上就能看到。',
                style: t.bodySmall?.copyWith(color: wo.fgMid, height: 1.5),
              ),
            ),
          ],
        ),
      );

  Widget _cityRow(WoColors wo, TextTheme t) => InkWell(
        onTap: _pickCity,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: wo.bgTint,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Text('📍', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('城市', style: t.labelSmall?.copyWith(color: wo.fgMid)),
                    const SizedBox(height: 1),
                    Text(
                      _city?.name ?? '搜索城市…',
                      style: t.titleSmall?.copyWith(
                        color: _city == null ? wo.fgDim : wo.fg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: wo.fgDim),
            ],
          ),
        ),
      );

  Widget _placeField(WoColors wo, TextTheme t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: wo.bgTint,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Text('🏞️', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _place,
                decoration: const InputDecoration(
                  labelText: '具体地点(可选)',
                  hintText: '如 东方明珠、长江大桥',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _imageBlock(WoColors wo) {
    if (_bytes == null) {
      return AspectRatio(
        aspectRatio: 4 / 3,
        child: InkWell(
          onTap: _pickImage,
          borderRadius: BorderRadius.circular(18),
          child: DottedPlaceholder(wo: wo),
        ),
      );
    }
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(_bytes!, fit: BoxFit.cover),
            Positioned(
              top: 10,
              right: 10,
              child: GestureDetector(
                onTap: _pickImage,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: const Text('换一张',
                      style: TextStyle(color: Colors.white, fontSize: 11)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _captionField(WoColors wo, TextTheme t) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _caption,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              hintText: '写一句想记住的话…',
              border: InputBorder.none,
            ),
            style: t.bodyLarge?.copyWith(color: wo.fg, height: 1.6),
          ),
          Container(height: 1, color: wo.hairline),
        ],
      );
}

class DottedPlaceholder extends StatelessWidget {
  const DottedPlaceholder({super.key, required this.wo});
  final WoColors wo;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: wo.bgTint,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: wo.hairline, width: 1.5),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🏞️', style: TextStyle(fontSize: 34)),
          const SizedBox(height: 8),
          Text('选一张照片',
              style: TextStyle(
                  color: wo.fgMid, fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text('每段旅行只留一张', style: TextStyle(color: wo.fgDim, fontSize: 12)),
        ],
      ),
    );
  }
}

/// 城市搜索选择底部弹层。
class _CityPickerSheet extends StatefulWidget {
  const _CityPickerSheet();

  @override
  State<_CityPickerSheet> createState() => _CityPickerSheetState();
}

class _CityPickerSheetState extends State<_CityPickerSheet> {
  List<TravelCity> _all = const [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    loadTravelCities().then((c) {
      if (mounted) setState(() => _all = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wo = context.wo;
    final q = _q.trim();
    final list = q.isEmpty
        ? _all.take(60).toList()
        : _all.where((c) => c.name.contains(q)).take(80).toList();

    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
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
              padding: const EdgeInsets.all(16),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: '搜索城市',
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
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) => ListTile(
                  leading: const Text('📍', style: TextStyle(fontSize: 18)),
                  title: Text(list[i].name),
                  onTap: () => Navigator.of(context).pop(list[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
