import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/widgets/user/user_profile_header.dart';
import 'package:fluxdo/widgets/user/activity_post_card.dart';
import 'package:fluxdo/widgets/user/user_profile_skeleton.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/reaction_emoji.dart';
import 'package:fluxdo/pages/topic_detail_page/topic_detail_page.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';
import 'package:fluxdo/widgets/user/user_profile_cover.dart';

import '../helpers/preview_fonts.dart';

import 'package:visibility_detector/visibility_detector.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/message_bus/session_channel_providers.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/category_topics_page.dart';
import 'package:fluxdo/pages/group_page.dart';
import 'package:fluxdo/models/user_action.dart';
import 'package:fluxdo/pages/user_profile_page.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/utils/hero_visibility_controller.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:m3e_ui/m3e_ui.dart';

class _ProfileService implements DiscourseService {
  _ProfileService(this.user, {this.failSummary = false});
  final User user;
  final bool failSummary;
  int summaryCalls = 0;
  @override
  Future<List<Category>> getCategories() async => [await getCategory(42)];
  @override
  Future<Category> getCategory(int id) async => Category(
    id: id,
    name: '开发调优',
    color: '0088CC',
    textColor: 'FFFFFF',
    slug: 'develop',
  );
  @override
  Future<User> getUser(String username, {bool isSilent = false}) async => user;
  @override
  Future<UserSummary> getUserSummary(
    String username, {
    bool forceRefresh = false,
  }) async {
    summaryCalls++;
    if (failSummary) throw StateError('测试统计失败');
    return UserSummary.fromJson({
      'user_summary': {
        'days_visited': 123,
        'topic_count': 12,
        'post_count': 21,
        'likes_received': 100,
        'likes_given': 86,
        'posts_read_count': 12400,
        'topics_entered': 823,
        'time_read': 185400,
        'recent_time_read': 14400,
        'replies': [
          {'topic_id': 101, 'post_number': 3, 'like_count': 24},
        ],
        'links': [
          {'url': 'https://flutter.dev', 'title': 'Flutter', 'clicks': 42},
        ],
        'top_categories': [
          {
            'id': 1,
            'name': '开发调优',
            'color': '0088CC',
            'topic_count': 12,
            'post_count': 21,
          },
        ],
      },
      'topics': [
        {'id': 101, 'title': 'Flutter 桌面端的多窗口体验', 'like_count': 42},
        {'id': 102, 'title': '分享最近整理的开发工具与使用心得', 'like_count': 26},
      ],
    });
  }

  final requestedFilters = <String?>[];
  Completer<void>? pendingActions;
  int followCalls = 0;
  Completer<void>? pendingFollow;
  @override
  Future<void> followUser(String username) async {
    followCalls++;
    await pendingFollow?.future;
  }

  @override
  Future<UserActionResponse> getUserActions(
    String username, {
    String? filter,
    int offset = 0,
    bool isSilent = false,
  }) async {
    requestedFilters.add(filter);
    await pendingActions?.future;
    return UserActionResponse(
      actions: [
        for (var index = 0; index < 8; index++)
          UserAction(
            actionType: int.tryParse(filter ?? '') ?? 5,
            topicId: 100 + index,
            postNumber: index + 1,
            username: user.username,
            author: TopicUser(
              id: 2,
              username: 'author',
              name: '原帖作者',
              avatarTemplate: '',
            ),
            categoryId: 42,
            title: index.isEven ? 'Flutter 桌面端的多窗口体验' : '分享最近整理的开发工具与使用心得',
            excerpt: index.isEven
                ? '<p>把常用操作放在顺手的位置，页面切换时也能保持阅读进度。最近做了些调整，欢迎一起交流。</p>'
                : '<p>从日常使用出发，整理了一些改善工作体验的小技巧。</p>',
            actingAt: DateTime.now().toUtc().subtract(
              Duration(minutes: 12 + index * 30),
            ),
          ),
      ],
    );
  }

  Map<String, dynamic> get _activityPost => {
    'id': 901,
    'post_id': 901,
    'topic_id': 101,
    'topic_title': '活动原帖',
    'post_number': 24,
    'url': '/t/activity/101/24',
    'category_id': 42,
    'user_id': 2,
    'username': 'author',
    'name': '原帖作者',
    'excerpt': '<p>正文 &amp; 表情都需要保留。</p>',
  };

  @override
  Future<UserReactionsResponse> getUserReactions(
    String username, {
    int? beforeReactionUserId,
    bool isSilent = false,
  }) async => UserReactionsResponse.fromJson([
    {
      'id': 1,
      'post_id': 901,
      'post': _activityPost,
      'reaction': {'reaction_value': 'heart'},
    },
  ]);

  @override
  Future<UserBoostsResponse> getUserBoostsGiven(
    String username, {
    int? beforeBoostId,
    bool isSilent = false,
  }) async => UserBoostsResponse.fromJson({
    'boosts': [
      {'id': 1, 'post': _activityPost, 'cooked': '<p>感谢这些细节上的改进，期待继续完善。</p>'},
    ],
  });

  int solvedCalls = 0;
  Completer<void>? pendingSolved;

  @override
  Future<SolvedPostsResponse> getUserSolvedPosts(
    String username, {
    int offset = 0,
  }) async {
    solvedCalls++;
    await pendingSolved?.future;
    return SolvedPostsResponse.fromJson({
      'user_solved_posts': [_activityPost],
    });
  }

  int votesCalls = 0;
  Completer<void>? pendingVotes;

  @override
  Future<TopicListResponse> getVotedTopics(
    String username, {
    int page = 0,
  }) async {
    votesCalls++;
    await pendingVotes?.future;
    return TopicListResponse(
      topics: [
        for (var index = 0; index < 8; index++)
          Topic(
            id: 200 + index,
            title: '一起完善社区的阅读体验 $index',
            slug: 'reading',
            postsCount: 25,
            replyCount: 24,
            views: 1200,
            likeCount: 42,
            categoryId: '42',
            lastReadPostNumber: 3,
            posters: [
              TopicPoster(
                userId: 2,
                description: 'Original Poster',
                extras: 'latest',
                user: TopicUser(
                  id: 2,
                  username: 'author',
                  name: '原帖作者',
                  avatarTemplate: '',
                ),
              ),
            ],
          ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SignedInUser extends CurrentUserNotifier {
  _SignedInUser(this.user);
  final User user;
  @override
  Future<User?> build() async => user;
}

class _ProfileRouteObserver extends NavigatorObserver {
  Route<dynamic>? latest;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      latest = route;
}

class _UserStatuses extends UserStatusNotifier {
  @override
  Map<int, UserStatus?> build() => {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ThemeRegistry.loadBuiltins);
  setUp(
    () => VisibilityDetectorController.instance.updateInterval = Duration.zero,
  );
  tearDown(
    () => VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    ),
  );
  const captureDir = String.fromEnvironment('PROFILE_CAPTURE_DIR');
  for (final variant in const [
    _ProfileCase(width: 320),
    _ProfileCase(width: 320, textScale: 2),
    _ProfileCase(width: 1100, failSummary: true, cover: true),
    _ProfileCase(width: 1100, dark: true, visitor: true),
    _ProfileCase(width: 1440),
    _ProfileCase(width: 390, hidden: true),
    _ProfileCase(width: 390),
    _ProfileCase(width: 390, platform: TargetPlatform.iOS),
    _ProfileCase(width: 390, dark: true),
    _ProfileCase(width: 390, visitor: true),
    _ProfileCase(width: 390, cover: true),
    _ProfileCase(width: 390, cover: true, dark: true),
    _ProfileCase(width: 390, cover: true, dark: true, topInset: 48),
    _ProfileCase(width: 320, cover: true, textScale: 2, visitor: true),
    _ProfileCase(width: 390, seedColor: Colors.green, visitor: true),
    _ProfileCase(width: 390, themeId: 'minimal', visitor: true),
    _ProfileCase(width: 1100, themeId: 'minimal', dark: true, visitor: true),
    _ProfileCase(width: 390, themeId: 'paper', visitor: true),
    _ProfileCase(width: 1100, themeId: 'nord', dark: true, visitor: true),
  ]) {
    final width = variant.width;
    final textScale = variant.textScale;
    final hidden = variant.hidden;
    final failSummary = variant.failSummary;
    testWidgets('资料页 ${variant.name}', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      if (width < 760) {
        tester.view.padding = FakeViewPadding(top: variant.topInset);
        addTearDown(tester.view.resetPadding);
      }
      if (captureDir.isNotEmpty) {
        await tester.runAsync(_loadCaptureFonts);
      }
      if (variant.cover) {
        await tester.runAsync(() async {
          final codec = await ui.instantiateImageCodec(
            File('assets/images/icon_modern_preview.png').readAsBytesSync(),
          );
          final frame = await codec.getNextFrame();
          PaintingBinding.instance.imageCache.putIfAbsent(
            const BlobImageProvider(
              'https://example.com/profile-cover.png',
              bucket: BlobImageCache.contentBucket,
            ),
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: frame.image)),
            ),
          );
          final viewerKey = await const ResizeImage(
            BlobImageProvider(
              'https://example.com/profile-cover.png',
              bucket: BlobImageCache.originalBucket,
            ),
            width: 2550,
            height: 2550,
            policy: ResizeImagePolicy.fit,
          ).obtainKey(ImageConfiguration.empty);
          PaintingBinding.instance.imageCache.putIfAbsent(
            viewerKey,
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: frame.image.clone())),
            ),
          );
          codec.dispose();
          final avatarCodec = await ui.instantiateImageCodec(
            File('assets/images/icon_default_preview.png').readAsBytesSync(),
          );
          final avatarFrame = await avatarCodec.getNextFrame();
          for (final size in [80, 160]) {
            final avatarKey = await ResizeImage(
              const BlobImageProvider(
                'https://example.com/avatar.png',
                bucket: BlobImageCache.avatarBucket,
              ),
              width: size,
              height: size,
              policy: ResizeImagePolicy.fit,
            ).obtainKey(ImageConfiguration.empty);
            PaintingBinding.instance.imageCache.putIfAbsent(
              avatarKey,
              () => OneFrameImageStreamCompleter(
                Future.value(ImageInfo(image: avatarFrame.image.clone())),
              ),
            );
          }
          avatarFrame.image.dispose();
          avatarCodec.dispose();
        });
        addTearDown(() => PaintingBinding.instance.imageCache.clear());
      }
      final themeState = ThemeState(
        mode: ThemeMode.system,
        themeId: variant.themeId,
        seedColor: variant.seedColor,
      );
      final resolved = ThemeResolver.resolve(
        spec: themeState.themeSpec,
        mode: ThemeMode.system,
        black: false,
        seed: themeState.seedColor,
        variant: themeState.schemeVariant,
      );
      final appTheme = buildAppTheme(
        variant.dark ? resolved.dark : resolved.light,
        variant.dark ? resolved.darkColors : resolved.lightColors,
        themeState.effectiveShapes,
        themeState,
        fullscreenSwipeBack: false,
        pageBackground: variant.dark,
        style: themeState.effectiveStyle,
      );
      final platformTheme = appTheme.copyWith(platform: variant.platform);
      final theme = captureDir.isEmpty
          ? platformTheme
          : platformTheme.copyWith(
              textTheme: platformTheme.textTheme.apply(fontFamily: 'MiSans'),
            );
      tester.view.devicePixelRatio = 1;
      PlatformUtils.debugDesktopOverride = width > 800;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => PlatformUtils.debugDesktopOverride = null);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final user = User(
        id: 1,
        username: 'tester',
        name: textScale > 1 ? '测试用户的长名称' : 'pyteng',
        trustLevel: 2,
        profileHidden: hidden,
        canEdit: true,
        avatarTemplate: variant.cover ? 'https://example.com/avatar.png' : null,
        profileBackgroundUploadUrl: variant.cover
            ? 'https://example.com/profile-cover.png'
            : null,
        title: '不二之选',
        status: hidden ? null : UserStatus(description: '带娃中'),
        bio: hidden ? null : '<p>记录开发、阅读与生活里的新发现。<br>喜欢交流，也在认真打磨手边的工具。</p>',
        location: hidden ? null : '上海',
        createdAt: hidden ? null : DateTime.utc(2024, 6, 1),
        totalFollowing: 12,
        totalFollowers: 177,
        lastSeenAt: DateTime.now().toUtc(),
        canFollow: variant.visitor,
        canSendPrivateMessageToUser: variant.visitor,
        canChatUser: variant.visitor,
        groups: const [TopicGroup(id: 7, name: 'team', fullName: '开发者交流')],
      );
      final service = _ProfileService(user, failSummary: failSummary);
      final observer = _ProfileRouteObserver();
      final checkNavigation =
          width == 390 &&
          !variant.dark &&
          !variant.cover &&
          !hidden &&
          !failSummary &&
          !variant.visitor;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            userStatusProvider.overrideWith(_UserStatuses.new),
            sharedPreferencesProvider.overrideWithValue(preferences),
            discourseServiceProvider.overrideWithValue(service),
            currentUserProvider.overrideWith(
              () => _SignedInUser(
                variant.visitor
                    ? User(id: 2, username: 'visitor', trustLevel: 2)
                    : user,
              ),
            ),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              navigatorObservers: [observer],
              debugShowCheckedModeBanner: false,
              theme: theme,
              locale: const Locale('zh'),
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(textScale)),
                child: RepaintBoundary(
                  key: const ValueKey('profile-capture'),
                  child: PageBackgroundScope(
                    backgroundBuilder: variant.dark
                        ? (_) => ColoredBox(color: theme.colorScheme.surface)
                        : null,
                    child: RoutePageBackground(child: child!),
                  ),
                ),
              ),
              home: UserProfilePage(
                username: 'tester',
                embeddedMode: true,
                onEmbeddedBack: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final avatar = find.byKey(const ValueKey('profile-avatar'));
      final displayName = find.byKey(const ValueKey('profile-display-name'));
      expect(tester.widget<Text>(displayName).data, user.name);
      expect(find.byIcon(Symbols.fullscreen_rounded), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      if (!hidden) {
        expect(service.requestedFilters, isEmpty);
      }
      await _capture(tester, captureDir, '${variant.name}-expanded');
      if (variant.visitor && textScale == 1) {
        _expectFollowColors(tester, theme);
      }
      _expectToolbarColor(tester, theme);
      if (variant.visitor) {
        final contact = find.widgetWithText(OutlinedButton, '联系');
        if (width >= 900) {
          expect(contact, findsNothing);
          expect(find.widgetWithText(OutlinedButton, '私信'), findsOneWidget);
          expect(find.widgetWithText(OutlinedButton, '聊天'), findsOneWidget);
        } else {
          await tester.ensureVisible(contact);
          await tester.pumpAndSettle();
          final follow = find.widgetWithText(FilledButton, '关注').hitTestable();
          final contactSurface = find.descendant(
            of: contact,
            matching: find.byType(Material),
          );
          final followSurface = find.descendant(
            of: follow,
            matching: find.byType(Material),
          );
          expect(
            tester.getSize(contactSurface.first).height,
            tester.getSize(followSurface.first).height,
          );
          await tester.tap(contact);
          await tester.pumpAndSettle();
          expect(
            find.widgetWithIcon(PopupMenuItem<String>, Symbols.mail_rounded),
            findsOneWidget,
          );
          expect(
            find.widgetWithIcon(
              PopupMenuItem<String>,
              Symbols.chat_bubble_rounded,
            ),
            findsOneWidget,
          );
          await _capture(tester, captureDir, '${variant.name}-contact');
          await tester.tapAt(const Offset(12, 760));
          await tester.pumpAndSettle();
          tester
              .widget<ExtendedNestedScrollView>(
                find.byType(ExtendedNestedScrollView),
              )
              .controller!
              .jumpTo(0);
          await tester.pumpAndSettle();
        }
      }
      if (variant.cover) {
        final cover = tester.widget<HeroImage>(
          find.byWidgetPredicate(
            (widget) =>
                widget is HeroImage && widget.heroTag == 'user_cover_tester',
          ),
        );
        expect(cover.effectiveCover, true);
        expect(cover.flightImage, isNotNull);
        if (width == 390 && !variant.dark) {
          final sourceRect = tester.getRect(find.byType(UserProfileCover));
          await tester.tapAt(const Offset(195, 105));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(ImageViewerPage), findsOneWidget);
          expect(find.byType(CoverContainFlightImage), findsWidgets);
          expect(
            HeroVisibilityController.instance.hiddenHeroTag,
            'user_cover_tester',
          );
          final viewer = tester.widget<ImageViewerPage>(
            find.byType(ImageViewerPage),
          );
          expect(viewer.heroSourceFit, BoxFit.cover);
          expect(viewer.thumbnailUrl, user.backgroundUrl);
          await tester.pumpAndSettle();
          navigatorKey.currentState!.pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(CoverContainFlightImage), findsWidgets);
          await tester.pumpAndSettle();
          expect(find.byType(ImageViewerPage), findsNothing);
          expect(HeroVisibilityController.instance.hiddenHeroTag, isNull);
          expect(tester.getRect(find.byType(UserProfileCover)), sourceRect);
          expect(tester.takeException(), isNull);
        }
      }
      if (width == 390 && !hidden) {
        await tester.tap(find.byKey(const ValueKey('profile-more-menu')));
        await tester.pumpAndSettle();
        expect(find.text('关于'), findsNothing);
        expect(
          find.widgetWithIcon(PopupMenuItem<String>, Symbols.settings_rounded),
          variant.visitor ? findsNothing : findsOneWidget,
        );
        expect(
          find.widgetWithText(PopupMenuItem<String>, '分享用户'),
          findsNothing,
        );
        if (variant.visitor) {
          expect(find.byType(PopupMenuDivider), findsNothing);
          expect(
            find.widgetWithIcon(PopupMenuItem<String>, Symbols.mail_rounded),
            findsNothing,
          );
        }
        await tester.tapAt(const Offset(12, 760));
        await tester.pumpAndSettle();
      }

      final morePosition = tester.getCenter(
        find.byKey(const ValueKey('profile-more-menu')),
      );
      final avatarElement = tester.element(avatar);
      final expandedPosition = tester.getTopLeft(avatar);
      _expectProfileToolbarGeometry(tester);
      final nested = tester.widget<ExtendedNestedScrollView>(
        find.byType(ExtendedNestedScrollView),
      );
      final delegate = tester
          .widgetList<SliverPersistentHeader>(
            find.byType(SliverPersistentHeader),
          )
          .map((sliver) => sliver.delegate)
          .whereType<UserProfileHeaderDelegate>()
          .single;
      final travel = delegate.maxExtent - delegate.minExtent;
      final expandedCoverHeight = tester
          .getSize(find.byKey(const ValueKey('profile-header-cover')))
          .height;
      for (final offset in [8.0, 16.0, 32.0, 48.0, 60.0]) {
        nested.controller!.jumpTo(offset);
        await tester.pumpAndSettle();
        final cover = tester.getRect(
          find.byKey(const ValueKey('profile-header-cover')),
        );
        final contentClip = tester.getRect(
          find.byKey(const ValueKey('profile-header-content-clip')),
        );
        expect(cover.height, lessThan(expandedCoverHeight));
        expect(expandedCoverHeight - cover.height, lessThan(offset));
        expect(contentClip.top, closeTo(cover.bottom, 0.01));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('profile-header-content-clip')),
            matching: avatar,
          ),
          findsNothing,
        );
        _expectAvatarPaintBounds(tester, avatar);
        _expectProfileToolbarGeometry(tester);
        if (variant.topInset == 48) {
          await _capture(tester, captureDir, '${variant.name}-scroll-$offset');
        }
      }
      nested.controller!.jumpTo(0);
      await tester.pumpAndSettle();
      if (width == 390 &&
          !variant.cover &&
          !hidden &&
          !variant.visitor &&
          !variant.dark) {
        final calls = service.summaryCalls;
        final canceled = await tester.startGesture(const Offset(180, 330));
        await canceled.moveBy(const Offset(0, 20));
        await tester.pump();
        await canceled.moveBy(const Offset(0, 30));
        await tester.pump();
        await canceled.up();
        await tester.pumpAndSettle();
        expect(service.summaryCalls, calls);
        expect(tester.getTopLeft(avatar), expandedPosition);

        for (final distance in [80.0, 320.0]) {
          final reversed = await tester.startGesture(const Offset(180, 330));
          await reversed.moveBy(const Offset(0, 20));
          await tester.pump();
          await reversed.moveBy(Offset(0, distance));
          await tester.pump();
          await reversed.moveBy(Offset(0, -distance - 160));
          await tester.pump();
          await reversed.up();
          await tester.pumpAndSettle();
          expect(service.summaryCalls, calls);
          expect(nested.controller!.offset, greaterThan(0));
          expect(
            tester
                .widgetList<SliverPersistentHeader>(
                  find.byType(SliverPersistentHeader),
                )
                .map((sliver) => sliver.delegate)
                .whereType<UserProfileHeaderDelegate>()
                .single
                .pullExtent,
            0,
          );
          nested.controller!.jumpTo(0);
          await tester.pumpAndSettle();
        }
        final drag = await tester.startGesture(const Offset(180, 330));
        await drag.moveBy(const Offset(0, 20));
        await tester.pump();
        // 同一手势先收起资料头，再回到顶部，下拉距离应从真正到顶后计算。
        await drag.moveBy(const Offset(0, -180));
        await tester.pump();
        expect(nested.controller!.offset, greaterThan(0));
        await drag.moveBy(const Offset(0, 180));
        await tester.pump();
        expect(nested.controller!.offset, 0);
        await drag.moveBy(const Offset(0, 320));
        await tester.pump(const Duration(milliseconds: 80));
        final pulled = tester
            .widgetList<SliverPersistentHeader>(
              find.byType(SliverPersistentHeader),
            )
            .map((s) => s.delegate)
            .whereType<UserProfileHeaderDelegate>()
            .single;
        expect(pulled.maxExtent, greaterThan(delegate.maxExtent + 10));
        final pulledMore = tester.getCenter(
          find.byKey(const ValueKey('profile-more-menu')),
        );
        expect(
          pulledMore.dy - morePosition.dy,
          closeTo(pulled.pullExtent, 0.01),
        );
        expect(
          tester.getTopLeft(avatar).dy - expandedPosition.dy,
          closeTo(pulled.pullExtent, 0.01),
        );
        await drag.moveBy(const Offset(0, 100));
        await tester.pump();
        expect(
          tester.getCenter(find.byKey(const ValueKey('profile-more-menu'))).dy,
          greaterThan(pulledMore.dy),
        );
        await _capture(tester, captureDir, '${variant.name}-pull');
        await drag.up();
        await tester.pumpAndSettle();
        expect(service.summaryCalls, calls + 1);
        expect(tester.getTopLeft(avatar), expandedPosition);
      }
      nested.controller!.jumpTo(32);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('profile-avatar-opacity')),
            )
            .opacity,
        closeTo(0.25, 0.001),
      );
      await _capture(tester, captureDir, '${variant.name}-avatar-collapse');
      nested.controller!.jumpTo(travel / 2);
      await tester.pumpAndSettle();
      expect(tester.element(avatar), same(avatarElement));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('profile-avatar-opacity')),
            )
            .opacity,
        lessThan(1),
      );
      expect(
        tester.getTopLeft(avatar).dy,
        closeTo(expandedPosition.dy - travel / 2, 0.01),
      );
      await _capture(tester, captureDir, '${variant.name}-middle');
      if (width == 390 && !hidden && !variant.cover && !variant.visitor) {
        await tester.tap(find.byKey(const ValueKey('profile-more-menu')));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithIcon(PopupMenuItem<String>, Symbols.share_rounded),
          findsOneWidget,
        );
        await tester.tapAt(const Offset(12, 760));
        await tester.pumpAndSettle();
      }
      nested.controller!.jumpTo(nested.controller!.position.maxScrollExtent);
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 45));
        expect(
          tester.getCenter(find.byKey(const ValueKey('profile-more-menu'))).dy,
          morePosition.dy,
        );
      }
      await tester.pumpAndSettle();
      expect(tester.element(avatar), same(avatarElement));
      final collapsedMorePosition = tester.getCenter(
        find.byKey(const ValueKey('profile-more-menu')),
      );
      expect(collapsedMorePosition.dy, morePosition.dy);
      expect(collapsedMorePosition.dx, lessThanOrEqualTo(morePosition.dx));
      _expectProfileToolbarGeometry(tester);
      if (variant.topInset == 48 ||
          (checkNavigation && variant.platform == null) ||
          (variant.visitor && width == 390)) {
        final moreElement = tester.element(
          find.byKey(const ValueKey('profile-more-menu')),
        );
        final endOffset = nested.controller!.position.maxScrollExtent;
        final startOffset = (endOffset - 64).clamp(0.0, endOffset);
        final more = find.byKey(const ValueKey('profile-more-menu'));
        nested.controller!.jumpTo(startOffset);
        await tester.pumpAndSettle();
        final expandedX = tester.getCenter(more).dx;
        nested.controller!.jumpTo(endOffset);
        await tester.pump();
        await tester.pump();
        expect(tester.getCenter(more).dx, expandedX);
        var previousFastX = expandedX;
        for (var frame = 1; frame <= 5; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final currentX = tester.getCenter(more).dx;
          expect(currentX, lessThan(previousFastX));
          expect(tester.element(more), same(moreElement));
          _expectProfileToolbarGeometry(tester);
          previousFastX = currentX;
          if (variant.topInset == 48 || variant.visitor) {
            await _capture(tester, captureDir, '${variant.name}-fast-$frame');
          }
        }
        final intermediateX = tester.getCenter(more).dx;
        expect(intermediateX, lessThan(expandedX));
        expect(intermediateX, greaterThan(collapsedMorePosition.dx));
        _expectProfileToolbarGeometry(tester);
        // 过渡途中反向滚动，保留当前画面并向原位置回退。
        nested.controller!.jumpTo(startOffset);
        await tester.pump();
        await tester.pump();
        expect(tester.getCenter(more).dx, intermediateX);
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getCenter(more).dx, greaterThan(intermediateX));
        await tester.pumpAndSettle();
        expect(tester.getCenter(more).dx, expandedX);
        for (final direction in [1, -1]) {
          nested.controller!.jumpTo(direction == 1 ? startOffset : endOffset);
          await tester.pumpAndSettle();
          var previousX = direction == 1
              ? morePosition.dx
              : collapsedMorePosition.dx;
          for (var frame = 0; frame <= 32; frame++) {
            final progress = direction == 1 ? frame / 32 : 1 - frame / 32;
            nested.controller!.jumpTo(
              startOffset + (endOffset - startOffset) * progress,
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 16));
            _expectProfileToolbarGeometry(tester);
            final position = tester.getCenter(more);
            expect(
              (position.dx - previousX) * direction,
              lessThanOrEqualTo(0.01),
            );
            expect(tester.element(more), same(moreElement));
            expect(
              tester
                  .widgetList<Opacity>(
                    find.ancestor(of: more, matching: find.byType(Opacity)),
                  )
                  .every((opacity) => opacity.opacity == 1),
              isTrue,
            );
            previousX = position.dx;
            if (variant.topInset == 48 && direction == 1 && frame % 4 == 0) {
              await _capture(
                tester,
                captureDir,
                '${variant.name}-toolbar-$frame',
              );
            }
          }
        }
        nested.controller!.jumpTo(endOffset);
        await tester.pumpAndSettle();
      }
      final toolbarName = find.byKey(const ValueKey('profile-toolbar-name'));
      expect(tester.getTopLeft(toolbarName).dy, lessThan(delegate.minExtent));
      if (!variant.visitor) expect(find.byTooltip('编辑资料'), findsOneWidget);
      await _capture(tester, captureDir, '${variant.name}-collapsed');
      if (variant.visitor && textScale == 1) {
        _expectFollowColors(tester, theme);
      }
      _expectToolbarColor(tester, theme);
      if (!hidden && !failSummary) {
        final summaryScrollable = find.descendant(
          of: find.byKey(const PageStorageKey('user_tester_summary')),
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.text('开发调优'),
          200,
          scrollable: summaryScrollable,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _capture(tester, captureDir, '${variant.name}-summary-content');
        if (checkNavigation) {
          final context = tester.element(find.text('开发调优'));
          await tester.tap(find.text('开发调优'));
          await tester.idle();
          final route = observer.latest! as InteractionPageRoute;
          expect((route.builder(context) as CategoryTopicsPage).category.id, 1);
          Navigator.of(context).pop();
          await tester.pumpAndSettle();
        }
        tester.state<ScrollableState>(summaryScrollable).position.jumpTo(0);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('profile-more-menu')));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithIcon(PopupMenuItem<String>, Symbols.share_rounded),
        findsOneWidget,
      );
      expect(
        find.widgetWithIcon(PopupMenuItem<String>, Symbols.search_rounded),
        findsOneWidget,
      );
      if (variant.visitor) {
        expect(
          find.widgetWithIcon(PopupMenuItem<String>, Symbols.mail_rounded),
          findsOneWidget,
        );
        expect(
          find.widgetWithIcon(
            PopupMenuItem<String>,
            Symbols.chat_bubble_rounded,
          ),
          findsOneWidget,
        );
      }
      await _capture(tester, captureDir, '${variant.name}-more');
      await tester.tapAt(const Offset(12, 760));
      await tester.pumpAndSettle();

      if (variant.visitor) {
        service.pendingFollow = Completer<void>();
        await tester.tap(find.widgetWithText(FilledButton, '关注').hitTestable());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        final pendingButton = find.byType(FilledButton).hitTestable();
        final spinner = find.descendant(
          of: pendingButton,
          matching: find.byType(LoadingSpinner),
        );
        expect(spinner, findsOneWidget);
        service.pendingFollow!.complete();
        await tester.pumpAndSettle();
        expect(service.followCalls, 1);
        expect(
          find.widgetWithText(OutlinedButton, '已关注').hitTestable(),
          findsOneWidget,
        );
        final followedLabel = find.descendant(
          of: find.widgetWithText(OutlinedButton, '已关注').hitTestable(),
          matching: find.text('已关注'),
        );
        expect(
          tester.renderObject<RenderParagraph>(followedLabel).didExceedMaxLines,
          false,
        );
      }
      expect(tester.takeException(), isNull);
      if (hidden) {
        expect(service.summaryCalls, 0);
        expect(find.byType(TabBar), findsNothing);
      } else {
        expect(tester.widget<TabBar>(find.byType(TabBar)).tabs.length, 4);
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 0);
        service.pendingActions = Completer<void>();
        final tabViewRect = tester.getRect(find.byType(TabBarView));
        final swipe = await tester.startGesture(
          Offset(
            tabViewRect.right - tabViewRect.width * 0.1,
            tabViewRect.center.dy,
          ),
        );
        for (var frame = 0; frame < 8; frame++) {
          await swipe.moveBy(Offset(-tabViewRect.width * 0.1, 0));
          await tester.pump(const Duration(milliseconds: 16));
          if (variant.topInset == 48 && frame.isOdd) {
            await _capture(tester, captureDir, '${variant.name}-tab-$frame');
          }
        }
        await swipe.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          find.descendant(of: find.byType(TabBar), matching: find.text('动态')),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
        expect(find.byType(UserActionListSkeleton), findsOneWidget);
        expect(
          find.descendant(of: find.byType(TabBar), matching: find.text('动态')),
          findsOneWidget,
        );
        service.pendingActions!.complete();
        service.pendingActions = null;
        await tester.pumpAndSettle();
        expect(service.requestedFilters, contains('4,5'));
        expect(service.requestedFilters, isNot(contains(null)));
        expect(find.byType(CheckedPopupMenuItem<String>), findsNothing);
        await tester.tap(find.byTooltip('动态'));
        await tester.pumpAndSettle();
        await _capture(tester, captureDir, '${variant.name}-menu');
        expect(find.byType(CheckedPopupMenuItem<String>), findsWidgets);
        await tester.tapAt(tester.getCenter(find.text('话题').last));
        await tester.pumpAndSettle();
        expect(service.requestedFilters, contains('4'));
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
        var selectedLabel = '话题';
        if (checkNavigation) {
          for (final label in ['赞', '获赞', '回应', 'Boost', '已解决']) {
            await tester.tap(find.byTooltip(selectedLabel));
            await tester.pumpAndSettle();
            if (label == '已解决') service.pendingSolved = Completer<void>();
            await tester.tap(
              find.widgetWithText(CheckedPopupMenuItem<String>, label),
            );
            if (label == '已解决') {
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 500));
              expect(
                tester
                    .widget<UserActionListSkeleton>(
                      find.byType(UserActionListSkeleton),
                    )
                    .type,
                UserActivitySkeletonType.post,
              );
              await _capture(
                tester,
                captureDir,
                '${variant.name}-solved-skeleton',
              );
              service.pendingSolved!.complete();
              service.pendingSolved = null;
            }
            await tester.pumpAndSettle();
            selectedLabel = label;
            final cardFinder = find.byType(ActivityPostCard).first;
            final card = tester.widget<ActivityPostCard>(cardFinder);
            expect(card.author?.username, 'author');
            expect(card.categoryId, 42);
            final like = label == '赞' || label == '获赞';
            expect(card.postNumber, like ? 1 : 24);
            expect(card.quoteExcerpt, label != '已解决' && label != 'Boost');
            if (label == '获赞') {
              expect(card.actionActor?.username, user.username);
              expect(card.actionLabel, '点赞');
              expect(card.boostNote, isNull);
            }
            if (label == 'Boost') {
              expect(find.byType(ActivityBoostNote), findsOneWidget);
              expect(card.reactionId, isNull);
            }
            if (label == '回应') {
              expect(card.boostNote, isNull);
              expect(card.reactionId, 'heart');
              expect(card.actionIcon, isNull);
              expect(find.byType(ActivityBoostNote), findsNothing);
              expect(find.byType(ReactionEmoji), findsOneWidget);
            }
            await _capture(
              tester,
              captureDir,
              '${variant.name}-activity-$label',
            );
            final title = find.descendant(
              of: cardFinder,
              matching: find.text(card.title),
            );
            await tester.ensureVisible(title);
            final context = tester.element(title);
            await tester.tap(title);
            await tester.idle();
            final route = observer.latest! as InteractionPageRoute;
            final detail = route.builder(context) as TopicDetailPage;
            expect(detail.topicId, like ? 100 : 101);
            expect(detail.scrollToPostNumber, like ? 1 : 24);
            Navigator.of(context).pop();
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }
        await tester.tap(find.byTooltip(selectedLabel));
        await tester.pumpAndSettle();
        service.pendingVotes = Completer<void>();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, '投票'),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          tester
              .widget<UserActionListSkeleton>(
                find.byType(UserActionListSkeleton),
              )
              .type,
          UserActivitySkeletonType.topic,
        );
        final skeletonRect = tester.getRect(
          find.byType(SegmentedCardItem).first,
        );
        await _capture(tester, captureDir, '${variant.name}-votes-skeleton');
        service.pendingVotes!.complete();
        service.pendingVotes = null;
        await tester.pumpAndSettle();
        final voteCard = find.byType(ActivityTopicCard).first;
        final voteList = find.ancestor(
          of: voteCard,
          matching: find.byType(ListView),
        );
        final listRect = tester.getRect(voteList);
        final cardRect = tester.getRect(voteCard);
        final voteContent = tester.widget<ActivityPostCard>(
          find.descendant(
            of: voteCard,
            matching: find.byType(ActivityPostCard),
          ),
        );
        expect(cardRect.left, listRect.left + 16);
        expect(cardRect.right, listRect.right - 16);
        expect(cardRect.left, skeletonRect.left);
        expect(cardRect.right, skeletonRect.right);
        final voteSegment = tester.widget<SegmentedCardItem>(
          find.descendant(
            of: voteCard,
            matching: find.byType(SegmentedCardItem),
          ),
        );
        expect(voteSegment.index, 0);
        expect(voteSegment.count, 8);
        expect(voteSegment.gap, 4);
        expect(voteContent.author?.username, 'author');
        expect(voteContent.categoryId, 42);
        expect(voteContent.actionLabel, '投票');
        for (final label in ['24 条回复', '1200 浏览', '42 点赞']) {
          expect(
            find.descendant(of: voteCard, matching: find.byTooltip(label)),
            findsOneWidget,
          );
        }
        final author = find.descendant(
          of: voteCard,
          matching: find.text('原帖作者'),
        );
        final action = find.descendant(of: voteCard, matching: find.text('投票'));
        final title = find.descendant(
          of: voteCard,
          matching: find.text(voteContent.title),
        );
        expect(
          tester.getRect(action).top,
          greaterThan(tester.getRect(author).bottom),
        );
        expect(
          tester.getRect(title).top,
          greaterThan(tester.getRect(action).bottom),
        );
        await _capture(tester, captureDir, '${variant.name}-votes');
        if (checkNavigation) {
          final initialCalls = service.votesCalls;
          service.pendingVotes = Completer<void>();
          nested.controller!.jumpTo(
            nested.controller!.position.maxScrollExtent,
          );
          await tester.pumpAndSettle();
          final listPosition = Scrollable.of(tester.element(voteCard)).position;
          listPosition.jumpTo(100);
          await tester.pumpAndSettle();
          final initialListOffset = listPosition.pixels;
          expect(initialListOffset, greaterThan(0));
          final collapsedOffset = nested.controller!.offset;
          final drag = await tester.startGesture(const Offset(180, 350));
          await drag.moveBy(const Offset(0, 20));
          await tester.pump();
          await drag.moveBy(Offset(0, initialListOffset / 2));
          await tester.pump();
          expect(listPosition.pixels, lessThan(initialListOffset));
          expect(nested.controller!.offset, collapsedOffset);
          await drag.moveBy(Offset(0, initialListOffset));
          await tester.pump();
          expect(nested.controller!.offset, lessThan(collapsedOffset));
          expect(service.votesCalls, initialCalls);
          await drag.moveBy(Offset(0, nested.controller!.offset + 320));
          await tester.pump(const Duration(milliseconds: 80));
          expect(nested.controller!.offset, 0);
          expect(
            tester
                .widgetList<SliverPersistentHeader>(
                  find.byType(SliverPersistentHeader),
                )
                .map((sliver) => sliver.delegate)
                .whereType<UserProfileHeaderDelegate>()
                .single
                .pullExtent,
            greaterThan(0),
          );
          await drag.up();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          expect(service.votesCalls, initialCalls + 1);

          // 请求等待期间仍能收起资料头和滚动，且只刷新当前投票列表一次。
          await tester.dragFrom(const Offset(180, 650), const Offset(0, -200));
          await tester.pump(const Duration(milliseconds: 200));
          expect(nested.controller!.offset, greaterThan(0));
          expect(find.byType(ActivityTopicCard), findsWidgets);
          await tester.dragFrom(const Offset(180, 650), const Offset(0, -700));
          await tester.pump(const Duration(milliseconds: 200));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 240));
          expect(
            find.byKey(const ValueKey('profile-more-menu')).hitTestable(),
            findsOneWidget,
          );
          expect(
            tester.getCenter(find.byKey(const ValueKey('profile-more-menu'))),
            collapsedMorePosition,
          );
          final toolbarName = find.byKey(
            const ValueKey('profile-toolbar-name'),
          );
          final toolbarOpacity = tester.widget<Opacity>(
            find
                .ancestor(of: toolbarName, matching: find.byType(Opacity))
                .first,
          );
          expect(toolbarOpacity.opacity, 1);
          expect(
            tester
                .getSize(
                  find.byKey(const ValueKey('profile-refresh-indicator')),
                )
                .height,
            0,
          );
          await _capture(
            tester,
            captureDir,
            '${variant.name}-refresh-scrolled',
          );
          service.pendingVotes!.complete();
          await tester.pumpAndSettle();
          expect(service.votesCalls, initialCalls + 1);
          service.pendingVotes = null;
          expect(tester.takeException(), isNull);

          // 切回已有内容的筛选项会重新请求，请求中的快速切换复用同一次加载。
          final votesCalls = service.votesCalls;
          final solvedCalls = service.solvedCalls;
          service.pendingSolved = Completer<void>();
          service.pendingVotes = Completer<void>();
          var selected = '投票';
          for (final label in ['已解决', '投票', '已解决', '投票']) {
            await tester.tap(find.byTooltip(selected));
            await tester.pumpAndSettle();
            await tester.tap(
              find.widgetWithText(CheckedPopupMenuItem<String>, label),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            expect(find.byType(UserActionListSkeleton), findsNothing);
            expect(find.byType(ActivityPostCard), findsWidgets);
            selected = label;
          }
          expect(service.votesCalls, votesCalls + 1);
          expect(service.solvedCalls, solvedCalls + 1);
          service.pendingSolved!.complete();
          service.pendingVotes!.complete();
          service.pendingSolved = null;
          service.pendingVotes = null;
          await tester.pumpAndSettle();

          // 从外层页签回到活动也重新加载，动画完成回调不能重复请求。
          await tester.tap(find.byTooltip('关于'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('投票'));
          await tester.pumpAndSettle();
          expect(service.votesCalls, votesCalls + 2);
          expect(tester.takeException(), isNull);
        }
        if (width == 1440) {
          final controller = tester
              .widget<TabBar>(find.byType(TabBar))
              .controller;
          final requests = service.requestedFilters.length;
          tester.view.physicalSize = const Size(520, 850);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TabBar>(find.byType(TabBar)).controller,
            same(controller),
          );
          expect(controller!.index, 1);
          expect(service.requestedFilters.length, requests);
          expect(tester.takeException(), isNull);
          tester.view.physicalSize = Size(width, 850);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TabBar>(find.byType(TabBar)).controller,
            same(controller),
          );
        }
        expect(find.byTooltip('关于'), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('关于'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('关于'));
        await tester.pumpAndSettle();
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
        expect(
          find.byKey(const PageStorageKey('user_tester_about')),
          findsOneWidget,
        );
        if (checkNavigation) {
          final group = find.widgetWithText(ActionChip, '开发者交流');
          await tester.scrollUntilVisible(
            group,
            150,
            scrollable: find
                .descendant(
                  of: find.byKey(const PageStorageKey('user_tester_about')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.ensureVisible(group);
          final context = tester.element(group);
          await tester.tap(group);
          await tester.idle();
          expect(
            ((observer.latest! as InteractionPageRoute).builder(
              context,
            ) as GroupPage).name,
            'team',
          );
          Navigator.of(context).pop();
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        if (failSummary) {
          await tester.tap(find.byTooltip('概览'));
          await tester.pumpAndSettle();
          expect(find.text('加载失败'), findsOneWidget);
        }
      }
      nested.controller!.jumpTo(0);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(avatar), expandedPosition);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('默认封面即时响应明暗和强调色变化', (tester) async {
    final pixels = <Color>[];
    for (final (brightness, accent) in [
      (Brightness.light, Colors.blue),
      (Brightness.dark, Colors.blue),
      (Brightness.dark, Colors.red),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: accent,
              brightness: brightness,
            ),
            extensions: [UiEmphasis(accent: accent, selected: accent)],
          ),
          home: Center(
            child: RepaintBoundary(
              key: const ValueKey('cover-theme'),
              child: SizedBox(
                width: 390,
                height: 180,
                child: UserProfileCover(onTap: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('cover-theme')),
      );
      final color = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final pixel = Color.fromARGB(
          bytes!.getUint8(3),
          bytes.getUint8(0),
          bytes.getUint8(1),
          bytes.getUint8(2),
        );
        image.dispose();
        return pixel;
      });
      pixels.add(color!);
    }
    expect(pixels.toSet().length, 3);
    expect(
      pixels[0].computeLuminance(),
      greaterThan(pixels[1].computeLuminance()),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _ProfileCase {
  const _ProfileCase({
    required this.width,
    this.textScale = 1,
    this.hidden = false,
    this.failSummary = false,
    this.cover = false,
    this.dark = false,
    this.visitor = false,
    this.themeId = 'material',
    this.seedColor = Colors.blue,
    this.platform,
    this.topInset = 24,
  });
  final double width;
  final double textScale;
  final bool hidden;
  final bool failSummary;
  final bool cover;
  final bool dark;
  final bool visitor;
  final String themeId;
  final Color seedColor;
  final TargetPlatform? platform;
  final double topInset;
  String get name =>
      '$width-$textScale-${dark ? "dark" : "light"}${cover ? "-cover" : ""}${hidden ? "-hidden" : ""}${visitor ? "-visitor" : ""}-$themeId-${seedColor.toARGB32()}${platform == null ? "" : "-${platform!.name}"}${topInset == 24 ? "" : "-inset$topInset"}';
}

void _expectAvatarPaintBounds(WidgetTester tester, Finder avatar) {
  final transform = tester.renderObject<RenderTransform>(
    find.descendant(of: avatar, matching: find.byType(Transform)).first,
  );
  final child = transform.child!;
  final bounds = MatrixUtils.transformRect(
    child.getTransformTo(null),
    child.paintBounds,
  );
  RenderObject? ancestor = transform.parent;
  while (ancestor != null) {
    if (ancestor is RenderClipRect && ancestor.clipBehavior != Clip.none) {
      final clip = MatrixUtils.transformRect(
        ancestor.getTransformTo(null),
        Offset.zero & ancestor.size,
      ).inflate(0.01);
      expect(clip.contains(bounds.topLeft), isTrue);
      expect(clip.contains(bounds.bottomRight), isTrue);
    }
    ancestor = ancestor.parent;
  }
}

void _expectProfileToolbarGeometry(WidgetTester tester) {
  final buttons = find.descendant(
    of: find.byType(AppBar),
    matching: find.byType(IconButton),
  );
  final paintedBounds = <Rect>[];
  for (final element in buttons.evaluate()) {
    final button = find.byWidget(element.widget);
    final surface = find
        .descendant(of: button, matching: find.byType(Material))
        .first;
    expect(tester.getSize(surface), const Size.square(40));
    final material = tester.widget<Material>(surface);
    expect(material.shape, element.shapes.circle());
    final visible = tester
        .widgetList<Opacity>(
          find.ancestor(of: button, matching: find.byType(Opacity)),
        )
        .every((opacity) => opacity.opacity == 1);
    if (visible) paintedBounds.add(tester.getRect(surface));
  }
  paintedBounds.sort((first, second) => first.left.compareTo(second.left));
  for (var index = 1; index < paintedBounds.length; index++) {
    expect(
      paintedBounds[index].left - paintedBounds[index - 1].right,
      greaterThanOrEqualTo(7.99),
    );
  }
}

void _expectFollowColors(WidgetTester tester, ThemeData theme) {
  final follow = find.widgetWithText(FilledButton, '关注').hitTestable();
  final surface = tester.widget<Material>(
    find.descendant(of: follow, matching: find.byType(Material)).first,
  );
  expect(surface.color, theme.colorScheme.onSurface);
  final label = find.descendant(of: follow, matching: find.text('关注'));
  expect(
    DefaultTextStyle.of(tester.element(label)).style.color,
    theme.colorScheme.surface,
  );
}

void _expectToolbarColor(WidgetTester tester, ThemeData theme) {
  final icon = find.descendant(
    of: find.byKey(const ValueKey('profile-more-menu')),
    matching: find.byType(RichText),
  );
  final glyph = tester.renderObject<RenderParagraph>(icon);
  expect(glyph.text.style?.color, theme.appBarTheme.actionsIconTheme?.color);
}

Future<void> _loadCaptureFonts() async {
  await loadPreviewCjkFont();
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest) {
    final family = entry['family'] as String;
    if (!family.contains('Material')) continue;
    final loader = FontLoader(family);
    for (final font in entry['fonts'] as List) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

Future<void> _capture(WidgetTester tester, String dir, String name) async {
  if (dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('profile-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
