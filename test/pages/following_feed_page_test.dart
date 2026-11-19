import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/models/following_feed.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/pages/following_feed_page.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/following_feed_provider.dart';
import 'package:fluxdo/providers/following_feed_migration_provider.dart';
import 'package:fluxdo/providers/shortcut_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/common/error_view.dart';
import 'package:fluxdo/widgets/user/activity_post_card.dart';

class _User extends CurrentUserNotifier {
  @override
  Future<User?> build() async => User(id: 1, username: 'alice', trustLevel: 1);
}

void main() {
  testWidgets('窄屏可进入动态、查看旧名单并确认引导', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'seeking_config': '{"users":["bob"]}',
    });
    final prefs = await SharedPreferences.getInstance();
    var requests = 0;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(_User.new),
        followingFeedProvider('alice').overrideWith(
          (ref) => FollowingFeedNotifier((_) async {
            requests++;
            return const FollowingFeedResponse(posts: [], hasMore: false);
          })..refresh(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const FollowingFeedPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('暂无关注动态'), findsOneWidget);
    for (final width in [390.0, 760.0, 1440.0, 390.0]) {
      tester.view.physicalSize = Size(width, 844);
      await tester.pumpAndSettle();
      final list = tester.getRect(find.byType(ListView).first);
      final guide = tester.getRect(
        find.ancestor(of: find.text('追觅已升级为关注动态'), matching: find.byType(Card)),
      );
      expect(guide.left - list.left, 16);
      expect(list.right - guide.right, 16);
      expect(guide.top - list.top, 12);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('追觅已升级为关注动态'));
    await tester.pumpAndSettle();
    expect(find.text('bob'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(container.read(followingFeedMigrationProvider).showGuide, false);
    expect(find.text('暂无关注动态'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('真实 extras 分页响应：滚到底部自动请求并追加第二页', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cursors = <String?>[];
    FollowingFeedResponse response(int start, int count, bool hasMore) =>
        FollowingFeedResponse.fromJson({
          '__rest_serializer': '1',
          'extras': {'has_more': hasMore},
          'posts': [
            for (var id = start; id > start - count; id--)
              {
                'id': id,
                'topic_id': id,
                'post_number': 1,
                'created_at':
                    '2026-11-17T00:00:${id.toString().padLeft(2, '0')}.123456Z',
                'user': {'id': 2, 'username': 'bob', 'avatar_template': ''},
                'topic': {'id': id, 'title': '动态 $id'},
              },
          ],
        });
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith(_User.new),
        followingFeedProvider('alice').overrideWith(
          (ref) => FollowingFeedNotifier((before) async {
            cursors.add(before);
            return before == null
                ? response(30, 20, true)
                : response(10, 10, false);
          })..refresh(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            locale: const Locale('zh'),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const FollowingFeedPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cursors, [null]);
    for (var i = 0; i < 15 && cursors.length == 1; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -650));
      await tester.pumpAndSettle();
    }
    expect(cursors, [null, '2026-11-17T00:00:11.123456Z']);
    final state = container.read(followingFeedProvider('alice'));
    expect(state.posts, hasLength(30));
    expect(state.hasMore, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final expressive in [true, false]) {
    for (final hasPosts in [true, false]) {
      testWidgets('刷新只显示一个指示器并保留内容 M3E=$expressive 有动态=$hasPosts', (
        tester,
      ) async {
        var pending = Completer<FollowingFeedResponse>();
        var requests = 0;
        final response = FollowingFeedResponse(
          posts: [
            if (hasPosts)
              for (var id = 1; id <= 20; id++)
                FollowingPost(
                  id: id,
                  topicId: id,
                  postNumber: 1,
                  createdAtRaw: '2026-11-17T00:00:00.123456Z',
                  title: '动态 $id',
                  author: TopicUser(id: 2, username: 'bob', avatarTemplate: ''),
                ),
          ],
          hasMore: false,
        );
        final container = await _pumpFeed(
          tester,
          expressive: expressive,
          load: (_) {
            requests++;
            return pending.future;
          },
        );
        final list = find.byType(ListView).first;
        final inlineLoading = find.descendant(
          of: list,
          matching: find.byType(LoadingSpinner),
        );
        expect(requests, 1);
        expect(inlineLoading, findsOneWidget);
        pending.complete(response);
        await tester.pumpAndSettle();

        var nonce = 0;
        void refreshFromNavigation() {
          container.read(navActionBusProvider.notifier).state = NavActionEvent(
            targetId: NavEntryIds.followingFeed,
            action: NavAction.refresh,
            nonce: ++nonce,
          );
        }

        void expectSingleRefresh({bool retrying = false}) {
          expect(container.read(followingFeedProvider('alice')).loading, true);
          expect(inlineLoading, findsNothing);
          expect(
            find.byType(LoadingSpinner),
            expressive ? findsOneWidget : findsNothing,
          );
          expect(
            find.byType(RefreshProgressIndicator),
            expressive ? findsNothing : findsOneWidget,
          );
          if (!hasPosts) {
            expect(
              find.text('暂无关注动态'),
              retrying ? findsNothing : findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
        }

        final refreshActions = <Future<void> Function()>[
          () => tester.drag(list, const Offset(0, 350)),
          () => tester.tap(find.byTooltip('刷新')),
          () async => refreshFromNavigation(),
          () async => desktopRefreshNotifier.value++,
        ];
        for (var i = 0; i < refreshActions.length; i++) {
          final scroll = tester.widget<ListView>(list).controller!;
          if (hasPosts && i > 0) {
            scroll.jumpTo(240);
            await tester.pumpAndSettle();
          }
          final offset = scroll.offset;
          final firstPostTop = hasPosts
              ? tester.getTopLeft(find.byType(ActivityPostCard).first)
              : null;
          pending = Completer<FollowingFeedResponse>();
          await refreshActions[i]();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 200));
          expect(requests, i + 2);
          expectSingleRefresh();
          expect(scroll.offset, offset);
          if (hasPosts) {
            expect(
              tester.getTopLeft(find.byType(ActivityPostCard).first),
              firstPostTop,
            );
          }
          refreshFromNavigation();
          await tester.pump(const Duration(milliseconds: 300));
          expect(requests, i + 2);
          pending.complete(response);
          await tester.pumpAndSettle();
          expect(find.byType(LoadingSpinner), findsNothing);
          expect(find.byType(RefreshProgressIndicator), findsNothing);
          expect(scroll.offset, offset);
        }

        pending = Completer<FollowingFeedResponse>();
        await tester.tap(find.byTooltip('刷新'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        pending.completeError(StateError('offline'));
        await tester.pumpAndSettle();
        tester.widget<ListView>(list).controller!.jumpTo(0);
        await tester.pumpAndSettle();
        expect(find.byType(ErrorView), findsOneWidget);
        pending = Completer<FollowingFeedResponse>();
        await tester.tap(find.text('重试'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 200));
        expectSingleRefresh(retrying: true);
        expect(find.byType(ErrorView), findsOneWidget);
        pending.complete(response);
        await tester.pumpAndSettle();
        expect(find.byType(ErrorView), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}

Future<ProviderContainer> _pumpFeed(
  WidgetTester tester, {
  required FollowingFeedLoader load,
  required bool expressive,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final desktopOverride = PlatformUtils.debugDesktopOverride;
  PlatformUtils.debugDesktopOverride = true;
  addTearDown(() => PlatformUtils.debugDesktopOverride = desktopOverride);
  SharedPreferences.setMockInitialValues({
    'seeking_config': '{"users":["bob"]}',
  });
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      currentUserProvider.overrideWith(_User.new),
      followingFeedProvider('alice')
          .overrideWith((ref) => FollowingFeedNotifier(load)..refresh()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData(extensions: [M3eFlags(enabled: expressive)]),
          locale: const Locale('zh'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: const FollowingFeedPage(),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}
