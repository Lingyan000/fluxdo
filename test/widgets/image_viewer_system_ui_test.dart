import 'dart:convert';
import 'dart:io';

import 'package:app_icons/app_icons.dart';
import 'package:extended_image_lite/extended_image_lite.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';
import 'package:fluxdo/widgets/layout/immersive_insets_hold.dart';

void main() {
  final imageBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
  );
  late GlobalKey<NavigatorState> navigator;
  late List<MethodCall> systemUiCalls;

  Future<void> openViewer(
    WidgetTester tester, {
    Future<void> Function(BuildContext)? open,
    Widget? homeBody,
  }) async {
    PlatformUtils.debugDesktopOverride = false;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
    addTearDown(tester.view.reset);

    systemUiCalls = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode' ||
            call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
          systemUiCalls.add(call);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    navigator = GlobalKey<NavigatorState>();
    late BuildContext homeContext;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => ImmersiveInsetsHoldScope(child: child!),
          home: Builder(
            builder: (context) {
              homeContext = context;
              return Scaffold(body: homeBody);
            },
          ),
        ),
      ),
    );
    if (open == null) {
      ImageViewerPage.openBytes(homeContext, imageBytes);
    } else {
      await open(homeContext);
    }
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsOneWidget);
    expect(systemUiCalls, isEmpty);
  }

  double controlsOpacity(WidgetTester tester, Finder control) {
    var opacity = 1.0;
    tester.element(control).visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is ExtendedImageSlidePage) return false;
      if (widget is Opacity) opacity *= widget.opacity;
      if (widget is FadeTransition) opacity *= widget.opacity.value;
      return true;
    });
    return opacity;
  }

  Future<void> toggleControls(
    WidgetTester tester, {
    Offset at = const Offset(200, 400),
  }) async {
    await tester.tapAt(at);
    // 等待图片手势层区分单击与双击。
    await tester.pumpAndSettle(const Duration(milliseconds: 350));
  }

  void expectSingleRestore() {
    expect(systemUiCalls.map((call) => [call.method, call.arguments]), [
      ['SystemChrome.setEnabledSystemUIMode', 'SystemUiMode.immersiveSticky'],
      [
        'SystemChrome.setEnabledSystemUIOverlays',
        ['SystemUiOverlay.top', 'SystemUiOverlay.bottom'],
      ],
      ['SystemChrome.setEnabledSystemUIMode', 'SystemUiMode.edgeToEdge'],
    ]);
  }

  testWidgets('普通查看后点关闭，不重新切换系统栏模式', (tester) async {
    await openViewer(tester);
    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsNothing);
    expect(systemUiCalls, isEmpty, reason: '未隐藏过系统栏，退场不能触发安全区变化');
  });

  testWidgets('从顶部渐变的空白处点按也能收起工具栏', (tester) async {
    await openViewer(tester);
    await toggleControls(tester, at: const Offset(200, 75));
    expect(systemUiCalls.map((call) => call.arguments), [
      'SystemUiMode.immersiveSticky',
    ]);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expectSingleRestore();
  });

  testWidgets('取消拖动从松手位置回弹，中途再拖可以接住图片', (tester) async {
    await openViewer(tester);
    final slide = tester.state<ExtendedImageSlidePageState>(
      find.byType(ExtendedImageSlidePage),
    );
    final image = tester.widget<GestureImageView>(
      find.byType(GestureImageView),
    );
    final controller = image.controller;
    final close = find.byIcon(Symbols.close_rounded);
    const drag = Offset(0, 75);
    slide.slide(drag, controller: controller);
    await tester.pump();
    final releaseScale = controller.slideScale;
    expect(releaseScale, lessThan(1));
    expect(controlsOpacity(tester, close), closeTo(1 - drag.dy / 800, 0.001));

    slide.endSlide(ScaleEndDetails());
    expect(controller.slideOffset, drag, reason: '回弹启动时图片应停在松手位置');
    expect(controller.slideScale, releaseScale);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final halfway = controller.slideOffset;
    expect(halfway.dy, inExclusiveRange(0, drag.dy));
    expect(
      controlsOpacity(tester, close),
      closeTo(1 - halfway.dy / 800, 0.001),
    );

    const more = Offset(0, 10);
    slide.slide(more, controller: controller);
    expect(controller.slideOffset, halfway + more);
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.slideOffset, halfway + more);
    slide.endSlide(ScaleEndDetails());
    await tester.pumpAndSettle();
    expect(controller.slideOffset, Offset.zero);
    expect(controller.slideScale, 1);
    expect(controlsOpacity(tester, close), 1);
    expect(slide.isSliding, isFalse);
    expect(systemUiCalls, isEmpty);
  });

  testWidgets('从顶部渐变处下滑可以直接关闭图片', (tester) async {
    await openViewer(tester);
    await tester.flingFrom(const Offset(200, 75), const Offset(0, 320), 1200);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expect(systemUiCalls, isEmpty);
  });

  testWidgets('画廊页码和文件名可穿透点按，拖动时与按钮一起淡出', (tester) async {
    const urls = [
      'https://example.test/first.png',
      'https://example.test/second.png',
    ];
    const filename = 'first.png';
    await openViewer(
      tester,
      homeBody: const Center(
        child: HeroImage(
          heroTag: 'first',
          child: SizedBox.square(dimension: 64),
        ),
      ),
      open: (context) async {
        // 两张图走真实查看器和画廊翻页路径，原图与相邻预取只读本地测试缓存。
        final root = (await tester.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp('fluxdo-viewer-');
          await BlobImageCache.configureForTesting(root: dir);
          for (final url in urls) {
            await BlobImageCache.write(
              BlobImageCache.originalBucket,
              url,
              imageBytes,
            );
            // 先解码测试视口（长边 800）的查看器原图，帧推进只受测试时钟控制。
            if (context.mounted) {
              await precacheImage(
                ResizeImage(
                  discourseImageProvider(
                    url,
                    bucket: BlobImageCache.originalBucket,
                  ),
                  width: 2400,
                  height: 2400,
                  policy: ResizeImagePolicy.fit,
                ),
                context,
              );
            }
          }
          return dir;
        }))!;
        addTearDown(() async {
          await BlobImageCache.configureForTesting();
          await root.delete(recursive: true);
        });
        if (!context.mounted) return;
        ImageViewerPage.open(
          context,
          urls.first,
          heroTag: 'first',
          galleryImages: urls,
          filenames: const [filename, 'second.png'],
          enableShare: true,
        );
      },
    );

    final counter = find.text('1 / 2');
    final caption = find.text(filename);
    final close = find.byIcon(Symbols.close_rounded);
    final save = find.byIcon(Symbols.save_alt_rounded);
    final slide = tester.state<ExtendedImageSlidePageState>(
      find.byType(ExtendedImageSlidePage),
    );
    final image = tester
        .widgetList<GestureImageView>(find.byType(GestureImageView))
        .first;
    slide.slide(const Offset(0, 80), controller: image.controller);
    await tester.pump();
    for (final control in [counter, caption, close, save]) {
      expect(controlsOpacity(tester, control), closeTo(0.8, 0.001));
    }
    slide.endSlide(ScaleEndDetails());
    await tester.pumpAndSettle();
    await toggleControls(tester, at: tester.getCenter(counter));
    expect(controlsOpacity(tester, close), 0);
    slide.slide(const Offset(0, 60), controller: image.controller);
    slide.endSlide(ScaleEndDetails());
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester, close), 0);
    await toggleControls(tester);
    await toggleControls(tester, at: tester.getCenter(caption));
    expect(controlsOpacity(tester, close), 0);
    expect(systemUiCalls.last.arguments, 'SystemUiMode.immersiveSticky');
    await toggleControls(tester);
    // 只有首图有配对缩略图。翻到普通页再翻回，工具栏始终只有一份且仍可操作。
    await tester.flingFrom(const Offset(320, 400), const Offset(-280, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.text('second.png'), findsOneWidget);
    expect(close, findsOneWidget);
    await tester.flingFrom(const Offset(80, 400), const Offset(280, 0), 1000);
    await tester.pumpAndSettle();
    expect(counter, findsOneWidget);
    expect(close, findsOneWidget);
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
  });

  testWidgets('横屏工具栏避开两侧安全区，关闭按钮边缘可以点按', (tester) async {
    await openViewer(tester);
    tester.view.physicalSize = const Size(800, 400);
    tester.view.padding = const FakeViewPadding(left: 52, right: 40);
    tester.view.viewPadding = const FakeViewPadding(left: 52, right: 40);
    await tester.pumpAndSettle();
    final close = find.widgetWithIcon(IconButton, Symbols.close_rounded);
    final save = find.widgetWithIcon(IconButton, Symbols.save_alt_rounded);
    final closeRect = tester.getRect(close);
    expect(closeRect.width, greaterThanOrEqualTo(48));
    expect(closeRect.height, greaterThanOrEqualTo(48));
    expect(closeRect.right, lessThanOrEqualTo(800 - 40));
    expect(tester.getRect(save).left, greaterThanOrEqualTo(52));
    await tester.tapAt(Offset(closeRect.left + 1, closeRect.center.dy));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
  });

  testWidgets('普通查看后返回，不重新切换系统栏模式', (tester) async {
    await openViewer(tester);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    expect(find.byType(ImageViewerPage), findsNothing);
    expect(systemUiCalls, isEmpty);
  });

  testWidgets('沉浸状态退出在退场起点恢复，销毁时不重复恢复', (tester) async {
    await openViewer(tester);
    await toggleControls(tester);
    expect(systemUiCalls.single.arguments, 'SystemUiMode.immersiveSticky');

    navigator.currentState!.pop();
    await tester.pump();
    expect(find.byType(ImageViewerPage), findsOneWidget);
    expectSingleRestore();

    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expectSingleRestore();
  });

  testWidgets('手动显示系统栏后关闭，不再次恢复', (tester) async {
    await openViewer(tester);
    await toggleControls(tester);
    await toggleControls(tester);
    expectSingleRestore();

    await tester.tap(find.byIcon(Symbols.close_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsNothing);
    expectSingleRestore();
  });
}
