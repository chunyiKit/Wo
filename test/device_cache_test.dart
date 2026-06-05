import 'package:flutter_test/flutter_test.dart';
import 'package:wo/data/device_cache.dart';

void main() {
  group('formatBytes', () {
    test('零与负数都显示 0 B', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-100), '0 B');
    });

    test('字节级不带小数', () {
      expect(formatBytes(1), '1 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('进位到 KB / MB / GB', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
    });

    test('非整数保留 1 位小数', () {
      expect(formatBytes(1536), '1.5 KB'); // 1.5 KB
    });

    test('≥100 的单位取整更清爽', () {
      // 150 MB 不应显示成 150.0 MB
      expect(formatBytes(150 * 1024 * 1024), '150 MB');
    });
  });

  group('CacheUsage', () {
    test('totalBytes 为三类之和', () {
      const u = CacheUsage(
        dataCacheBytes: 100,
        apkBytes: 200,
        appDataBytes: 300,
      );
      expect(u.totalBytes, 600);
    });

    test('empty 全为 0', () {
      expect(CacheUsage.empty.totalBytes, 0);
    });
  });
}
