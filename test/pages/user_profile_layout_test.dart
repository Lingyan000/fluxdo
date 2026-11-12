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
import 'package:fluxdo/widgets/common/hero_image.dart';
import 'package:fluxdo/widgets/user/user_profile_cover.dart';

import '../helpers/preview_fonts.dart';

import 'package:visibility_detector/visibility_detector.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/models/user_action.dart';
import 'package:fluxdo/pages/user_profile_page.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/utils/hero_visibility_controller.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ProfileService implements DiscourseService {
  _ProfileService(this.user, {this.failSummary = false});
  final User user;
  final bool failSummary;
  int summaryCalls = 0;
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
  int followCalls = 0;
  @override
  Future<void> followUser(String username) async {
    followCalls++;
  }

  @override
  Future<UserActionResponse> getUserActions(
    String username, {
    String? filter,
    int offset = 0,
    bool isSilent = false,
  }) async {
    requestedFilters.add(filter);
    return UserActionResponse(
      actions: [
        for (var index = 0; index < 8; index++)
          UserAction(
            actionType: filter == '4' ? 4 : 5,
            topicId: 100 + index,
            postNumber: index + 1,
            username: user.username,
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SignedInUser extends CurrentUserNotifier {
  _SignedInUser(this.user);
  final User user;
  @override
  Future<User?> build() async => user;
}

void main() {
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
    _ProfileCase(width: 390, dark: true),
    _ProfileCase(width: 390, visitor: true),
    _ProfileCase(width: 390, cover: true),
    _ProfileCase(width: 390, cover: true, dark: true),
    _ProfileCase(width: 320, cover: true, textScale: 2, visitor: true),
  ]) {
    final width = variant.width;
    final textScale = variant.textScale;
    final hidden = variant.hidden;
    final failSummary = variant.failSummary;
    testWidgets('资料页 ${variant.name}', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      if (width < 760) {
        tester.view.padding = const FakeViewPadding(top: 24);
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
      const themeState = ThemeState(
        mode: ThemeMode.system,
        seedColor: Colors.blue,
      );
      final resolved = ThemeResolver.resolve(
        spec: ThemeRegistry.material,
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
      );
      final theme = captureDir.isEmpty
          ? appTheme
          : appTheme.copyWith(
              textTheme: appTheme.textTheme.apply(fontFamily: 'MiSans'),
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
      );
      final service = _ProfileService(user, failSummary: failSummary);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
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
      if (variant.visitor) {
        final contact = find.widgetWithText(OutlinedButton, '联系');
        if (width >= 900) {
          expect(contact, findsNothing);
          expect(find.widgetWithText(OutlinedButton, '私信'), findsOneWidget);
          expect(find.widgetWithText(OutlinedButton, '聊天'), findsOneWidget);
        } else {
          await tester.ensureVisible(contact);
          await tester.pumpAndSettle();
          final follow = find.widgetWithText(FilledButton, '关注');
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
        final drag = await tester.startGesture(const Offset(180, 330));
        await drag.moveBy(const Offset(0, 20));
        await tester.pump();
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
        await _capture(tester, captureDir, '${variant.name}-pull');
        await drag.up();
        await tester.pumpAndSettle();
        expect(service.summaryCalls, calls + 1);
        expect(tester.getTopLeft(avatar), expandedPosition);
      }
      nested.controller!.jumpTo(travel / 2);
      await tester.pumpAndSettle();
      expect(tester.element(avatar), same(avatarElement));
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
          tester.getCenter(find.byKey(const ValueKey('profile-more-menu'))),
          morePosition,
        );
      }
      await tester.pumpAndSettle();
      expect(tester.element(avatar), same(avatarElement));
      expect(
        tester.getCenter(find.byKey(const ValueKey('profile-more-menu'))),
        morePosition,
      );
      final toolbarName = find.byKey(const ValueKey('profile-toolbar-name'));
      expect(tester.getTopLeft(toolbarName).dy, lessThan(delegate.minExtent));
      if (!variant.visitor) expect(find.byTooltip('编辑资料'), findsOneWidget);
      await _capture(tester, captureDir, '${variant.name}-collapsed');
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
        await tester.tap(find.widgetWithText(FilledButton, '关注').hitTestable());
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
        await tester.tap(find.byTooltip('动态'));
        await tester.pumpAndSettle();
        expect(find.byType(CheckedPopupMenuItem<String>), findsNothing);
        await tester.tap(find.byTooltip('动态'));
        await tester.pumpAndSettle();
        await _capture(tester, captureDir, '${variant.name}-menu');
        expect(find.byType(CheckedPopupMenuItem<String>), findsWidgets);
        await tester.tapAt(tester.getCenter(find.text('话题').last));
        await tester.pumpAndSettle();
        expect(service.requestedFilters, contains('4'));
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 1);
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
        await tester.tap(find.byTooltip('关于'));
        await tester.pumpAndSettle();
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, 3);
        expect(
          find.byKey(const PageStorageKey('user_tester_about')),
          findsOneWidget,
        );
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
  });
  final double width;
  final double textScale;
  final bool hidden;
  final bool failSummary;
  final bool cover;
  final bool dark;
  final bool visitor;
  String get name =>
      '$width-$textScale-${dark ? "dark" : "light"}${cover ? "-cover" : ""}${hidden ? "-hidden" : ""}${visitor ? "-visitor" : ""}';
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
