import 'package:flutter/material.dart';

import '../../../data/models.dart';
import '../../../theme/wo_tokens.dart';
import 'travel_map.dart';

/// 城市搜索选择底部弹层。
class TravelCityPickerSheet extends StatefulWidget {
  const TravelCityPickerSheet();

  @override
  State<TravelCityPickerSheet> createState() => TravelCityPickerSheetState();
}

class TravelCityPickerSheetState extends State<TravelCityPickerSheet> {
  List<TravelCity> _all = const [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    // 城市在前、区县在后:搜索「杭州」时先出地级市,再出同名区县。
    Future.wait([loadTravelCities(), loadTravelDistricts()]).then((r) {
      if (mounted) setState(() => _all = [...r[0], ...r[1]]);
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
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
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
              child: WoTextField(
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: '搜索城市 / 区县',
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
                itemBuilder: (_, i) {
                  final c = list[i];
                  return WoListTile(
                    leading: const Text('📍', style: TextStyle(fontSize: 18)),
                    title: Text(c.name),
                    subtitle: c.region == null ? null : Text(c.region!),
                    onTap: () => Navigator.of(context).pop(c),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
