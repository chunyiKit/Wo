import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/app_update.dart';
import 'package:wo/widgets/app_update_dialog.dart';

const _release = AppRelease(
  versionName: '1.2.3',
  versionCode: 12,
  notes: '- 修复问题\n- 优化体验',
  size: 12 * 1024 * 1024,
  sha256: '',
  downloadUrl: '/api/v1/app/download',
);

void main() {
  testWidgets('展示新版本、更新内容和后台下载说明', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppUpdateDialog(release: _release),
        ),
      ),
    );

    expect(find.text('发现新版本 1.2.3'), findsOneWidget);
    expect(find.text('安装包大小 12.0 MB'), findsOneWidget);
    expect(find.text('- 修复问题\n- 优化体验'), findsOneWidget);
    expect(find.textContaining('后台下载'), findsOneWidget);
    expect(find.text('稍后'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
  });

  testWidgets('点击立即更新后向调用方返回 true', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<bool>(
                context: context,
                builder: (_) => const AppUpdateDialog(release: _release),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即更新'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });
}
