import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wo/features/profile/local_sync_page.dart';
import 'package:wo/local/local_runtime.dart';
import 'package:wo/theme/wo_theme.dart';
import 'package:wo/theme/wo_tokens.dart';

// 测试源码尚未执行。
void main() {
  LocalRuntime? previous;
  setUp(() { previous = LocalRuntime.instance; LocalRuntime.instance = null; });
  tearDown(() { LocalRuntime.instance = previous; });

  testWidgets('运行时尚未就绪时不生成邀请也不进入永久首屏加载', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: WoTheme.light(), home: const LocalSyncPage()));
    expect(find.text('本机同步尚未就绪'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final invite = tester.widget<WoFilledButton>(find.widgetWithText(WoFilledButton, '邀请另一台手机'));
    expect(invite.onPressed, isNull);
    expect(find.textContaining('私密回忆不向手机广播'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字仍能滚动读取权限说明并安全退出计时器', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme: WoTheme.dark(), builder: (context, child) =>
      MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)), child: child!),
      home: const LocalSyncPage()));
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });
}
