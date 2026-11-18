import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/chat/chat_list_page.dart';
import 'package:fluxdo/pages/private_messages_page.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_bottom_bar.dart';
import 'package:fluxdo/pages/topic_detail_page/widgets/topic_filter_controls.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/chat/chat_channels_provider.dart';
import 'package:fluxdo/providers/message_bus/pm_tracking_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/user_content_providers.dart';
import 'package:fluxdo/services/local_notification_service.dart' show navigatorKey;
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/layout/adaptive_navigation.dart';
import 'package:fluxdo/widgets/layout/adaptive_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _phone = Size(390, 844);

Future<void> _pumpPage(
  WidgetTester tester, {
  required Widget page,
  bool embedded = true,
  bool hideBottomNavigation = false,
  bool floating = true,
  bool labelless = true,
  double safeBottom = 24,
  double textScale = 1,
  int destinationCount = 3,
  Size size = _phone,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    'pref_bottom_nav_floating': floating,
    'pref_bottom_nav_labelless': labelless,
  });
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        categoriesProvider.overrideWith((_) async => []),
        chatChannelsProvider.overrideWithBuild(
          (_, _) async => const ChatChannelsState(),
        ),
        pmInboxProvider.overrideWithBuild((_, _) async => []),
        pmSentProvider.overrideWithBuild((_, _) async => []),
        pmArchiveProvider.overrideWithBuild((_, _) async => []),
        pmTrackingProvider.overrideWithBuild((_, _) => const PmIncomingState()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              padding: EdgeInsets.only(bottom: safeBottom),
              viewPadding: EdgeInsets.only(bottom: safeBottom),
              textScaler: TextScaler.linear(textScale),
            ),
            child: embedded
                ? AdaptiveScaffold(
                    selectedIndex: 1,
                    hideBottomNavigation: hideBottomNavigation,
                    onDestinationSelected: (_) {},
                    destinations: [
                      for (var i = 0; i < destinationCount; i++)
                        AdaptiveDestination(
                          id: 'entry$i',
                          icon: const Icon(Icons.home_outlined),
                          selectedIcon: const Icon(Icons.home),
                          label: '入口$i',
                        ),
                    ],
                    body: page,
                  )
                : page,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (page is ChatListPage &&
      find.byType(FloatingActionButton).evaluate().isEmpty) {
    await tester.tap(find.byType(Tab).last);
    await tester.pumpAndSettle();
  }
}

void _expectClearance(WidgetTester tester) {
  final bar = tester.getRect(find.byType(AdaptiveBottomNavigation));
  final fab = find.byType(FloatingActionButton);
  expect(fab, findsOneWidget);
  expect(
    bar.top - tester.getBottomRight(fab).dy,
    closeTo(kFloatingActionButtonMargin, 0.01),
    reason: 'FAB 底边应在底栏实际槽位上方保留标准间距',
  );
  expect(fab.hitTestable(), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() => PlatformUtils.debugDesktopOverride = false);
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  testWidgets('横屏话题切回竖屏后回复栏只留系统安全区，返回列表恢复导航间距', (tester) async {
    final index = ValueNotifier(0);
    addTearDown(index.dispose);
    final detail = Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: TopicBottomBar(
          streamIndexListenable: index,
          totalCount: 1,
          replyEntryState: TopicReplyEntryState.reply,
          onReplyEntryTap: () {},
          onOpenTimeline: () {},
          bookmarked: false,
          onBookmark: () {},
          onGestureAction: (_) {},
          onScrubCommit: (_) {},
          filter: const TopicFilterControls(),
        ),
      ),
    );
    await _pumpPage(tester, page: detail, size: const Size(960, 390));
    expect(find.byType(AdaptiveNavigationRail), findsOneWidget);

    const safeBottom = 24.0;
    await _pumpPage(
      tester,
      page: detail,
      size: const Size(390, 960),
      safeBottom: safeBottom,
      hideBottomNavigation: true,
    );
    expect(
      tester.getSize(find.byType(TopicBottomBar)).height,
      TopicBottomBarMetrics.progressLineHeight +
          TopicBottomBarMetrics.contentHeight +
          safeBottom,
    );

    await _pumpPage(
      tester,
      page: const PrivateMessagesPage(),
      size: const Size(390, 960),
    );
    _expectClearance(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final entry in [
    (name: '聊天', page: const ChatListPage()),
    (name: '私信', page: const PrivateMessagesPage()),
  ]) {
    for (final floating in [false, true]) {
      for (final labelless in [false, true]) {
        testWidgets(
          '${entry.name}嵌入底栏后 FAB 留出间距 floating=$floating labelless=$labelless',
          (tester) async {
            await _pumpPage(
              tester,
              page: entry.page,
              floating: floating,
              labelless: labelless,
              safeBottom: labelless ? 0 : 34,
              textScale: labelless ? 1 : 2,
              destinationCount: labelless ? 3 : 5,
            );
            _expectClearance(tester);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }

    testWidgets('${entry.name}独立打开时只避让系统安全区', (tester) async {
      await _pumpPage(tester, page: entry.page, embedded: false);
      expect(find.byType(AdaptiveBottomNavigation), findsNothing);
      expect(
        tester.getBottomRight(find.byType(FloatingActionButton)).dy,
        closeTo(_phone.height - 24 - kFloatingActionButtonMargin, 0.01),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('${entry.name}底栏与侧栏切换时重新计算 FAB 间距', (tester) async {
      await _pumpPage(tester, page: entry.page);
      _expectClearance(tester);

      const wide = Size(1200, 844);
      await _pumpPage(tester, page: entry.page, size: wide);
      expect(find.byType(AdaptiveBottomNavigation), findsNothing);
      expect(find.byType(AdaptiveNavigationRail), findsOneWidget);
      expect(
        tester.getBottomRight(find.byType(FloatingActionButton)).dy,
        closeTo(wide.height - 24 - kFloatingActionButtonMargin, 0.01),
      );

      await _pumpPage(tester, page: entry.page);
      _expectClearance(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('聊天频道与直接消息切换时只在直接消息显示 FAB', (tester) async {
    await _pumpPage(tester, page: const ChatListPage());
    _expectClearance(tester);
    await tester.tap(find.byType(Tab).first);
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
    await tester.tap(find.byType(Tab).last);
    await tester.pumpAndSettle();
    _expectClearance(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
