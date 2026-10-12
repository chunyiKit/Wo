import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wo/features/plugins/chat/chat_history_list.dart';

void main() {
  testWidgets('最新窗口默认显示最后一条消息', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: ChatHistoryList<int>(
        items: List.generate(500, (i) => i + 4501),
        controller: controller,
        hasOlder: true,
        loadingOlder: false,
        onLoadOlder: () {},
        itemKey: (item) => ValueKey(item),
        itemBuilder: (item) => SizedBox(height: 48, child: Text('消息 $item')),
      ),
    )));
    expect(find.text('消息 5000'), findsOneWidget);
    expect(controller.offset, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('展开旧消息后可见行与滚动位置不变', (tester) async {
    final controller = ScrollController();
    final items = ValueNotifier(List.generate(500, (i) => i + 501));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: ValueListenableBuilder<List<int>>(
        valueListenable: items,
        builder: (_, values, __) => ChatHistoryList<int>(
          items: values,
          controller: controller,
          hasOlder: true,
          loadingOlder: false,
          onLoadOlder: () {},
          itemKey: (item) => ValueKey(item),
          itemBuilder: (item) => SizedBox(height: 48, child: Text('消息 $item')),
        ),
      ),
    )));
    controller.jumpTo(480);
    await tester.pump();
    final anchor = find.byKey(const ValueKey(990));
    final position = tester.getTopLeft(anchor);
    items.value = List.generate(1000, (i) => i + 1);
    await tester.pump();
    expect(controller.offset, 480);
    expect(tester.getTopLeft(anchor), position);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    items.dispose();
  });
}
