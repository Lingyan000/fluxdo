import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/screen_track.dart';

class _TimingRecord {
  const _TimingRecord({
    required this.topicId,
    required this.topicTime,
    required this.timings,
  });

  final int topicId;
  final int topicTime;
  final Map<int, int> timings;
}

class _FakeDiscourseService implements DiscourseService {
  final List<_TimingRecord> sent = [];

  @override
  bool get isAuthenticated => true;

  @override
  Future<int?> topicsTimings({
    required int topicId,
    required int topicTime,
    required Map<int, int> timings,
    Map<String, dynamic>? logContext,
  }) async {
    sent.add(
      _TimingRecord(
        topicId: topicId,
        topicTime: topicTime,
        timings: Map<int, int>.from(timings),
      ),
    );
    return 200;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('ScreenTrack', () {
    testWidgets('反复暂停与恢复（模拟开关图片查看器）不额外触发 POST /topics/timings', (
      tester,
    ) async {
      final service = _FakeDiscourseService();
      final track = ScreenTrack(service, now: () => tester.binding.clock.now());

      track.start(3253949);
      track.setOnscreen({1, 2});

      // 未读楼层在首个累积周期触发一次 rush 上报
      await tester.pump(const Duration(seconds: 2));
      expect(service.sent, hasLength(1));

      // 连续 10 次打开/关闭覆盖层（setHasFocus false <-> true），每次停留 1 秒
      for (var i = 0; i < 10; i++) {
        track.setHasFocus(false);
        await tester.pump(const Duration(seconds: 1));
        track.setHasFocus(true);
        await tester.pump(const Duration(seconds: 1));
      }

      // 期间不得触发任何额外 timings 上报，且未累计失焦时间超过 60s
      expect(service.sent, hasLength(1));

      // 真正离开话题（stop）时仅做一次收尾 flush，且只包含聚焦期间的有效阅读时长
      track.stop();
      await tester.pump();
      expect(service.sent, hasLength(2));
      expect(service.sent.last.timings[1], greaterThan(0));
      expect(service.sent.last.timings[1], lessThanOrEqualTo(12000));
    });

    testWidgets('已读楼层传入 readOnscreen 时不触发 rush 立即上报', (tester) async {
      final service = _FakeDiscourseService();
      final track = ScreenTrack(service, now: () => tester.binding.clock.now());

      track.start(3253949);
      track.setOnscreen({1, 2}, readOnscreen: {1, 2});

      await tester.pump(const Duration(seconds: 10));
      expect(service.sent, isEmpty);

      // 满 60 秒正常周期才上报一次
      await tester.pump(const Duration(seconds: 55));
      expect(service.sent, hasLength(1));

      track.stop();
      await tester.pump();
    });

    testWidgets('暂停期间不推进 60 秒 flush 窗口，恢复后继续累加', (tester) async {
      final service = _FakeDiscourseService();
      final track = ScreenTrack(service, now: () => tester.binding.clock.now());

      track.start(3253949);
      track.setOnscreen({1}, readOnscreen: {1});

      // 聚焦阅读 20 秒
      await tester.pump(const Duration(seconds: 20));
      expect(service.sent, isEmpty);

      // 失焦/被覆盖 120 秒，不应在后台触发任何 flush
      track.setHasFocus(false);
      await tester.pump(const Duration(seconds: 120));
      expect(service.sent, isEmpty);

      // 恢复聚焦，再阅读 42 秒（累计活跃 62 秒 > 60 秒）触发一次正常周期上报
      track.setHasFocus(true);
      await tester.pump(const Duration(seconds: 42));
      expect(service.sent, hasLength(1));

      track.stop();
      await tester.pump();
    });
  });
}
