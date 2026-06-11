import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/message_bus_service.dart';

void main() {
  group('MessageBusService.extractNextChunkForTest', () {
    test('按 \\r\\n|\\r\\n 切出完整 chunk', () {
      const input = '[{"channel":"/a","message_id":1,"data":null}]\r\n|\r\n[]\r\n|\r\n';
      final first = MessageBusService.extractNextChunkForTest(input, 0)!;
      expect(first.payload, '[{"channel":"/a","message_id":1,"data":null}]');
      expect(first.endOffset, isPositive);

      final second = MessageBusService.extractNextChunkForTest(input, first.endOffset)!;
      expect(second.payload, '[]');

      expect(
        MessageBusService.extractNextChunkForTest(input, second.endOffset),
        isNull,
      );
    });

    test('内容里的 \\r\\n||\\r\\n 还原为 \\r\\n|\\r\\n,不会被当成分隔符', () {
      const escaped = 'A\r\n||\r\nB';
      final input = '$escaped\r\n|\r\n';
      final slice = MessageBusService.extractNextChunkForTest(input, 0)!;
      expect(slice.payload, 'A\r\n|\r\nB');
    });

    test('普通竖线不会被误判为分隔符', () {
      const payload = '[{"channel":"/a","data":"one|two|three"}]';
      final input = '$payload\r\n|\r\n';
      final slice = MessageBusService.extractNextChunkForTest(input, 0)!;
      expect(slice.payload, payload);
    });

    test('没有完整分隔符时返回 null', () {
      expect(
        MessageBusService.extractNextChunkForTest('partial chunk only', 0),
        isNull,
      );
    });
  });

  group('MessageBusService.computeNextDelayForTest', () {
    final bus = MessageBusService();
    final earlier = DateTime.now().subtract(const Duration(milliseconds: 500));

    test('429 时尊重 Retry-After,最小 15s', () {
      final delay = bus.computeNextDelayForTest(
        rateLimited: true,
        rateLimitedSeconds: 5,
        abortedByClient: false,
        requestFailed: false,
        gotData: false,
        inBackground: false,
        startedAt: earlier,
      );
      expect(delay, const Duration(seconds: 15));
    });

    test('429 且 Retry-After 大于 15s,使用 Retry-After 值', () {
      final delay = bus.computeNextDelayForTest(
        rateLimited: true,
        rateLimitedSeconds: 60,
        abortedByClient: false,
        requestFailed: false,
        gotData: false,
        inBackground: false,
        startedAt: earlier,
      );
      expect(delay, const Duration(seconds: 60));
    });

    test('客户端 abort 100ms 后立即重试', () {
      final delay = bus.computeNextDelayForTest(
        rateLimited: false,
        abortedByClient: true,
        requestFailed: false,
        gotData: false,
        inBackground: false,
        startedAt: earlier,
      );
      expect(delay, const Duration(milliseconds: 100));
    });

    test('long poll 收到数据 100ms 后立即继续', () {
      final delay = bus.computeNextDelayForTest(
        rateLimited: false,
        abortedByClient: false,
        requestFailed: false,
        gotData: true,
        inBackground: false,
        startedAt: earlier,
      );
      expect(delay, const Duration(milliseconds: 100));
    });

    test('无数据返回时按 callbackInterval - elapsed 补足', () {
      final startedAt = DateTime.now().subtract(const Duration(milliseconds: 500));
      final delay = bus.computeNextDelayForTest(
        rateLimited: false,
        abortedByClient: false,
        requestFailed: false,
        gotData: false,
        inBackground: false,
        startedAt: startedAt,
      );
      // 默认 callbackInterval = 3s,elapsed ~500ms,应在 2.4s~2.6s 区间
      expect(delay, greaterThan(const Duration(seconds: 2)));
      expect(delay, lessThanOrEqualTo(const Duration(seconds: 3)));
    });

    test('剩余时间小于 100ms 时退化为 100ms 下限', () {
      final startedAt = DateTime.now().subtract(const Duration(seconds: 60));
      final delay = bus.computeNextDelayForTest(
        rateLimited: false,
        abortedByClient: false,
        requestFailed: false,
        gotData: false,
        inBackground: false,
        startedAt: startedAt,
      );
      expect(delay, const Duration(milliseconds: 100));
    });

    test('后台模式使用 backgroundCallbackInterval', () {
      final startedAt = DateTime.now();
      final delay = bus.computeNextDelayForTest(
        rateLimited: false,
        abortedByClient: false,
        requestFailed: false,
        gotData: false,
        inBackground: true,
        startedAt: startedAt,
      );
      // 默认 backgroundCallbackInterval = 60s,elapsed 接近 0,应该 > 55s
      expect(delay, greaterThan(const Duration(seconds: 55)));
      expect(delay, lessThanOrEqualTo(const Duration(seconds: 60)));
    });
  });
}
