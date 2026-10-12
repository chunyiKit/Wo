// 无第三方依赖，直接测试页面使用的阅读态合并逻辑。
import 'dart:io';
import '../../lib/features/plugins/chat/chat_history_refresh.dart';

typedef Row = ({int id, int time, String status, String? image});
Row row(int id, {int? time, String status = 'sending', String? image}) =>
    (id: id, time: time ?? id, status: status, image: image);
void check(bool value) {
  if (!value) throw StateError('阅读态刷新回归失败');
}

void main() {
  final previous = [row(1), row(2), row(3)];
  ChatHistoryRefresh<Row> refresh(List<Row> fresh, {bool reading = true}) =>
      ChatHistoryRefresh(
          previous: previous,
          fresh: fresh,
          id: (item) => item.id,
          readingHistory: reading);
  final statuses = refresh([
    row(1, status: 'sent'),
    row(2, status: 'failed'),
    row(3, status: 'sent', image: '/downloaded/image.jpg')
  ]);
  check(!statuses.hasNewMessages);
  check(statuses.items[0].status == 'sent');
  check(statuses.items[1].status == 'failed');
  check(statuses.items[2].image == '/downloaded/image.jpg');
  final reordered = [row(3, time: 0), row(1), row(4, time: 1), row(2), row(5)];
  final reading = refresh(reordered);
  check(reading.items.map((r) => r.id).join(',') == '1,2,3');
  check(reading.items.last.time == 0);
  check(reading.hasNewMessages);
  final latest = refresh(reordered, reading: false);
  check(latest.items == reordered && !latest.hasNewMessages);
  check(refresh([row(1), row(4), row(2), row(3)]).hasNewMessages);
  stdout.writeln('阅读态状态、附件、重排、插入与回填回归通过');
}
