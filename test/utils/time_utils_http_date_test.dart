import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/time_utils.dart';

/// Discourse 绝大多数时间字段是 ISO-8601，但少数走 Ruby 的 `httpdate`
/// （如 MessageBus `/do-not-disturb/:id` 的 ends_at）。这种格式
/// DateTime.parse 直接抛异常，若被静默吞成 null，勿扰模式会被误判为
/// 未开启而照常弹通知——所以这条回退路径需要有测试兜住。
void main() {
  group('parseHttpDate', () {
    test('解析标准 HTTP-date 为对应 UTC 时刻', () {
      final parsed = TimeUtils.parseHttpDate('Wed, 21 Oct 2015 07:28:00 GMT');
      expect(parsed, isNotNull);
      expect(parsed!.toUtc(), DateTime.utc(2015, 10, 21, 7, 28));
    });

    test('返回本地时间（与 parseUtcTime 语义一致）', () {
      final parsed = TimeUtils.parseHttpDate('Wed, 21 Oct 2015 07:28:00 GMT');
      expect(parsed!.isUtc, isFalse);
    });

    test('缺少 GMT 后缀也能解析', () {
      expect(
        TimeUtils.parseHttpDate('Wed, 21 Oct 2015 07:28:00')?.toUtc(),
        DateTime.utc(2015, 10, 21, 7, 28),
      );
    });

    test('空值与非法输入返回 null', () {
      expect(TimeUtils.parseHttpDate(null), isNull);
      expect(TimeUtils.parseHttpDate(''), isNull);
      expect(TimeUtils.parseHttpDate('not a date'), isNull);
    });
  });

  group('parseUtcTime 的 HTTP-date 回退', () {
    test('ISO-8601 仍走原路径', () {
      expect(
        TimeUtils.parseUtcTime('2015-10-21T07:28:00Z')?.toUtc(),
        DateTime.utc(2015, 10, 21, 7, 28),
      );
    });

    test('ISO 解析失败时回退到 HTTP-date', () {
      expect(
        TimeUtils.parseUtcTime('Wed, 21 Oct 2015 07:28:00 GMT')?.toUtc(),
        DateTime.utc(2015, 10, 21, 7, 28),
      );
    });

    test('两种格式都不匹配时返回 null', () {
      expect(TimeUtils.parseUtcTime('garbage'), isNull);
    });
  });
}
