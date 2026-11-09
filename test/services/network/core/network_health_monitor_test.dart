import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/core/network_health_monitor.dart';

void main() {
  late NetworkHealthMonitor monitor;
  late List<Map<String, dynamic>> events;
  late DateTime now;
  final forum = Uri.parse('https://forum.test/topic?token=secret');

  setUp(() {
    now = DateTime.utc(2026, 11, 9);
    events = [];
    monitor = NetworkHealthMonitor(now: () => now, write: events.add);
  });
  tearDown(() => monitor.dispose());

  test('并发故障只记开始和恢复汇总，403 也证明传输已响应', () {
    final attempts = List.generate(12, (_) => monitor.begin(forum));
    for (final attempt in attempts.reversed) {
      monitor.failed(attempt, kind: 'connectionTimeout');
    }
    expect(events, hasLength(1));
    expect(monitor.problem?.failures, 12);
    now = now.add(const Duration(seconds: 20));
    final next = monitor.begin(forum, traceId: 'trace', requestId: 42);
    monitor.headers(next, statusCode: 403, protocol: 'HTTP/2', connectMs: 50);
    expect(monitor.problem?.failures, 12);
    monitor.completed(next);
    expect(monitor.problem, isNull);
    expect(monitor.forOrigin(forum)?.responded, isTrue);
    expect(events.last['event'], 'transport_recovered');
    expect(events.last['failureCount'], 12);
    expect(events.last['episodeMs'], 20000);
    expect(events.last['statusCode'], 403);
    expect(events.last['coreRequestId'], 42);
    expect(events.toString(), isNot(contains('secret')));
    expect(events.toString(), isNot(contains('/topic')));
  });

  test('切网清空观测，旧请求不能重报故障或伪报恢复', () {
    final old = monitor.begin(forum);
    monitor.failed(old, kind: 'connectionError');
    monitor.reset(reason: 'network_changed');
    monitor.completed(old);
    monitor.failed(old, kind: 'connectionError');
    expect(monitor.forOrigin(forum), isNull);
    expect(events.map((e) => e['event']), [
      'transport_failure_started',
      'transport_observation_reset',
    ]);
  });

  test('迟到的旧成功不覆盖新失败，迟到旧失败也不覆盖新成功', () {
    final old = monitor.begin(forum);
    final newer = monitor.begin(forum);
    monitor.failed(newer, kind: 'connectionTimeout');
    monitor.completed(old);
    expect(monitor.problem, isNotNull);
    final latest = monitor.begin(forum);
    monitor.completed(latest);
    monitor.completed(old);
    monitor.failed(newer, kind: 'connectionTimeout');
    expect(monitor.problem, isNull);
    expect(events, hasLength(2));
  });

  test('响应体故障单独标记，不把收到头当作下载已恢复', () {
    final old = monitor.begin(forum);
    monitor.headers(old, statusCode: 200);
    monitor.failed(old, kind: 'receiveTimeout');
    expect(events.single['failurePhase'], 'response_body');
    final next = monitor.begin(forum);
    monitor.headers(next, statusCode: 200);
    expect(monitor.problem, isNotNull);
    monitor.completed(next);
    expect(monitor.problem, isNull);
  });

  test('正常请求不重复通知和记日志，用户取消不报故障', () {
    var notifications = 0;
    monitor.addListener(() => notifications++);
    for (var i = 0; i < 1000; i++) {
      final observation = monitor.begin(forum);
      monitor.headers(observation, statusCode: 200);
      monitor.completed(observation);
    }
    monitor.failed(monitor.begin(forum), kind: 'cancelled');
    expect(notifications, 1);
    expect(events, isEmpty);
    expect(monitor.problem, isNull);
  });

  test('观测存储有界，端口隔离，淘汰只结束记录不声称恢复', () {
    monitor.failed(monitor.begin(forum), kind: 'connectionError');
    for (var i = 0; i < NetworkHealthMonitor.maxOrigins; i++) {
      monitor.completed(monitor.begin(Uri.parse('https://host$i.test/')));
    }
    expect(monitor.forOrigin(forum), isNull);
    expect(events.last['event'], 'transport_observation_reset');
    expect(events.last['reason'], 'capacity');
    monitor.failed(monitor.begin(forum), kind: 'badCertificate');
    monitor.completed(monitor.begin(Uri.parse('https://forum.test:8443/')));
    expect(monitor.forOrigin(forum)?.failures, 1);
  });
}
