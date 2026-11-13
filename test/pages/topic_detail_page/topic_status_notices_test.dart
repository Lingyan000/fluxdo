import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_status_notices.dart';
import 'package:m3e_ui/m3e_ui.dart';

TopicDetail _detail({Map<String, dynamic> fields = const {}}) =>
    TopicDetail.fromJson({
      'id': 1,
      'post_stream': {'posts': [], 'stream': []},
      ...fields,
    });

const _timer = {
  'status_type': 'delete_replies',
  'duration_minutes': 10080,
  'execute_at': '2020-01-01T00:00:00Z',
};

Widget _app(
  TopicDetail detail, {
  AppLocale locale = AppLocale.zh,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) {
  LocaleSettings.setLocaleSync(locale);
  return TranslationProvider(
    child: MaterialApp(
      locale: Locale(locale.languageCode, locale.countryCode),
      supportedLocales: AppLocaleUtils.supportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: SingleChildScrollView(
            child: TopicStatusNotices(detail: detail),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() async {
    for (final locale in AppLocale.values) {
      await LocaleSettings.setLocale(locale);
    }
  });
  tearDown(() => LocaleSettings.setLocaleSync(AppLocale.zh));

  test('兼容缺少字段的数据，解析 UTC 和保留时长并支持复制与清除', () {
    final empty = _detail();
    expect(empty.slowModeSeconds, 0);
    expect(empty.topicTimer, isNull);
    final detail = _detail(
      fields: {'slow_mode_seconds': 3600, 'topic_timer': _timer},
    );
    expect(detail.topicTimer!.executeAt!.toUtc(), DateTime.utc(2020));
    expect(detail.topicTimer!.durationMinutes, 10080);
    final copy = detail.copyWith(likeCount: 1);
    expect(copy.slowModeSeconds, 3600);
    expect(copy.topicTimer, same(detail.topicTimer));
    final cleared = copy.copyWith(slowModeSeconds: 0, clearTopicTimer: true);
    expect(cleared.slowModeSeconds, 0);
    expect(cleared.topicTimer, isNull);
  });

  testWidgets('无提示时不保留卡片或间距', (tester) async {
    await tester.pumpWidget(_app(_detail()));
    expect(find.byType(SegmentedCardGroup), findsNothing);
    expect(tester.getSize(find.byType(TopicStatusNotices)).height, 0);
  });

  testWidgets('同时显示慢速和自动删除提示，过期执行时间不隐藏循环任务', (tester) async {
    await tester.pumpWidget(
      _app(_detail(fields: {'slow_mode_seconds': 3600, 'topic_timer': _timer})),
    );
    expect(find.text('请在此话题的两次发帖之间等待 1 小时'), findsOneWidget);
    expect(find.text('此话题的回复会在 7 天后自动删除。'), findsOneWidget);
  });

  testWidgets('关闭话题只隐藏慢速提示，移除定时任务后卡片消失', (tester) async {
    final detail = _detail(
      fields: {
        'closed': true,
        'slow_mode_seconds': 3600,
        'topic_timer': _timer,
      },
    );
    await tester.pumpWidget(_app(detail));
    expect(find.textContaining('两次发帖'), findsNothing);
    expect(find.textContaining('自动删除'), findsOneWidget);
    await tester.pumpWidget(_app(detail.copyWith(clearTopicTimer: true)));
    expect(find.byType(SegmentedCardGroup), findsNothing);
  });

  testWidgets('忽略其他定时任务、未设置执行时间和无效时长', (tester) async {
    for (final timer in [
      {..._timer, 'status_type': 'close'},
      {..._timer, 'execute_at': null},
      {..._timer, 'duration_minutes': 0},
      {..._timer, 'duration_minutes': -1},
    ]) {
      await tester.pumpWidget(_app(_detail(fields: {'topic_timer': timer})));
      expect(find.byType(SegmentedCardGroup), findsNothing);
    }
  });

  testWidgets('时长保留小时、分钟和秒，英文支持单复数', (tester) async {
    await tester.pumpWidget(
      _app(
        _detail(
          fields: {
            'slow_mode_seconds': 3723,
            'topic_timer': {..._timer, 'duration_minutes': 1.5},
          },
        ),
        locale: AppLocale.en,
      ),
    );
    expect(
      find.text(
        'Please wait 1 hour 2 minutes 3 seconds between posts in this topic.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Replies to this topic are automatically deleted after 1 minute 30 seconds.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('四种语言在明暗主题、窄屏大字号下自动换行', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final locale in AppLocale.values) {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _app(
            _detail(fields: {'slow_mode_seconds': 3600, 'topic_timer': _timer}),
            locale: locale,
            brightness: brightness,
            textScale: 2,
          ),
        );
        expect(find.byType(SegmentedCardGroup), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });
}
