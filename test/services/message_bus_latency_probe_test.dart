import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/message_bus_latency_probe.dart';
import 'package:fluxdo/services/message_bus_service.dart';

void main() {
  late DateTime now;
  late MessageBusLatencyProbe probe;

  setUp(() {
    now = DateTime.utc(2026, 11, 2, 12);
    probe = MessageBusLatencyProbe(clock: () => now);
  });

  MessageBusMessage latest(Duration sinceBump, {String channel = '/latest'}) {
    return MessageBusMessage(
      channel: channel,
      messageId: 1,
      data: {
        'message_type': 'latest',
        'topic_id': 1,
        'payload': {'bumped_at': now.subtract(sinceBump).toIso8601String()},
      },
      receivedAt: now,
    );
  }

  test('按 bumped_at 统计传输延迟，积压回放单独计数', () {
    for (final ms in [300, 800, 1200, 20000]) {
      probe.onReceived(
        latest(Duration(milliseconds: ms)),
        chunked: ms != 20000,
      );
    }
    probe.onReceived(latest(const Duration(minutes: 10)), chunked: true);
    // 其他频道的消息不计入
    probe.onReceived(latest(Duration.zero, channel: '/new'), chunked: true);

    final summary = probe.summarize();
    expect(summary['samples'], 4);
    expect(summary['p50Ms'], 1200);
    expect(summary['maxMs'], 20000);
    expect(summary['stale'], 1);
    expect(summary['chunked'], 4);
    expect(summary['plain'], 1);
  });

  test('记录滚动期延迟投递压住的最长时间', () {
    final message = latest(const Duration(milliseconds: 500));
    probe.onReceived(message, chunked: true);
    now = now.add(const Duration(milliseconds: 1400));
    probe.onDelivered(message);
    expect(probe.summarize()['maxDeliveryDelayMs'], 1400);
  });

  test('时间窗到期后落日志并清空窗口', () {
    probe.onReceived(latest(const Duration(seconds: 1)), chunked: true);
    expect(probe.summarize()['samples'], 1);

    now = now.add(MessageBusLatencyProbe.reportInterval);
    probe.onReceived(latest(const Duration(seconds: 1)), chunked: true);
    expect(probe.summarize()['samples'], 0);
  });
}
