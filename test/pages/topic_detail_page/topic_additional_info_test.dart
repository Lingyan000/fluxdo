import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_state_summary.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_statistics.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_statistics_sheets.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 弹层读取背景模糊等偏好，需要可用的 SharedPreferences
late SharedPreferences _prefs;

TopicDetail _detail(Map<String, dynamic> fields) => TopicDetail.fromJson({
  'id': 1,
  'post_stream': {'posts': [], 'stream': []},
  ...fields,
});

Widget _app(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) => ProviderScope(
  overrides: [sharedPreferencesProvider.overrideWithValue(_prefs)],
  child: TranslationProvider(
    child: MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: AppLocaleUtils.supportedLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: SingleChildScrollView(child: child),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });
  setUp(() => LocaleSettings.setLocaleSync(AppLocale.zh));

  test('新增字段解析、复制和清除覆盖旧数据', () {
    final detail = _detail({
      'visibility_reason_id': 3,
      'is_warning': true,
      'queued_posts_count': 2,
      'participant_count': 10,
      'word_count': 3500,
      'topic_timer': {
        'status_type': 'close',
        'based_on_last_post': true,
        'category_id': 7,
      },
      'details': {
        'participants': [
          {'id': 2, 'username': 'alice', 'post_count': 8},
        ],
        'links': [
          {'url': 'https://example.com', 'title': '链接', 'clicks': 12},
        ],
      },
    });
    final copy = detail.copyWith(views: 3);
    expect(copy.visibilityReasonId, 3);
    expect(copy.isWarning, isTrue);
    expect(copy.queuedPostsCount, 2);
    expect(copy.participantCount, 10);
    expect(copy.wordCount, 3500);
    expect(copy.participants.single.postCount, 8);
    expect(copy.links.single.clicks, 12);
    expect(copy.topicTimer!.basedOnLastPost, isTrue);
    expect(copy.topicTimer!.categoryId, 7);
    final empty = copy.copyWith(
      isWarning: false,
      queuedPostsCount: 0,
      participants: [],
      links: [],
    );
    expect(empty.isWarning, isFalse);
    expect(empty.queuedPostsCount, 0);
    expect(empty.participants, isEmpty);
    expect(empty.links, isEmpty);
    expect(_detail({}).links, isEmpty);
  });

  testWidgets('展示归档、不公开原因和官方警告，未知原因保留通用说明', (tester) async {
    final detail = _detail({
      'archived': true,
      'visible': false,
      'visibility_reason_id': 3,
      'is_warning': true,
    });
    await tester.pumpWidget(_app(TopicStateSummary(detail: detail)));
    expect(find.textContaining('已归档'), findsOneWidget);
    expect(find.textContaining('手动取消公开'), findsOneWidget);
    expect(find.textContaining('官方警告'), findsOneWidget);
    await tester.pumpWidget(
      _app(TopicStateSummary(detail: detail.copyWith(visibilityReasonId: 123))),
    );
    expect(find.textContaining('直接链接访问'), findsOneWidget);
    expect(find.textContaining('手动取消公开'), findsNothing);
  });

  testWidgets('无附加数据时隐藏，阅读时长使用站点速度且短话题不显示', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(TopicStatistics(detail: _detail({}))));
    expect(tester.getSize(find.byType(TopicStatistics)).height, 0);
    await tester.pumpWidget(
      _app(
        TopicStatistics(
          detail: _detail({'word_count': 3500}),
          wordsPerMinute: 350,
        ),
      ),
    );
    expect(find.bySemanticsLabel('阅读约 10 分钟'), findsOneWidget);
    await tester.pumpWidget(
      _app(
        TopicStatistics(
          detail: _detail({'word_count': 350}),
          wordsPerMinute: 350,
        ),
      ),
    );
    expect(find.bySemanticsLabel(RegExp('阅读约')), findsNothing);
    semantics.dispose();
  });

  testWidgets('参与者和链接在弹层中查看，链接全部列出', (tester) async {
    final semantics = tester.ensureSemantics();
    final detail = _detail({
      'participant_count': 2,
      'like_count': 7,
      'details': {
        'participants': [
          {'id': 2, 'username': 'alice', 'name': '测试用户', 'post_count': 8},
        ],
        'links': [
          for (var i = 1; i <= 6; i++)
            {'url': 'https://example.com/$i', 'title': '链接 $i', 'clicks': i},
        ],
      },
    });
    await tester.pumpWidget(_app(TopicStatistics(detail: detail)));
    expect(find.bySemanticsLabel('2 位参与者'), findsOneWidget);
    expect(find.bySemanticsLabel('7 个赞'), findsOneWidget);
    expect(find.text('测试用户'), findsNothing);

    await tester.tap(find.bySemanticsLabel('2 位参与者'));
    await tester.pumpAndSettle();
    expect(find.text('测试用户'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);
    expect(find.textContaining('8'), findsWidgets);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('6 个链接'));
    await tester.pumpAndSettle();
    final linkList = find.descendant(
      of: find.byType(TopicLinkList),
      matching: find.byType(Scrollable),
    );
    for (var i = 1; i <= 6; i++) {
      await tester.scrollUntilVisible(
        find.text('链接 $i'),
        50,
        scrollable: linkList,
      );
      expect(find.text('链接 $i'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('窄屏大字体展示状态和统计 ${brightness.name}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final detail = _detail({
        'archived': true,
        'visible': false,
        'is_warning': true,
        'participant_count': 12345,
        'like_count': 12345,
        'details': {
          'participants': [
            {
              'id': 2,
              'username': 'a_very_long_participant_username',
              'post_count': 12345,
            },
          ],
          'links': [
            {
              'url': 'https://example.com/long/topic/reference',
              'title': '一条很长的讨论参考资料链接标题',
              'clicks': 12345,
            },
          ],
        },
      });
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              TopicStateSummary(detail: detail),
              TopicStatistics(detail: detail),
            ],
          ),
          brightness: brightness,
          textScale: 2,
        ),
      );
      final semantics = tester.ensureSemantics();
      await tester.ensureVisible(find.bySemanticsLabel('12345 位参与者'));
      await tester.tap(find.bySemanticsLabel('12345 位参与者'));
      await tester.pumpAndSettle();
      expect(find.text('a_very_long_participant_username'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  }
}
