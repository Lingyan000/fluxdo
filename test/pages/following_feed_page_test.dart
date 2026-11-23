import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/models/following_feed.dart';
import 'package:fluxdo/navigation/nav_action_bus.dart';
import 'package:fluxdo/pages/following_feed_page.dart';
import 'package:fluxdo/pages/follow_list_page.dart';
import 'package:fluxdo/pages/user_profile_page.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/following_feed_provider.dart';
import 'package:fluxdo/providers/following_feed_migration_provider.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';
import 'package:fluxdo/providers/shortcut_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/widgets/common/error_view.dart';
import 'package:fluxdo/widgets/user/activity_card_layout.dart';
import 'package:fluxdo/widgets/user/activity_post_card.dart';
import 'package:fluxdo/widgets/user/user_profile_skeleton.dart';

import '../helpers/preview_fonts.dart';

class _User extends CurrentUserNotifier {
  @override
  Future<User?> build() async => User(id: 1, username: 'alice', trustLevel: 1);
}

class _FollowService extends Fake implements DiscourseService {
  @override
  Future<List<FollowUser>> getFollowing(String username) async => [];

  @override
  Future<List<FollowUser>> getFollowers(String username) async => [];
}

class _RouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    latest = route;
  }
}

const _emptyFeed = FollowingFeedResponse(posts: [], hasMore: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await ThemeRegistry.loadBuiltins();
    for (final locale in AppLocale.values) {
      await LocaleSettings.setLocale(locale);
    }
    LocaleSettings.setLocaleSync(AppLocale.zh);
  });
  tearDown(() => LocaleSettings.setLocaleSync(AppLocale.zh));
  const captureDir = String.fromEnvironment('FOLLOWING_GUIDE_CAPTURE_DIR');

  testWidgets('一次性说明可直接查看旧名单，关闭后从我的关注找回', (tester) async {
    final observer = _RouteObserver();
    final container = await _pumpFeed(
      tester,
      preferences: {'seeking_config': '{"users":["bob"]}'},
      observer: observer,
    );
    await tester.pumpAndSettle();
    expect(find.text('从追觅到关注动态'), findsOneWidget);
    expect(find.byType(AppSheetScaffold), findsOneWidget);
    expect(find.byIcon(Symbols.info_rounded), findsNothing);
    expect(container.read(followingFeedMigrationProvider).showGuide, false);

    await tester.tap(find.text('查看旧名单'));
    await tester.pumpAndSettle();
    expect(find.text('旧追觅名单'), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('从追觅到关注动态'), findsNothing);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('暂无关注动态'), findsOneWidget);

    await tester.tap(find.byTooltip('我的关注'));
    await tester.pumpAndSettle();
    expect(find.byType(FollowListPage), findsOneWidget);
    await tester.tap(find.text('旧追觅名单'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSheetScaffold), findsOneWidget);
    expect(find.text('bob'), findsOneWidget);
    await tester.tap(find.text('bob'));
    await tester.idle();
    final profile = (observer.latest! as InteractionPageRoute).builder(
      tester.element(find.byType(FollowListPage)),
    ) as UserProfilePage;
    expect(profile.username, 'bob');
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    container.invalidate(followingFeedMigrationProvider);
    await tester.pumpAndSettle();
    expect(find.byType(AppSheetScaffold), findsNothing);
    expect(find.text('暂无关注动态'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final close in ['开始浏览', '关闭', '返回', '遮罩', '下滑']) {
    testWidgets('隐藏页面延迟引导，$close 后重新进入也不再展示', (tester) async {
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      var requests = 0;
      final container = await _pumpFeed(
        tester,
        preferences: {'seeking_enabled': true},
        home: ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (context, active, _) => FollowingFeedPage(isActive: active),
        ),
        load: (_) async {
          requests++;
          return _emptyFeed;
        },
      );
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(container.read(followingFeedMigrationProvider).showGuide, true);
      expect(find.byType(AppSheetScaffold), findsNothing);
      active.value = true;
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.byType(AppSheetScaffold), findsOneWidget);
      expect(find.text('查看旧名单'), findsNothing);
      switch (close) {
        case '开始浏览':
          await tester.tap(find.text(close));
        case '关闭':
          await tester.tap(find.byIcon(Symbols.close_rounded));
        case '返回':
          await tester.binding.handlePopRoute();
        case '遮罩':
          await tester.tapAt(const Offset(10, 10));
        case '下滑':
          await tester.fling(find.text('从追觅到关注动态'), const Offset(0, 500), 2000);
      }
      await tester.pumpAndSettle();
      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pumpAndSettle();
      expect(find.byType(AppSheetScaffold), findsNothing);
      expect(find.byIcon(Symbols.info_rounded), findsNothing);
      expect(
        container
            .read(sharedPreferencesProvider)
            .getBool('following_feed_migration_seen'),
        true,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final (width, height, scale, dark, locale) in [
    (390.0, 844.0, 1.0, false, const Locale('zh')),
    (390.0, 844.0, 1.0, true, const Locale('zh')),
    (320.0, 640.0, 2.0, false, const Locale('zh')),
    (844.0, 390.0, 1.0, false, const Locale('en')),
    (1440.0, 900.0, 1.0, true, const Locale('zh')),
  ]) {
    testWidgets('引导与长名单适配 $width/$height/$scale/$dark/$locale', (tester) async {
      final state = ThemeState(
        mode: ThemeMode.system,
        seedColor: Colors.blue,
        themeId: 'material',
      );
      final resolved = ThemeResolver.resolve(
        spec: state.themeSpec,
        mode: ThemeMode.system,
        black: false,
        seed: state.seedColor,
        variant: state.schemeVariant,
      );
      var theme = buildAppTheme(
        dark ? resolved.dark : resolved.light,
        dark ? resolved.darkColors : resolved.lightColors,
        state.effectiveShapes,
        state,
        fullscreenSwipeBack: false,
        pageBackground: false,
      );
      if (captureDir.isNotEmpty) {
        await tester.runAsync(() async {
          await loadPreviewCjkFont();
          final manifest = jsonDecode(
            await rootBundle.loadString('FontManifest.json'),
          ) as List;
          for (final entry in manifest) {
            final loader = FontLoader(entry['family'] as String);
            for (final font in entry['fonts'] as List) {
              loader.addFont(rootBundle.load(font['asset'] as String));
            }
            await loader.load();
          }
        });
        theme = theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'MiSans'),
        );
      }
      await _pumpFeed(
        tester,
        size: Size(width, height),
        scale: scale,
        locale: locale,
        theme: theme,
        preferences: {
          'seeking_config': jsonEncode({
            'users': List.generate(40, (index) => 'member_$index'),
          }),
        },
      );
      await tester.pumpAndSettle();
      final l10n = tester.element(find.byType(AppSheetScaffold)).l10n;
      expect(
        find.text(l10n.followingFeed_migrationContinue).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.text(l10n.followingFeed_viewLegacyUsers).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      Future<void> capture(String stage) async {
        if (captureDir.isEmpty) return;
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('feed-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$captureDir/${stage}_${width}_${scale}_$dark.png')
              .writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('guide');
      await tester.tap(find.text(l10n.followingFeed_viewLegacyUsers));
      await tester.pumpAndSettle();
      await capture('legacy');
      await tester.scrollUntilVisible(
        find.text('member_39'),
        350,
        scrollable: find.descendant(
          of: find.byType(AppSheetScaffold),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('member_39').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('legacy_end');
      await tester.tap(find.byIcon(Symbols.close_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(AppSheetScaffold), findsNothing);
      await capture('feed');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final preferences in [
    <String, Object>{},
    <String, Object>{
      'seeking_config': '{"users":["bob"]}',
      'following_feed_migration_seen': true,
    },
  ]) {
    testWidgets('新用户和已确认用户直接进入动态 $preferences', (tester) async {
      await _pumpFeed(tester, preferences: preferences);
      await tester.pumpAndSettle();
      expect(find.byType(AppSheetScaffold), findsNothing);
      expect(find.byIcon(Symbols.info_rounded), findsNothing);
      expect(find.text('暂无关注动态'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final (username, isFollowing, showLegacy) in [
    ('Alice', true, true),
    ('bob', true, false),
    ('alice', false, false),
  ]) {
    testWidgets('旧名单仅在自己的关注列表出现 $username/$isFollowing', (tester) async {
      await _pumpFeed(
        tester,
        home: FollowListPage(username: username, isFollowing: isFollowing),
      );
      await tester.pumpAndSettle();
      expect(find.text('旧追觅名单'), showLegacy ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
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
        categoryMapProvider.overrideWithValue(const AsyncValue.data({})),
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
      testWidgets('首屏骨架屏、刷新单指示器并保留内容 M3E=$expressive 有动态=$hasPosts', (
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
        expect(requests, 1);
        expect(find.byType(UserActionListSkeleton), findsOneWidget);
        expect(find.byTooltip('刷新'), findsNothing);
        pending.complete(response);
        await tester.pumpAndSettle();
        expect(find.byType(UserActionListSkeleton), findsNothing);

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
          expect(find.byType(UserActionListSkeleton), findsNothing);
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

        final scrollable = hasPosts
            ? find.byType(ListView).first
            : find.byType(CustomScrollView).first;
        final refreshActions = <({bool resetsToTop, Future<void> Function() run})>[
          (
            resetsToTop: false,
            run: () => tester.drag(scrollable, const Offset(0, 350)),
          ),
          (
            resetsToTop: false,
            run: () async => desktopRefreshNotifier.value++,
          ),
          (
            resetsToTop: true,
            run: () async => refreshFromNavigation(),
          ),
        ];
        for (var i = 0; i < refreshActions.length; i++) {
          final action = refreshActions[i];
          final scroll = hasPosts
              ? tester.widget<ListView>(scrollable).controller!
              : null;
          if (hasPosts && i > 0) {
            scroll!.jumpTo(240);
            await tester.pumpAndSettle();
          }
          final offset = scroll?.offset ?? 0;
          final firstPostTop = hasPosts && !action.resetsToTop
              ? tester.getTopLeft(find.byType(ActivityPostCard).first)
              : null;
          pending = Completer<FollowingFeedResponse>();
          await action.run();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump(const Duration(milliseconds: 200));
          expect(requests, i + 2);
          expectSingleRefresh();
          if (hasPosts && !action.resetsToTop) {
            expect(scroll!.offset, offset);
            expect(
              tester.getTopLeft(find.byType(ActivityPostCard).first),
              firstPostTop,
            );
          }
          if (action.resetsToTop) {
            expect(
              container.read(
                navScrollProgressProvider(NavEntryIds.followingFeed),
              ),
              0.0,
            );
          }
          refreshFromNavigation();
          await tester.pump(const Duration(milliseconds: 300));
          expect(requests, i + 2);
          pending.complete(response);
          await tester.pumpAndSettle();
          expect(find.byType(LoadingSpinner), findsNothing);
          expect(find.byType(RefreshProgressIndicator), findsNothing);
          if (hasPosts) {
            expect(scroll!.offset, action.resetsToTop ? 0.0 : offset);
          }
        }

        pending = Completer<FollowingFeedResponse>();
        desktopRefreshNotifier.value++;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        pending.completeError(StateError('offline'));
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

  testWidgets('卡片展示动作图标、回复正文优先、分类、屏蔽过滤、滚动进度与底部留白', (
    tester,
  ) async {
    final category = Category(
      id: 42,
      name: '开发调优',
      slug: 'dev',
      color: '0088CC',
      textColor: 'FFFFFF',
    );
    final container = await _pumpFeed(
      tester,
      size: const Size(390, 844),
      bottomPadding: 80,
      categories: {42: category},
      load: (_) async => FollowingFeedResponse(
        posts: [
          FollowingPost(
            id: 1,
            topicId: 101,
            postNumber: 1,
            createdAtRaw: '2026-11-17T00:00:03.000000Z',
            title: '新话题标题',
            author: TopicUser(id: 2, username: 'bob', avatarTemplate: ''),
            excerpt: '<p>主题正文</p>',
            categoryId: 42,
          ),
          FollowingPost(
            id: 2,
            topicId: 102,
            postNumber: 5,
            createdAtRaw: '2026-11-17T00:00:02.000000Z',
            title: '被回复的话题',
            author: TopicUser(id: 3, username: 'carol', avatarTemplate: ''),
            excerpt: '<p>这是回复正文</p>',
            categoryId: 42,
          ),
          FollowingPost(
            id: 3,
            topicId: 103,
            postNumber: 1,
            createdAtRaw: '2026-11-17T00:00:01.000000Z',
            title: '被屏蔽用户的帖子',
            author: TopicUser(id: 4, username: 'blocked', avatarTemplate: ''),
          ),
          for (var i = 4; i <= 15; i++)
            FollowingPost(
              id: i,
              topicId: 100 + i,
              postNumber: 1,
              createdAtRaw:
                  '2026-11-16T00:00:${i.toString().padLeft(2, '0')}.000000Z',
              title: '更多动态 $i',
              author: TopicUser(id: 2, username: 'bob', avatarTemplate: ''),
            ),
        ],
        hasMore: true,
      ),
    );
    await tester.pumpAndSettle();

    // 不再显示多余的独立「加载更多」按钮
    expect(find.byType(TextButton), findsNothing);
    // 列表底部避让悬浮底栏高度
    final listView = tester.widget<ListView>(find.byType(ListView).first);
    expect((listView.padding as EdgeInsets).bottom, greaterThanOrEqualTo(92));
    // 分类展示
    expect(find.text('开发调优'), findsNWidgets(2));
    // 发帖和回复的动作图标与回复 bodyFirst
    final cards = tester
        .widgetList<ActivityPostCard>(find.byType(ActivityPostCard))
        .toList();
    expect(cards[0].actionIcon, Symbols.article_rounded);
    expect(cards[0].bodyFirst, false);
    expect(cards[1].actionIcon, Symbols.reply_rounded);
    expect(cards[1].bodyFirst, true);

    // 滚动上报进度到 navScrollProgressProvider
    listView.controller!.jumpTo(320);
    await tester.pump();
    expect(
      container.read(navScrollProgressProvider(NavEntryIds.followingFeed)),
      320.0,
    );

    // 本地屏蔽过滤
    await container
        .read(preferencesProvider.notifier)
        .setBlockedUsernames(['blocked']);
    await tester.pumpAndSettle();
    expect(find.text('被屏蔽用户的帖子'), findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('双栏选中态判定与 ActivityPostCard 高亮透传', (tester) async {
    final post1 = FollowingPost(
      id: 1,
      topicId: 101,
      postNumber: 1,
      createdAtRaw: '2026-11-17T00:00:03.000000Z',
      title: '话题 A',
      author: TopicUser(id: 2, username: 'bob', avatarTemplate: ''),
    );
    final post2 = FollowingPost(
      id: 2,
      topicId: 101,
      postNumber: 5,
      createdAtRaw: '2026-11-17T00:00:02.000000Z',
      title: '话题 A',
      author: TopicUser(id: 3, username: 'carol', avatarTemplate: ''),
    );
    const selected = PaneEntry.topic(topicId: 101, scrollToPostNumber: 5);
    expect(
      isFollowingPostSelected(wide: true, selectedTop: selected, post: post1),
      false,
    );
    expect(
      isFollowingPostSelected(wide: true, selectedTop: selected, post: post2),
      true,
    );
    expect(
      isFollowingPostSelected(wide: false, selectedTop: selected, post: post2),
      false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ActivityPostCard(
            position: (index: 0, count: 1),
            highlighted: true,
            title: '话题 A',
            actionLabel: '回复了',
            onTap: () {},
          ),
        ),
      ),
    );
    final frame = tester.widget<ActivityCardFrame>(
      find.byType(ActivityCardFrame),
    );
    expect(frame.highlighted, true);
  });

  testWidgets('未登录时使用统一空态组件展示', (tester) async {
    await _pumpFeed(
      tester,
      loggedIn: false,
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppEmptyState), findsOneWidget);
    expect(find.text('登录后查看关注动态'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _NullUser extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;
}

Future<ProviderContainer> _pumpFeed(
  WidgetTester tester, {
  FollowingFeedLoader? load,
  bool expressive = true,
  bool loggedIn = true,
  double bottomPadding = 0,
  Map<int, Category> categories = const {},
  Map<String, Object> preferences = const {
    'seeking_config': '{"users":["bob"]}',
    'following_feed_migration_seen': true,
  },
  Widget home = const FollowingFeedPage(),
  NavigatorObserver? observer,
  Size size = const Size(390, 844),
  double scale = 1,
  ThemeData? theme,
  Locale locale = const Locale('zh'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final desktopOverride = PlatformUtils.debugDesktopOverride;
  PlatformUtils.debugDesktopOverride = true;
  addTearDown(() => PlatformUtils.debugDesktopOverride = desktopOverride);
  SharedPreferences.setMockInitialValues({
    'pref_dialog_blur': false,
    ...preferences,
  });
  final prefs = await SharedPreferences.getInstance();
  LocaleSettings.setLocaleRawSync(locale.toLanguageTag());
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      currentUserProvider.overrideWith(
        loggedIn ? _User.new : _NullUser.new,
      ),
      discourseServiceProvider.overrideWithValue(_FollowService()),
      categoryMapProvider.overrideWithValue(AsyncValue.data(categories)),
      followingFeedProvider('alice').overrideWith(
        (ref) =>
            FollowingFeedNotifier(load ?? (_) async => _emptyFeed)..refresh(),
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
          theme:
              theme ?? ThemeData(extensions: [M3eFlags(enabled: expressive)]),
          locale: locale,
          debugShowCheckedModeBanner: false,
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(scale),
                padding: mq.padding.copyWith(bottom: bottomPadding),
              ),
              child: RepaintBoundary(
                key: const ValueKey('feed-capture'),
                child: child!,
              ),
            );
          },
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: AppLocaleUtils.supportedLocales,
          navigatorObservers: [?observer],
          home: home,
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}
