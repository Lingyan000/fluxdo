import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/services/emoji_handler.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_action_bar.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_reaction_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _reactionIds = [
  'heart',
  '+1',
  'laughing',
  'open_mouth',
  'clap',
  'smile',
  'thinking',
  'cry',
];

Finder _reactionImage(String id) => find.byWidgetPredicate(
  (widget) =>
      widget is Image &&
      widget.width == 28 &&
      widget.image == emojiImageProvider(EmojiHandler().getEmojiUrl(id)),
);

class _ActionBarHarness {
  final likeButtonKey = GlobalKey();
  final isLoadingReplies = ValueNotifier(false);
  final showReplies = ValueNotifier(false);
  final selected = <String>[];
  int likes = 0;

  Widget build({
    bool scrollable = false,
    bool isGuest = false,
    bool isOwnPost = false,
  }) {
    final bar = PostActionBar(
      post: Post(
        id: 1,
        username: 'tester',
        avatarTemplate: '',
        cooked: '',
        postNumber: 1,
        postType: 1,
        updatedAt: DateTime.utc(2026, 9, 9),
        createdAt: DateTime.utc(2026, 9, 9),
        likeCount: 0,
        replyCount: 0,
      ),
      isGuest: isGuest,
      isOwnPost: isOwnPost,
      isLiking: false,
      reactions: const [],
      currentUserReaction: null,
      likeButtonKey: likeButtonKey,
      replies: const [],
      isLoadingRepliesNotifier: isLoadingReplies,
      showRepliesNotifier: showReplies,
      onToggleLike: () => likes++,
      onReactionSelected: selected.add,
      onShowReactionUsers: (_) {},
      onShowMoreMenu: () {},
      onToggleReplies: () {},
    );
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: scrollable
              ? SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 240),
                      bar,
                      const SizedBox(height: 1200),
                    ],
                  ),
                )
              : Center(child: bar),
        ),
      ),
    );
  }

  void dispose() {
    isLoadingReplies.dispose();
    showReplies.dispose();
  }
}

Future<TestGesture> _holdButton(
  WidgetTester tester,
  _ActionBarHarness harness,
) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(harness.likeButtonKey)),
  );
  await tester.pump(kReactionPickerLongPressDuration);
  await tester.pumpAndSettle();
  return gesture;
}

Future<ReactionPickerController> _openControllerPicker(
  WidgetTester tester, {
  required Rect buttonRect,
}) async {
  final controller = ReactionPickerController(
    vsync: const TestVSync(),
    onReactionSelected: (_) {},
  );
  addTearDown(controller.dispose);
  late BuildContext pickerContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          pickerContext = context;
          return const Scaffold();
        },
      ),
    ),
  );
  controller.open(
    context: pickerContext,
    buttonRect: buttonRect,
    reactions: _reactionIds,
    currentUserReaction: null,
    theme: Theme.of(pickerContext),
    mode: ReactionPickerMode.touch,
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlatformUtils.debugDesktopOverride = false;

    // 向图片缓存注入内存图，手势测试不依赖网络、磁盘或原生解码器。
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawCircle(const Offset(14, 14), 12, Paint()..color = Colors.amber);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(28, 28);
    picture.dispose();
    for (final id in _reactionIds) {
      PaintingBinding.instance.imageCache.putIfAbsent(
        emojiImageProvider(EmojiHandler().getEmojiUrl(id)),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: image.clone())),
        ),
      );
    }
    image.dispose();
  });

  tearDown(() {
    PlatformUtils.debugDesktopOverride = null;
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  testWidgets('原地长按就显示面板，松手后可直接点选', (tester) async {
    final harness = _ActionBarHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    final gesture = await _holdButton(tester, harness);
    final image = _reactionImage('heart');
    expect(image, findsOneWidget);
    // 只检查节点存在抓不到零尺寸浮层：还要确认它实际落在可绘制区域内。
    final stacks = find.ancestor(of: image, matching: find.byType(Stack));
    for (final element in stacks.evaluate()) {
      final box = element.findRenderObject()! as RenderBox;
      expect(box.size.isEmpty, isFalse);
    }
    expect(harness.selected, isEmpty);
    expect(harness.likes, 0);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(image.hitTestable(), findsOneWidget);
    final beforeFlight = tester.getRect(image);
    await tester.tap(image);
    await tester.pump();
    final flyingImage = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image ==
              emojiImageProvider(EmojiHandler().getEmojiUrl('heart')),
    );
    expect(flyingImage, findsOneWidget);
    expect(tester.getRect(flyingImage), beforeFlight);
    expect(harness.selected, isEmpty);
    await tester.pumpAndSettle();
    expect(harness.selected, ['heart']);
    expect(harness.likes, 0);
    expect(_reactionImage('heart'), findsNothing);
  });

  testWidgets('长按后上滑选中，松手只提交一次', (tester) async {
    final harness = _ActionBarHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    final gesture = await _holdButton(tester, harness);
    await gesture.moveTo(tester.getCenter(_reactionImage('laughing')));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(harness.selected, ['laughing']);
    expect(harness.likes, 0);
    expect(_reactionImage('heart'), findsNothing);
  });

  testWidgets('短按只点赞，不弹出面板', (tester) async {
    final harness = _ActionBarHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    await tester.tap(find.byKey(harness.likeButtonKey));
    await tester.pumpAndSettle();

    expect(harness.likes, 1);
    expect(harness.selected, isEmpty);
    expect(_reactionImage('heart'), findsNothing);
  });

  testWidgets('从点赞按钮起手滚动，不误弹面板或点赞', (tester) async {
    final harness = _ActionBarHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build(scrollable: true));

    await tester.timedDrag(
      find.byKey(harness.likeButtonKey),
      const Offset(0, -120),
      const Duration(milliseconds: 200),
    );
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.pixels, greaterThan(0));
    expect(harness.likes, 0);
    expect(harness.selected, isEmpty);
    expect(_reactionImage('heart'), findsNothing);
  });

  testWidgets('长按松手后点击外部关闭面板', (tester) async {
    final harness = _ActionBarHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    final gesture = await _holdButton(tester, harness);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(harness.selected, isEmpty);
    expect(_reactionImage('heart'), findsNothing);
  });

  testWidgets('长按后拖远松手取消选择', (tester) async {
    final harness = _ActionBarHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    final gesture = await _holdButton(tester, harness);
    await gesture.moveTo(const Offset(20, 580));
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(harness.selected, isEmpty);
    expect(_reactionImage('heart'), findsNothing);
  });

  testWidgets('桌面端悬停按钮直接展开，支持点选', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    final harness = _ActionBarHarness();
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.build());

    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(20, 20));
    await mouse.moveTo(tester.getCenter(find.byKey(harness.likeButtonKey)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(_reactionImage('heart').hitTestable(), findsOneWidget);
    await tester.tap(_reactionImage('heart'));
    await tester.pumpAndSettle();
    expect(harness.selected, ['heart']);
  });

  testWidgets('窄屏自动换行，所有表情均可点选', (tester) async {
    tester.view.physicalSize = const Size(220, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _openControllerPicker(
      tester,
      buttonRect: const Rect.fromLTWH(160, 300, 44, 36),
    );
    controller.releaseTouch();
    await tester.pumpAndSettle();

    expect(controller.rows, greaterThan(1));
    expect(controller.pickerRect.left, greaterThanOrEqualTo(16));
    expect(controller.pickerRect.right, lessThanOrEqualTo(204));
    for (final id in _reactionIds) {
      expect(_reactionImage(id).hitTestable(), findsOneWidget);
    }
  });

  testWidgets('顶部空间不足时向下展开，高亮向远离按钮的一侧浮起', (tester) async {
    final controller = await _openControllerPicker(
      tester,
      buttonRect: const Rect.fromLTWH(600, 20, 44, 36),
    );
    expect(controller.isAbove, isFalse);
    expect(
      controller.pickerRect.top,
      greaterThan(controller.buttonRect.bottom),
    );

    final slot = controller.itemRects.first;
    controller.updateHighlight(slot.center);
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(_reactionImage('heart')).dy,
      greaterThan(slot.center.dy),
    );
  });

  testWidgets('访客和自己的帖子移除时不会临时创建动画控制器', (tester) async {
    final harness = _ActionBarHarness();
    addTearDown(harness.dispose);
    for (final isGuest in [true, false]) {
      await tester.pumpWidget(
        harness.build(isGuest: isGuest, isOwnPost: !isGuest),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    }
  });
}
