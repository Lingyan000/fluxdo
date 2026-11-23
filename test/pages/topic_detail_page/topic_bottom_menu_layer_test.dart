import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bottom_bar.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bottom_menu_layer.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_filter_controls.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
  });

  Widget buildHarness({
    required TopicBottomMenuSession session,
    required GlobalKey sourceKey,
    required TopicBottomMenuData data,
    TopicReplyEntryState replyEntryState = TopicReplyEntryState.reply,
    ValueNotifier<int>? streamIndex,
  }) {
    final indexNotifier = streamIndex ?? ValueNotifier<int>(1);
    return ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          locale: const Locale('zh'),
          supportedLocales: AppLocaleUtils.supportedLocales,
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Stack(
            children: [
              Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: TopicBottomBar(
                    streamIndexListenable: indexNotifier,
                    totalCount: 20,
                    replyEntryState: replyEntryState,
                    onReplyEntryTap: () {},
                    onOpenTimeline: () {},
                    bookmarked: data.bookmarked,
                    onBookmark: data.onBookmark,
                    onGestureAction: (_) {},
                    onScrubCommit: (_) {},
                    filter: data.filter,
                    menuSourceKey: sourceKey,
                    onOpenBottomMenu: session.open,
                    menuPresentedListenable: session.presentedNotifier,
                  ),
                ),
              ),
              Positioned.fill(
                child: TopicBottomMenuLayer(
                  session: session,
                  sourceKey: sourceKey,
                  data: data,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  TopicBottomMenuData makeData({
    TopicFilterControls? filter,
    bool showBookmark = true,
    bool bookmarked = false,
    bool isInReadLater = false,
    bool isPrivateMessage = false,
    bool isLoggedIn = true,
    TopicNotificationLevel notificationLevel = TopicNotificationLevel.regular,
    VoidCallback? onBookmark,
    VoidCallback? onToggleReadLater,
    VoidCallback? onOpenFind,
    VoidCallback? onShareTopic,
    VoidCallback? onShowMembers,
    VoidCallback? onOpenNotification,
    VoidCallback? onOpenInBrowser,
    VoidCallback? onOpenReadingSettings,
  }) {
    return TopicBottomMenuData(
      filter: filter ?? const TopicFilterControls(),
      showBookmark: showBookmark,
      bookmarked: bookmarked,
      isInReadLater: isInReadLater,
      isPrivateMessage: isPrivateMessage,
      isLoggedIn: isLoggedIn,
      notificationLevel: notificationLevel,
      onBookmark: onBookmark ?? () {},
      onToggleReadLater: onToggleReadLater ?? () {},
      onOpenFind: onOpenFind ?? () {},
      onShareTopic: onShareTopic ?? () {},
      onShowMembers: onShowMembers,
      onOpenNotification: onOpenNotification ?? () {},
      onOpenInBrowser: onOpenInBrowser ?? () {},
      onOpenReadingSettings: onOpenReadingSettings ?? () {},
    );
  }

  testWidgets('点击底栏按钮原地展开双排宫格，点关闭按钮与遮罩均可收起', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 812);
    addTearDown(tester.view.reset);

    final session = TopicBottomMenuSession();
    final sourceKey = GlobalKey();
    final streamIndex = ValueNotifier<int>(3);
    addTearDown(() {
      session.dispose();
      streamIndex.dispose();
    });

    await tester.pumpWidget(
      buildHarness(
        session: session,
        sourceKey: sourceKey,
        data: makeData(),
        streamIndex: streamIndex,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bottom_menu_footer_close')), findsNothing);
    expect(session.active, isFalse);
    expect(session.presented, isFalse);

    await tester.tap(find.byType(TopicFilterButton));
    await tester.pumpAndSettle();

    expect(session.active, isTrue);
    expect(session.presented, isTrue);
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_author')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_top_level')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_nested')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_read_later')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_find')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_share')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_notification')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_footer_close')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // 点关闭按钮收起
    await tester.tap(find.byKey(const ValueKey('bottom_menu_footer_close')));
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(session.presented, isFalse);
    expect(find.byKey(const ValueKey('bottom_menu_footer_close')), findsNothing);

    // 再次展开后点遮罩顶部收起
    await tester.tap(find.byType(TopicFilterButton));
    await tester.pumpAndSettle();
    expect(session.active, isTrue);

    await tester.tapAt(const Offset(195, 80));
    await tester.pumpAndSettle();
    expect(session.active, isFalse);
    expect(session.presented, isFalse);
  });

  testWidgets('开关类瓷砖点击保持展开，动作类瓷砖点击自动关闭', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 812);
    addTearDown(tester.view.reset);

    final session = TopicBottomMenuSession();
    final sourceKey = GlobalKey();
    final streamIndex = ValueNotifier<int>(1);
    addTearDown(() {
      session.dispose();
      streamIndex.dispose();
    });

    var authorCalls = 0;
    var topLevelCalls = 0;
    var nestedCalls = 0;
    var readLaterCalls = 0;
    var findCalls = 0;
    var shareCalls = 0;
    var notificationCalls = 0;
    var readingSettingsCalls = 0;

    final data = makeData(
      filter: TopicFilterControls(
        onShowAuthorOnly: () => authorCalls++,
        onShowTopLevelReplies: () => topLevelCalls++,
        onShowNestedView: () => nestedCalls++,
      ),
      onToggleReadLater: () => readLaterCalls++,
      onOpenFind: () => findCalls++,
      onShareTopic: () => shareCalls++,
      onOpenNotification: () => notificationCalls++,
      onOpenReadingSettings: () => readingSettingsCalls++,
    );

    await tester.pumpWidget(
      buildHarness(
        session: session,
        sourceKey: sourceKey,
        data: data,
        streamIndex: streamIndex,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TopicFilterButton));
    await tester.pumpAndSettle();

    // 连续点击 4 个开关类瓷砖，面板均应保持展开
    await tester.tap(find.byKey(const ValueKey('bottom_menu_tile_author')));
    await tester.pump();
    expect(authorCalls, 1);
    expect(session.active, isTrue);

    await tester.tap(find.byKey(const ValueKey('bottom_menu_tile_top_level')));
    await tester.pump();
    expect(topLevelCalls, 1);
    expect(session.active, isTrue);

    await tester.tap(find.byKey(const ValueKey('bottom_menu_tile_nested')));
    await tester.pump();
    expect(nestedCalls, 1);
    expect(session.active, isTrue);

    await tester.tap(find.byKey(const ValueKey('bottom_menu_tile_read_later')));
    await tester.pump();
    expect(readLaterCalls, 1);
    expect(session.active, isTrue);

    // 动作类瓷砖：点击后自动收起并执行回调
    await tester.tap(find.byKey(const ValueKey('bottom_menu_tile_find')));
    await tester.pumpAndSettle();
    expect(findCalls, 1);
    expect(session.active, isFalse);

    session.open();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bottom_menu_tile_share')));
    await tester.pumpAndSettle();
    expect(shareCalls, 1);
    expect(session.active, isFalse);

    session.open();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bottom_menu_tile_notification')),
    );
    await tester.pumpAndSettle();
    expect(notificationCalls, 1);
    expect(session.active, isFalse);

    session.open();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bottom_menu_footer_reading')));
    await tester.pumpAndSettle();
    expect(readingSettingsCalls, 1);
    expect(session.active, isFalse);
  });

  testWidgets('激活筛选态点击底栏按钮展开面板，再次点选已激活瓷砖可取消并保持打开', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 812);
    addTearDown(tester.view.reset);

    final session = TopicBottomMenuSession();
    final sourceKey = GlobalKey();
    final streamIndex = ValueNotifier<int>(1);
    addTearDown(() {
      session.dispose();
      streamIndex.dispose();
    });

    var cancelCalls = 0;
    final data = makeData(
      filter: TopicFilterControls(
        isAuthorOnlyMode: true,
        onCancelFilter: () => cancelCalls++,
      ),
    );

    await tester.pumpWidget(
      buildHarness(
        session: session,
        sourceKey: sourceKey,
        data: data,
        streamIndex: streamIndex,
      ),
    );
    await tester.pumpAndSettle();

    // 已激活筛选时点击底栏按钮应展开面板，而非直接取消
    await tester.tap(find.byType(TopicFilterButton));
    await tester.pumpAndSettle();
    expect(session.active, isTrue);
    expect(cancelCalls, 0);
    expect(
      find.byKey(const ValueKey('bottom_menu_footer_cancel_filter')),
      findsOneWidget,
    );

    // 再次点击高亮的「只看题主」瓷砖应触发取消，且保持面板打开
    await tester.tap(find.byKey(const ValueKey('bottom_menu_tile_author')));
    await tester.pump();
    expect(cancelCalls, 1);
    expect(session.active, isTrue);
  });

  testWidgets('按话题能力与登录状态动态派生宫格瓷砖', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 812);
    addTearDown(tester.view.reset);

    final session = TopicBottomMenuSession();
    final sourceKey = GlobalKey();
    final streamIndex = ValueNotifier<int>(1);
    addTearDown(() {
      session.dispose();
      streamIndex.dispose();
    });

    var membersCalls = 0;
    var browserCalls = 0;

    // 场景 1：带热门 + 问答 + 私信 + 未登录
    await tester.pumpWidget(
      buildHarness(
        session: session,
        sourceKey: sourceKey,
        replyEntryState: TopicReplyEntryState.login,
        data: makeData(
          filter: const TopicFilterControls(
            hasSummary: true,
            isPostVoting: true,
            isAuthorOnlyMode: true,
            usernameFilter: 'alice',
            isOtherUserFilter: true,
          ),
          showBookmark: false,
          isPrivateMessage: true,
          isLoggedIn: false,
          onShowMembers: () => membersCalls++,
          onOpenInBrowser: () => browserCalls++,
        ),
        streamIndex: streamIndex,
      ),
    );
    await tester.pumpAndSettle();

    session.open();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('bottom_menu_tile_activity')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_hot')),
      findsOneWidget,
    );
    expect(find.textContaining('alice'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_members')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_share')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_browser')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_notification')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_footer_bookmark')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('bottom_menu_tile_members')));
    await tester.pumpAndSettle();
    expect(membersCalls, 1);
    expect(session.active, isFalse);

    session.open();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bottom_menu_tile_browser')));
    await tester.pumpAndSettle();
    expect(browserCalls, 1);
    expect(session.active, isFalse);
  });

  testWidgets('底行书签未收藏时原地切换不关闭，已收藏时关闭面板再打开编辑', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 812);
    addTearDown(tester.view.reset);

    final session = TopicBottomMenuSession();
    final sourceKey = GlobalKey();
    final streamIndex = ValueNotifier<int>(1);
    addTearDown(() {
      session.dispose();
      streamIndex.dispose();
    });

    var bookmarkCalls = 0;
    await tester.pumpWidget(
      buildHarness(
        session: session,
        sourceKey: sourceKey,
        data: makeData(
          bookmarked: false,
          onBookmark: () => bookmarkCalls++,
        ),
        streamIndex: streamIndex,
      ),
    );
    await tester.pumpAndSettle();

    session.open();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bottom_menu_footer_bookmark')));
    await tester.pump();
    expect(bookmarkCalls, 1);
    expect(session.active, isTrue);

    await tester.pumpWidget(
      buildHarness(
        session: session,
        sourceKey: sourceKey,
        data: makeData(
          bookmarked: true,
          onBookmark: () => bookmarkCalls++,
        ),
        streamIndex: streamIndex,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bottom_menu_footer_bookmark')));
    await tester.pumpAndSettle();
    expect(bookmarkCalls, 2);
    expect(session.active, isFalse);
  });

  testWidgets('宽屏悬浮形态展开与底栏宽度一致且无布局溢出', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 812);
    addTearDown(tester.view.reset);

    final session = TopicBottomMenuSession();
    final sourceKey = GlobalKey();
    final streamIndex = ValueNotifier<int>(5);
    addTearDown(() {
      session.dispose();
      streamIndex.dispose();
    });

    await tester.pumpWidget(
      buildHarness(
        session: session,
        sourceKey: sourceKey,
        data: makeData(
          filter: const TopicFilterControls(hasSummary: true),
        ),
        streamIndex: streamIndex,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TopicFilterButton));
    await tester.pumpAndSettle();

    expect(session.active, isTrue);
    expect(
      find.byKey(const ValueKey('bottom_menu_tile_hot')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bottom_menu_footer_close')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
