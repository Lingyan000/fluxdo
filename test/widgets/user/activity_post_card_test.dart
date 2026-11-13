import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/category_topics_page.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/selected_topic_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/services/emoji_handler.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/widgets/common/emoji_text.dart';
import 'package:fluxdo/widgets/common/relative_time_text.dart';
import 'package:fluxdo/widgets/common/smart_avatar.dart';
import 'package:fluxdo/widgets/content/collapsed_html_content.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/reaction_emoji.dart';
import 'package:fluxdo/widgets/user/activity_post_card.dart';
import 'package:fluxdo/widgets/user/activity_card_layout.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/preview_fonts.dart';

class _Observer extends NavigatorObserver {
  Route<dynamic>? latest;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      latest = route;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ThemeRegistry.loadBuiltins);
  const captureDir = String.fromEnvironment('ACTIVITY_CAPTURE_DIR');
  final author = TopicUser(
    id: 1,
    username: 'alice',
    name: '林间',
    avatarTemplate: '',
  );
  final actor = TopicUser(id: 2, username: 'pyteng', avatarTemplate: '');
  final liker = TopicUser(id: 3, username: 'neo', avatarTemplate: '');
  final categories = {
    1: Category(
      id: 1,
      name: '开发调优',
      color: '0088cc',
      textColor: 'ffffff',
      slug: 'develop',
    ),
    42: Category(
      id: 42,
      name: '客户端',
      color: '0088cc',
      textColor: 'ffffff',
      slug: 'app',
      parentCategoryId: 1,
    ),
  };
  const boostText = '因为这些细节做得很用心，手机和桌面上用起来都很顺手，继续加油！也期待后续的改进。';

  for (final (width, scale, themeId, dark, background) in [
    (390.0, 1.0, 'material', false, false),
    (390.0, 1.0, 'material', true, false),
    (320.0, 2.0, 'material', false, false),
    (1440.0, 1.0, 'terminal', true, false),
    (1440.0, 1.0, 'material', true, false),
    (760.0, 1.0, 'paper', false, true),
  ]) {
    testWidgets('活动卡 $width/$scale/$themeId/$dark 交互与布局', (tester) async {
      tester.view.physicalSize = Size(width, captureDir.isEmpty ? 900 : 1650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      if (captureDir.isNotEmpty) {
        await tester.runAsync(() async {
          await loadPreviewCjkFont();
          final latinFile = File('/System/Library/Fonts/SFNS.ttf');
          if (latinFile.existsSync()) {
            final loader = FontLoader('ActivityLatin');
            loader.addFont(
              Future.value(ByteData.sublistView(latinFile.readAsBytesSync())),
            );
            await loader.load();
          }
          final emojiFile = File('/System/Library/Fonts/Apple Color Emoji.ttc');
          if (emojiFile.existsSync()) {
            final loader = FontLoader('ActivityEmoji');
            loader.addFont(
              Future.value(ByteData.sublistView(emojiFile.readAsBytesSync())),
            );
            await loader.load();
          }
          final manifest = jsonDecode(
            await rootBundle.loadString('FontManifest.json'),
          ) as List;
          for (final entry in manifest) {
            final family = entry['family'] as String;
            if (!family.contains('Material')) continue;
            final loader = FontLoader(family);
            for (final font in entry['fonts'] as List) {
              loader.addFont(rootBundle.load(font['asset'] as String));
            }
            await loader.load();
          }
        });
      }
      // 预览表情使用本机字体绘制的内存图，布局验证不依赖图片网络请求。
      final recorder = ui.PictureRecorder();
      final painter = TextPainter(
        text: TextSpan(
          text: '👍',
          style: TextStyle(
            fontFamily: captureDir.isNotEmpty ? 'ActivityEmoji' : null,
            fontSize: 28,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(Canvas(recorder), Offset.zero);
      final picture = recorder.endRecording();
      final reactionImage = picture.toImageSync(40, 40);
      picture.dispose();
      painter.dispose();
      PaintingBinding.instance.imageCache.putIfAbsent(
        emojiImageProvider(EmojiHandler().getEmojiUrl('+1')),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: reactionImage)),
        ),
      );
      addTearDown(() {
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
      });
      final state = ThemeState(
        mode: ThemeMode.system,
        seedColor: Colors.blue,
        themeId: themeId,
      );
      final resolved = ThemeResolver.resolve(
        spec: state.themeSpec,
        mode: ThemeMode.system,
        black: false,
        seed: state.seedColor,
        variant: state.schemeVariant,
      );
      final theme = buildAppTheme(
        dark ? resolved.dark : resolved.light,
        dark ? resolved.darkColors : resolved.lightColors,
        state.effectiveShapes,
        state,
        fullscreenSwipeBack: false,
        pageBackground: background,
        style: state.effectiveStyle,
      );
      final taps = <int>[];
      var votePreviews = 0;
      final observer = _Observer();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            categoryMapProvider.overrideWithValue(AsyncData(categories)),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              theme: captureDir.isEmpty
                  ? theme
                  : theme.copyWith(
                      textTheme: theme.textTheme.apply(
                        fontFamily: 'MiSans',
                        fontFamilyFallback: const [
                          'ActivityLatin',
                          'ActivityEmoji',
                        ],
                      ),
                    ),
              navigatorObservers: [observer],
              builder: (context, child) {
                final content = MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                );
                return background
                    ? PageBackgroundScope(
                        backgroundBuilder: (_) =>
                            ColoredBox(color: theme.colorScheme.surface),
                        child: content,
                      )
                    : content;
              },
              home: RepaintBoundary(
                key: const ValueKey('capture'),
                child: Scaffold(
                  backgroundColor: theme.colorScheme.surface,
                  body: EmbeddedStackScope(
                    stackProvider: selectedTopicProvider,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1080),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Column(
                            children: [
                              for (final (index, label, icon, title, excerpt) in [
                                (
                                  0,
                                  '回复',
                                  Symbols.reply_rounded,
                                  'Version 1.0.5 Build 7',
                                  '<p>可以，确实没考虑到这点，改一版看看。<br>感谢反馈，也欢迎继续交流。</p>',
                                ),
                                (
                                  1,
                                  '回复',
                                  Symbols.favorite_border_rounded,
                                  '从可用到好用，记录这次客户端更新',
                                  '国庆节的时候，我们上架了 iOS App 的首个可用版本，并发布了公告。\n\n\n'
                                      '从可用到好用，常用操作放在顺手的位置，页面切换时保留阅读进度。\n\n'
                                      '这次更新也结合了大家的反馈，逐步完善手机、平板和桌面上的阅读体验。',
                                ),
                                (
                                  2,
                                  'Boosts',
                                  Symbols.rocket_launch_rounded,
                                  '分享最近整理的开发工具与使用心得',
                                  '<p>感谢支持，如喜欢也欢迎交流自己的使用体验。</p>',
                                ),
                                (
                                  3,
                                  '回应',
                                  null,
                                  '一个让阅读更舒服的小改进',
                                  '<p>主题 &amp; 字号都可以跟随自己的习惯。</p>',
                                ),
                                (
                                  4,
                                  '已采纳为解决方案',
                                  Symbols.check_circle_rounded,
                                  '如何在桌面端保留阅读进度？',
                                  '<p>设备信息发我一下，也可以直接发我日志。</p>',
                                ),
                              ])
                                ActivityPostCard(
                                  key: ValueKey(index),
                                  position: (index: index, count: 6),
                                  title: title,
                                  author: author,
                                  actionActor: index == 1 ? liker : null,
                                  actionLabel: label,
                                  actionIcon: icon,
                                  postNumber: index + 12,
                                  occurredAt: DateTime.now().toUtc().subtract(
                                    const Duration(hours: 3),
                                  ),
                                  excerpt: excerpt,
                                  bodyFirst: index == 0 || index == 4,
                                  quoteExcerpt: index == 1 || index == 3,
                                  reactionId: index == 3 ? ':+1:' : null,
                                  accepted: index == 4,
                                  categoryId: 42,
                                  categories: categories,
                                  boostNote: index == 2
                                      ? ActivityBoostNote(
                                          actor: actor,
                                          text: boostText,
                                        )
                                      : null,
                                  onTap: () => taps.add(index),
                                ),
                              ActivityTopicCard(
                                position: (index: 5, count: 6),
                                topic: Topic(
                                  id: 73,
                                  title: '一起完善社区的阅读体验',
                                  slug: 'reading',
                                  postsCount: 25,
                                  replyCount: 24,
                                  views: 1200,
                                  likeCount: 42,
                                  categoryId: '42',
                                  excerpt: '<p>从日常使用出发，分享体验与建议。</p>',
                                  unread: 3,
                                  posters: [
                                    TopicPoster(
                                      userId: author.id,
                                      description: '',
                                      extras: '',
                                      user: author,
                                    ),
                                  ],
                                ),
                                categories: categories,
                                onTap: () => taps.add(5),
                                onLongPress: () => votePreviews++,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final cards = find.byType(ActivityPostCard);
      final firstRect = tester.getRect(cards.first);
      if (width < 600) {
        expect(firstRect.left, 0);
        expect(firstRect.right, width);
      }
      for (var i = 1; i < 6; i++) {
        expect(tester.getRect(cards.at(i)).left, firstRect.left);
        expect(tester.getRect(cards.at(i)).right, firstRect.right);
      }
      for (var i = 0; i < 6; i++) {
        final avatar = find
            .descendant(of: cards.at(i), matching: find.byType(SmartAvatar))
            .first;
        final header = find
            .ancestor(of: avatar, matching: find.byType(ActivityCardHeader))
            .first;
        final identity = find
            .descendant(of: header, matching: find.byType(Column))
            .first;
        expect(tester.getRect(avatar).left, firstRect.left + 16);
        expect(
          tester.getCenter(avatar).dy,
          closeTo(tester.getCenter(identity).dy, 0.1),
        );
      }
      expect(
        find.text('主题 & 字号都可以跟随自己的习惯。', findRichText: true),
        findsOneWidget,
      );
      final voteCard = cards.at(5);
      final voteAuthor = find.descendant(
        of: voteCard,
        matching: find.text('林间'),
      );
      final voteAction = find.descendant(
        of: voteCard,
        matching: find.text('投票'),
      );
      final voteTitle = find.descendant(
        of: voteCard,
        matching: find.text('一起完善社区的阅读体验'),
      );
      final voteBody = find.descendant(
        of: voteCard,
        matching: find.byType(CollapsedHtmlContent),
      );
      final voteCategory = find.descendant(
        of: voteCard,
        matching: find.text('开发调优 › 客户端'),
      );
      final voteStats = find.descendant(
        of: voteCard,
        matching: find.byTooltip('24 条回复'),
      );
      for (final (previous, next) in [
        (voteAuthor, voteAction),
        (voteAction, voteTitle),
        (voteTitle, voteBody),
        (voteBody, voteCategory),
        (voteCategory, voteStats),
      ]) {
        expect(
          tester.getRect(next).top,
          greaterThan(tester.getRect(previous).bottom),
        );
      }
      expect(
        find.descendant(of: voteCard, matching: find.byType(Badge)),
        findsOneWidget,
      );
      final note = find.descendant(
        of: find.byType(ActivityBoostNote),
        matching: find.byType(EmojiText),
      );
      expect(tester.widget<EmojiText>(note).text, contains(boostText));
      expect(tester.widget<EmojiText>(note).maxLines, 3);
      expect(find.byType(ActivityBoostNote), findsOneWidget);
      final reactionCard = cards.at(3);
      final reaction = find.descendant(
        of: reactionCard,
        matching: find.byType(ReactionEmoji),
      );
      final reactionTitle = find.descendant(
        of: reactionCard,
        matching: find.text('一个让阅读更舒服的小改进'),
      );
      final reactionExcerpt = find.descendant(
        of: reactionCard,
        matching: find.byType(CollapsedHtmlContent),
      );
      expect(tester.widget<ReactionEmoji>(reaction).reactionId, '+1');
      expect(
        tester.getRect(reaction).top,
        greaterThanOrEqualTo(tester.getRect(reactionTitle).bottom + 10),
      );
      expect(
        tester.getRect(reactionExcerpt).top,
        greaterThanOrEqualTo(tester.getRect(reaction).bottom + 10),
      );
      expect(
        find.descendant(
          of: reactionCard,
          matching: find.byType(ActivityBoostNote),
        ),
        findsNothing,
      );
      final boostExcerpt = find.descendant(
        of: cards.at(2),
        matching: find.byType(CollapsedHtmlContent),
      );
      expect(
        tester.getRect(find.byType(ActivityBoostNote)).top,
        greaterThanOrEqualTo(tester.getRect(boostExcerpt).bottom + 10),
      );

      // 获赞事件独立呈现，点赞人、描述和发生时间对齐。
      final likeCard = cards.at(1);
      final likeAuthor = find
          .ancestor(
            of: find.descendant(of: likeCard, matching: find.text('林间')),
            matching: find.byType(InkWell),
          )
          .first;
      final likeLabel = find.descendant(
        of: likeCard,
        matching: find.text('回复'),
      );
      expect(tester.getRect(likeLabel).left, tester.getRect(likeAuthor).left);
      final likerLink = find
          .ancestor(of: find.text('@neo'), matching: find.byType(InkWell))
          .first;
      expect(
        tester.getRect(likerLink).top,
        lessThan(tester.getRect(likeAuthor).top),
      );
      final likeIcon = find.descendant(
        of: likeCard,
        matching: find.byIcon(Symbols.favorite_rounded),
      );
      final contentLeft = firstRect.left + 16;
      expect(tester.getRect(likeIcon).left, closeTo(contentLeft, 1));
      final receivedLabel = find.text('赞了这条内容');
      if (scale == 1) {
        expect(
          tester.getRect(likerLink).top,
          closeTo(tester.getRect(receivedLabel).top, 0.1),
        );
        expect(
          tester.getCenter(likeIcon).dy,
          closeTo(tester.getCenter(receivedLabel).dy, 0.5),
        );
      }
      if (scale == 1) {
        final likeTime = find.descendant(
          of: find.descendant(
            of: likeCard,
            matching: find.byType(RelativeTimeText),
          ),
          matching: find.byType(Text),
        );
        final likeFloor = find.descendant(
          of: likeCard,
          matching: find.text('#13'),
        );
        final labelParagraph = tester.renderObject<RenderParagraph>(likeLabel);
        final labelBaseline =
            tester.getTopLeft(likeLabel).dy +
            labelParagraph.getDryBaseline(
              labelParagraph.constraints,
              TextBaseline.alphabetic,
            )!;
        for (final label in [likeFloor]) {
          final paragraph = tester.renderObject<RenderParagraph>(label);
          final baseline =
              tester.getTopLeft(label).dy +
              paragraph.getDryBaseline(
                paragraph.constraints,
                TextBaseline.alphabetic,
              )!;
          expect(baseline, closeTo(labelBaseline, 0.1));
        }
        expect(tester.getRect(likeTime).top, tester.getRect(likerLink).top);
      }
      final authorLink = find
          .ancestor(of: find.text('林间').first, matching: find.byType(InkWell))
          .first;
      final authorRect = tester.getRect(authorLink);
      final nameRight = tester.getRect(find.text('林间').first).right;
      final usernameRight = tester.getRect(find.text('@alice').first).right;
      expect(
        authorRect.right,
        closeTo(nameRight > usernameRight ? nameRight : usernameRight, 1),
      );
      final categoryLink = find
          .ancestor(
            of: find.text('开发调优 › 客户端').first,
            matching: find.byType(InkWell),
          )
          .first;
      expect(tester.getRect(categoryLink).left, contentLeft);
      final replyBody = find.descendant(
        of: cards.first,
        matching: find.byType(CollapsedHtmlContent),
      );
      final replyTitle = find.text('Version 1.0.5 Build 7');
      expect(tester.getRect(replyBody).left, contentLeft);
      expect(
        tester.getRect(replyTitle).top,
        greaterThan(tester.getRect(replyBody).bottom),
      );
      expect(tester.getRect(replyTitle).left, contentLeft + 21);
      for (final link in [authorLink, categoryLink]) {
        final ink = tester.widget<InkWell>(link);
        expect(
          ink.overlayColor?.resolve({WidgetState.hovered}),
          Colors.transparent,
        );
        expect(
          ink.overlayColor?.resolve({WidgetState.pressed}),
          Colors.transparent,
        );
        expect(
          ink.overlayColor?.resolve({WidgetState.focused}),
          theme.focusColor,
        );
      }
      if (background) {
        expect(
          tester
              .widget<SegmentedCardItem>(find.byType(SegmentedCardItem).first)
              .color,
          Colors.transparent,
        );
      }
      if (captureDir.isNotEmpty) {
        final mouse = await tester.createGesture(
          kind: ui.PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: Offset.zero);
        for (final (suffix, target) in [
          ('', Offset.zero),
          if (width >= 1000) ...[
            ('-author-hover', authorRect.center),
            ('-category-hover', tester.getRect(categoryLink).center),
          ],
        ]) {
          await mouse.moveTo(target);
          await tester.pumpAndSettle();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            Directory(captureDir).createSync(recursive: true);
            File('$captureDir/$width-$scale-$themeId-$dark$suffix.png')
                .writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await mouse.removePointer();
      }
      // 姓名右侧的留白属于帖子，不能误入个人主页。
      await tester.tapAt(Offset(authorRect.right + 8, authorRect.center.dy));
      expect(taps, [0]);
      taps.clear();
      await tester.tap(find.text('Version 1.0.5 Build 7'));
      expect(taps, [0]);
      await tester.tap(find.text('林间').first);
      await tester.pumpAndSettle();
      final context = tester.element(cards.first);
      final container = ProviderScope.containerOf(context);
      expect(container.read(selectedTopicProvider).topEntry?.username, 'alice');
      expect(taps, [0]);
      await tester.ensureVisible(find.text('@neo'));
      await tester.tap(find.text('@neo'));
      await tester.pumpAndSettle();
      expect(container.read(selectedTopicProvider).topEntry?.username, 'neo');
      expect(taps, [0]);
      await tester.ensureVisible(find.text('开发调优 › 客户端').first);
      await tester.tap(find.text('开发调优 › 客户端').first);
      await tester.idle();
      final route = observer.latest! as InteractionPageRoute;
      expect((route.builder(context) as CategoryTopicsPage).category.id, 42);
      expect(taps, [0]);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      await tester.ensureVisible(voteTitle);
      await tester.longPress(voteTitle);
      await tester.pumpAndSettle();
      expect(votePreviews, 1);
      expect(taps, [0]);
      await tester.tap(voteTitle);
      expect(taps, [0, 5]);
      expect(tester.takeException(), isNull);
    });
  }
}
