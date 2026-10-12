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

  testWidgets('阅读时已有图片变高仍保持可见消息锚点', (tester) async {
    final controller = ScrollController();
    final downloaded = ValueNotifier(false);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: ValueListenableBuilder<bool>(
        valueListenable: downloaded,
        builder: (_, ready, __) => ChatHistoryList<int>(
          items: List.generate(30, (i) => i + 1),
          controller: controller,
          hasOlder: false,
          loadingOlder: false,
          onLoadOlder: () {},
          itemKey: (id) => ValueKey(id),
          itemBuilder: (id) => SizedBox(
            height: id == 25 ? (ready ? 220 : 160) : 48,
            child: Text(id == 25 ? (ready ? '图片已下载' : '图片下载中') : '消息 $id'),
          ),
        ),
      ),
    )));
    controller.jumpTo(400);
    await tester.pump();
    final anchor = find.byKey(const ValueKey(15));
    final before = tester.getTopLeft(anchor);
    downloaded.value = true;
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(anchor).dy, closeTo(before.dy, 0.1));
    expect(controller.offset, closeTo(460, 0.1));
    await tester.pumpWidget(const SizedBox());
    downloaded.dispose();
    controller.dispose();
  });

  testWidgets('阅读时发送状态消失仍保持可见消息锚点', (tester) async {
    final controller = ScrollController();
    final sent = ValueNotifier(false);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: ValueListenableBuilder<bool>(
        valueListenable: sent,
        builder: (_, ready, __) => ChatHistoryList<int>(
          items: List.generate(30, (i) => i + 1),
          controller: controller,
          hasOlder: false,
          loadingOlder: false,
          onLoadOlder: () {},
          itemKey: (id) => ValueKey(id),
          itemBuilder: (id) => SizedBox(
            height: id == 25 && !ready ? 68 : 48,
            child: Text(id == 25 ? (ready ? '已发送' : '发送中') : '消息 $id'),
          ),
        ),
      ),
    )));
    controller.jumpTo(300);
    await tester.pump();
    final anchor = find.byKey(const ValueKey(15));
    final before = tester.getTopLeft(anchor);
    sent.value = true;
    await tester.pump();
    await tester.pump();
    expect(tester.getTopLeft(anchor).dy, closeTo(before.dy, 0.1));
    expect(controller.offset, closeTo(280, 0.1));
    await tester.pumpWidget(const SizedBox());
    sent.dispose();
    controller.dispose();
  });

  testWidgets('显式返回最新消息的动画不会被阅读锚点补偿取消', (tester) async {
    final controller = ScrollController();
    final downloaded = ValueNotifier(false);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: ValueListenableBuilder<bool>(
        valueListenable: downloaded,
        builder: (_, ready, __) => ChatHistoryList<int>(
          items: List.generate(30, (i) => i + 1),
          controller: controller,
          hasOlder: false,
          loadingOlder: false,
          onLoadOlder: () {},
          itemKey: (id) => ValueKey(id),
          itemBuilder: (id) => SizedBox(
            height: id == 25 ? (ready ? 220 : 160) : 48,
            child: Text('消息 $id'),
          ),
        ),
      ),
    )));
    controller.jumpTo(400);
    await tester.pump();
    // 模拟页面先安排回底，随后列表更新并安排锚点补偿的同帧顺序。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.animateTo(0,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
    downloaded.value = true;
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    expect(find.text('消息 30'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    downloaded.dispose();
    controller.dispose();
  });
}
