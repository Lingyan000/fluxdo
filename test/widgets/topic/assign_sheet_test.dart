import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/assignment.dart';
import 'package:fluxdo/models/mention_user.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/widgets/topic/assign_sheet.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AssignService extends Fake implements DiscourseService {
  TopicDetail detail = TopicDetail.fromJson({
    'id': 42,
    'post_stream': {'posts': [], 'stream': []},
    'assigned_to_user': {
      'id': 1,
      'username': 'owner',
      'name': '当前受理人',
      'avatar_template': '',
    },
    'assignment_status': '处理中',
    'assignment_note': '请核对日志，并在处理完成后更新进度。',
  });
  final searches = <String, Completer<MentionSearchResult>>{};
  final assignments = <(int, String, String?, String?)>[];
  Completer<void>? pendingAssignment;
  int topicLoads = 0;

  @override
  Future<TopicDetail> getTopicDetail(
    int id, {
    int? postNumber,
    bool trackVisit = false,
    String? filter,
    String? usernameFilters,
    bool filterTopLevelReplies = false,
  }) async {
    topicLoads++;
    return detail;
  }

  @override
  Future<AssignSuggestions> fetchAssignSuggestions() async => AssignSuggestions(
    suggestions: [
      TopicUser(id: 2, username: 'alice', name: '爱丽丝', avatarTemplate: ''),
    ],
    assignAllowedGroups: ['restricted'],
    assignAllowedForGroups: ['support'],
  );

  @override
  Future<MentionSearchResult> searchUsers({
    required String term,
    int? topicId,
    int? categoryId,
    bool includeGroups = true,
    bool includeMessageableGroups = false,
    bool throwOnError = false,
    int limit = 6,
  }) {
    expect(includeGroups, isFalse);
    expect(throwOnError, isTrue);
    return (searches[term] = Completer<MentionSearchResult>()).future;
  }

  @override
  Future<void> assignTarget({
    required int targetId,
    String targetType = 'Topic',
    String? username,
    String? groupName,
    String? note,
    String? status,
    bool shouldNotify = true,
  }) async {
    assignments.add((targetId, targetType, username, groupName));
    await pendingAssignment?.future;
  }
}

const _params = TopicDetailParams(42, instanceId: 'assign-test');

Future<ProviderContainer> _open(
  WidgetTester tester,
  _AssignService service, {
  bool post = false,
  PostAssignmentInfo? current,
  AppLocale locale = AppLocale.zh,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  LocaleSettings.setLocaleSync(locale);
  SharedPreferences.setMockInitialValues({'dialog_blur': false});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      discourseServiceProvider.overrideWithValue(service),
    ],
  );
  addTearDown(container.dispose);
  container.listen(topicDetailProvider(_params), (_, _) {});
  await container.read(topicDetailProvider(_params).future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          locale: Locale(locale.languageCode, locale.countryCode),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => post
                      ? showPostAssignDialog(
                          context,
                          ref,
                          topicId: 42,
                          postId: 420,
                          current: current,
                        )
                      : showAssignSheet(context, ref, topicId: 42),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _search(WidgetTester tester, String term) async {
  await tester.enterText(find.byType(TextField), term);
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(() async {
    for (final locale in AppLocale.values) {
      await LocaleSettings.setLocale(locale);
    }
  });
  tearDown(() {
    LocaleSettings.setLocaleSync(AppLocale.zh);
    PreloadedDataService().reset();
  });

  testWidgets('当前指定同时展示状态和备注，候选显示身份且只列出可用群组', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _AssignService();
    await _open(tester, service);
    expect(find.text('当前受理人'), findsOneWidget);
    expect(find.text('@owner'), findsOneWidget);
    expect(find.text('处理中'), findsOneWidget);
    expect(find.text(service.detail.assignmentNote!), findsOneWidget);
    expect(find.text('爱丽丝'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('restricted'), findsNothing);
    await tester.ensureVisible(find.text('support'));
    await tester.tap(find.text('support'));
    await tester.pumpAndSettle();
    expect(service.assignments.single, (42, 'Topic', null, 'support'));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索忽略旧响应，重新输入后清除选择，并按帖子目标提交新受理人', (tester) async {
    final service = _AssignService();
    await _open(tester, service, post: true);
    final submit = find.widgetWithText(FilledButton, '指定');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await _search(tester, 'old');
    await _search(tester, 'alice');
    service.searches['alice']!.complete(
      const MentionSearchResult(
        users: [MentionUser(id: 2, username: 'alice', name: '爱丽丝')],
        groups: [],
      ),
    );
    await tester.pumpAndSettle();
    service.searches['old']!.complete(
      const MentionSearchResult(
        users: [MentionUser(id: 3, username: 'outdated')],
        groups: [],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('@outdated'), findsNothing);
    await tester.tap(find.text('@alice'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
    await _search(tester, 'bob');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    service.searches['bob']!.complete(
      const MentionSearchResult(
        users: [MentionUser(id: 4, username: 'bob')],
        groups: [],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('@bob'));
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(service.assignments.single, (420, 'Post', 'bob', null));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('提交期间关闭面板，完成后仍刷新正在显示的话题', (tester) async {
    final service = _AssignService()..pendingAssignment = Completer<void>();
    await _open(tester, service);
    await tester.ensureVisible(find.text('@alice'));
    await tester.tap(find.text('@alice'));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(service.topicLoads, 1);
    service.pendingAssignment!.complete();
    await tester.pumpAndSettle();
    expect(service.topicLoads, 2);
    expect(service.assignments.single, (42, 'Topic', 'alice', null));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索失败与空结果可见，关闭后返回的请求不会更新已释放的界面', (tester) async {
    final service = _AssignService();
    await _open(tester, service, post: true);
    await _search(tester, 'failed');
    service.searches['failed']!.completeError(Exception('offline'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败，请重试'), findsOneWidget);
    await _search(tester, 'empty');
    service.searches['empty']!.complete(
      const MentionSearchResult(users: [], groups: []),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有找到相关结果'), findsOneWidget);
    await _search(tester, 'late');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    service.searches['late']!.complete(
      const MentionSearchResult(users: [], groups: []),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字号与键盘弹出时仍能编辑群组及站点已移除的状态', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    SharedPreferences.setMockInitialValues({});
    PreloadedDataService().debugSeed(
      siteSettings: {
        'enable_assign_status': true,
        'assign_statuses': '待处理|已完成',
      },
      loaded: true,
    );
    for (final locale in AppLocale.values) {
      for (final brightness in Brightness.values) {
        await _open(
          tester,
          _AssignService(),
          post: true,
          current: const PostAssignmentInfo(
            postId: 420,
            assignedToGroupName: 'long_support_group_name',
            status: '历史状态',
            note: '第一行备注\n第二行备注\n第三行备注',
          ),
          locale: locale,
          brightness: brightness,
          textScale: 1.8,
        );
        expect(find.text('long_support_group_name'), findsOneWidget);
        expect(find.text('历史状态'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    }
  });
}
