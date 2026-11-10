import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/theme/festival_calendar.dart';
import 'package:fluxdo/theme/theme_spec.dart';

void main() {
  setUpAll(() {
    FestivalCalendar.setAll(
      FestivalCalendar.parse(
        File(FestivalCalendar.assetPath).readAsStringSync(),
      ),
    );
  });
  tearDownAll(() => FestivalCalendar.setAll(const []));

  String? activeId(int y, int m, int d) =>
      FestivalCalendar.activeOn(DateTime(y, m, d, 15))?.festival.id;

  test('农历节日日期与已知公历日期一致', () {
    expect(const LunarDateRule(1, 1).dateIn(2026), DateTime(2026, 2, 17));
    expect(const LunarDateRule(1, 1).dateIn(2025), DateTime(2025, 1, 29));
    expect(const LunarDateRule(5, 5).dateIn(2026), DateTime(2026, 6, 19));
    expect(const LunarDateRule(8, 15).dateIn(2026), DateTime(2026, 9, 25));
    // 腊月节日落在次年年初：2027 年 1 月的腊八属于农历 2026 年
    expect(const LunarDateRule(12, 8).dateIn(2027)?.year, 2027);
  });

  test('冬至按节气判定', () {
    final date = const SolarTermRule('冬至', 12).dateIn(2026);
    expect(date?.month, 12);
    expect(date!.day, inInclusiveRange(21, 23));
  });

  test('春节窗口为除夕至初七，腊月廿九的除夕也覆盖', () {
    // 2025 年除夕为腊月廿九（1 月 28 日），初七为 2 月 4 日
    expect(activeId(2025, 1, 27), isNull);
    expect(activeId(2025, 1, 28), 'spring');
    expect(activeId(2025, 2, 4), 'spring');
    expect(activeId(2025, 2, 5), isNull);
    // 2026 年除夕 2 月 16 日，初七 2 月 23 日
    expect(activeId(2026, 2, 16), 'spring');
    expect(activeId(2026, 2, 23), 'spring');
    expect(activeId(2026, 2, 24), isNull);
  });

  test('其余节日窗口', () {
    expect(activeId(2026, 3, 2), 'lantern'); // 正月十四
    expect(activeId(2026, 3, 3), 'lantern'); // 元宵
    expect(activeId(2026, 6, 18), 'dragonboat');
    expect(activeId(2026, 6, 20), isNull);
    expect(activeId(2026, 9, 24), 'midautumn');
    expect(activeId(2026, 9, 26), 'midautumn');
    expect(activeId(2026, 9, 27), isNull);
    expect(activeId(2026, 7, 1), isNull);
  });

  test('不做清明', () {
    expect(FestivalCalendar.all.map((f) => f.id), isNot(contains('qingming')));
    expect(activeId(2026, 4, 5), isNull);
  });

  test('本次节日的键按节日当天区分年份', () {
    final a = FestivalCalendar.activeOn(DateTime(2025, 1, 30))!;
    final b = FestivalCalendar.activeOn(DateTime(2026, 2, 20))!;
    expect(a.key, 'spring-20250129');
    expect(b.key, 'spring-20260217');
  });

  test('每个节日都有对应的节日配色主题，且不进画廊分组', () {
    for (final festival in FestivalCalendar.all) {
      final file = File('assets/themes/${festival.themeId}.json');
      expect(file.existsSync(), isTrue, reason: festival.themeId);
      final spec = ThemeSpec.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      );
      expect(spec.group, ThemeGroup.festival, reason: festival.themeId);
      expect(festival.greeting['zh'], isNotNull);
      expect(festival.greeting['en'], isNotNull);
    }
  });

  test('运行时读取的主题、节日、字体资源都已在 pubspec 中声明', () {
    // 运行时经 rootBundle 读取；测试直接读磁盘文件，漏声明不会在其它
    // 用例里暴露
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final asset in [
      'assets/themes/',
      'assets/festivals/',
      'assets/fonts/catalog.json',
    ]) {
      expect(pubspec, contains('    - $asset\n'), reason: asset);
    }
  });

  test('下一个零点', () {
    expect(
      FestivalCalendar.nextMidnight(DateTime(2026, 12, 31, 23, 59)),
      DateTime(2027, 1, 1),
    );
  });
}
