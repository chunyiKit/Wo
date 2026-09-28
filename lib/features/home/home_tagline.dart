import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/wo_taglines.dart';
import '../../theme/wo_typography.dart';

/// 标题局部轮播，避免带动首页列表重建或随文案长度改变布局。
class HomeTagline extends StatefulWidget {
  const HomeTagline({super.key});

  @override
  State<HomeTagline> createState() => _HomeTaglineState();
}

class _HomeTaglineState extends State<HomeTagline> {
  Timer? _timer;
  int _index = 0;
  bool _visible = true;
  bool _animate = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 保持兼容项目最低支持的 Flutter 3.27。
    // ignore: deprecated_member_use
    final tickerEnabled = TickerMode.of(context);
    final animate = tickerEnabled && !MediaQuery.disableAnimationsOf(context);
    if (_animate == animate) return;
    _animate = animate;
    _timer?.cancel();
    _visible = true;
    if (animate) {
      _timer = Timer.periodic(const Duration(seconds: 4), (_) {
        setState(() => _visible = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: MediaQuery.textScalerOf(context).scale(28) * 1.35,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: _animate ? const Duration(milliseconds: 450) : Duration.zero,
        curve: Curves.easeInOut,
        onEnd: () {
          if (!_animate || _visible) return;
          setState(() {
            _index = (_index + 1) % woTaglines.length;
            _visible = true;
          });
        },
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            woTaglines[_index],
            maxLines: 1,
            style: const TextStyle(
              fontFamily: WoTypography.editorialFamily,
              fontSize: 28,
              color: Color(0xFFFFEAD0),
              height: 1.35,
            ),
          ),
        ),
      ),
    );
  }
}
