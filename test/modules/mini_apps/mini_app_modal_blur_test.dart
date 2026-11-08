import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_modal_blur.dart';

Future<ui.Image> _frame(WidgetTester tester) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xff226633), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await tester.runAsync(() => picture.toImage(16, 24));
  picture.dispose();
  return image!;
}

void main() {
  testWidgets('迟到截图与退出末帧不会把过时的清晰画面盖回网页', (tester) async {
    tester.view.physicalSize = const Size(120, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final blur = MiniAppModalBlur();
    final gate = Completer<ui.Image?>();
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 网页继续运行，当前画面与刚取得的截图不同。
              const ColoredBox(color: Color(0xff0000ff)),
              MiniAppModalFrame(blur: blur),
            ],
          ),
        ),
      ),
    );
    Future<List<int>> pixel() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final data = (await image.toByteData())!;
          return [
            for (var c = 0; c < 4; c++) data.getUint8((60 * 120 + 60) * 4 + c),
          ];
        } finally {
          image.dispose();
        }
      }))!;
    }

    final menu = blur.acquire(() => gate.future);
    menu.onBlurSigmaChanged(18);
    await tester.pump(const Duration(milliseconds: 300));
    gate.complete(await _frame(tester));
    await tester.pump();
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    expect(await pixel(), [0, 0, 255, 255], reason: '首帧不能突兀切换到旧截图');
    await tester.pump(const Duration(milliseconds: 60));
    final middle = await pixel();
    expect(middle[1], inExclusiveRange(0, 102), reason: '准备好的模糊画面渐入');
    await tester.pump(const Duration(milliseconds: 100));
    expect((await pixel())[1], 102);

    menu.onBlurSigmaChanged(1);
    await tester.pump();
    expect((await pixel())[2], greaterThan(150), reason: '退场末尾渐回实时画面');
    // 有效租约仍在，但路由拖回起点时截图不应再可见。
    menu.onBlurSigmaChanged(0);
    await tester.pump();
    expect(await pixel(), [0, 0, 255, 255]);
    menu.finish();
    await tester.pumpWidget(const SizedBox.shrink());
    blur.dispose();
  });

  testWidgets('工具栏和网页画面跨边界共同取样，无分段滤镜硬边', (tester) async {
    tester.view.physicalSize = const Size(120, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final blur = MiniAppModalBlur();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const Color(0xff226633), ui.BlendMode.src);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 120, 80),
      ui.Paint()..color = const Color(0xffff0000),
    );
    final picture = recorder.endRecording();
    final image = (await tester.runAsync(() => picture.toImage(120, 200)))!;
    picture.dispose();
    final frame = blur.acquire(() async => image);
    frame.onBlurSigmaChanged(18);
    await tester.pump();
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(
          key: key,
          child: MiniAppModalFrame(blur: blur),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(BackdropFilter),
      findsNothing,
      reason: '只过滤合成图片，不让原生平台视图参与背景滤镜',
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final pixels = await tester.runAsync(() async {
      final composite = await boundary.toImage();
      final data = await composite.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      composite.dispose();
      return data!;
    });
    int channel(int y, int c) => pixels!.getUint8((y * 120 + 60) * 4 + c);
    expect(channel(79, 1), greaterThan(15), reason: '工具栏采到下方网页绿色');
    expect(channel(80, 0), greaterThan(70), reason: '网页采到上方工具栏红色');
    expect((channel(79, 0) - channel(80, 0)).abs(), lessThan(15));
    frame.finish();
    frame.onBlurSigmaChanged(0);
    await tester.pumpWidget(const SizedBox.shrink());
    blur.dispose();
  });

  testWidgets('弹层关闭后保留画面到退场结束，菜单切换评分共用一帧', (tester) async {
    final image = await _frame(tester);
    final blur = MiniAppModalBlur();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MiniAppModalFrame(blur: blur),
      ),
    );
    final menu = blur.acquire(() async => image);
    menu.onBlurSigmaChanged(18);
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, same(image));
    menu.finish();
    expect(blur.image, same(image));
    final rating = blur.acquire(() => throw StateError('不能二次取帧'));
    rating.onBlurSigmaChanged(18);
    menu.onBlurSigmaChanged(0);
    expect(blur.image, same(image));
    rating.finish();
    rating.onBlurSigmaChanged(9);
    expect(blur.image, same(image));
    rating.onBlurSigmaChanged(0);
    expect(blur.image, isNull);
    await tester.pump();
    expect(find.byType(RawImage), findsNothing);
    expect(image.debugDisposed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    blur.dispose();
  });

  testWidgets('弹层立即取得使用权，慢帧到达后仍启用模糊', (tester) async {
    final image = await _frame(tester);
    final gate = Completer<ui.Image?>();
    final blur = MiniAppModalBlur();
    final readiness = <bool>[];
    blur.addListener(() => readiness.add(blur.value));
    var captures = 0;
    final menu = blur.acquire(() {
      captures++;
      return gate.future;
    });
    menu.onBlurSigmaChanged(18);
    await tester.pump(const Duration(seconds: 1));
    expect(menu.valid, isTrue);
    expect(menu.hasFrame, isFalse);
    final other = blur.acquire(() => throw StateError('等待中不能重复取帧'));
    expect(captures, 1);
    gate.complete(image);
    await tester.pump();
    expect(menu.hasFrame, isTrue);
    expect(other.hasFrame, isTrue);
    expect(readiness, [true]);
    other.finish();
    menu.finish();
    menu.onBlurSigmaChanged(0);
    await tester.pump();
    expect(readiness, [true, false]);
    expect(image.debugDisposed, isTrue);
    blur.dispose();
  });

  testWidgets('取帧期间关闭，迟到结果释放且不能覆盖下一次弹层', (tester) async {
    final stale = await _frame(tester);
    final next = await _frame(tester);
    final gate = Completer<ui.Image?>();
    final blur = MiniAppModalBlur();
    final old = blur.acquire(() => gate.future);
    old.onBlurSigmaChanged(18);
    await tester.pump(const Duration(milliseconds: 500));
    expect(old.hasFrame, isFalse);
    old.finish();
    old.onBlurSigmaChanged(0);
    final fresh = blur.acquire(() async => next);
    gate.complete(stale);
    await tester.pump();
    expect(stale.debugDisposed, isTrue);
    expect(blur.image, same(next));
    fresh.finish();
    await tester.pump();
    expect(next.debugDisposed, isTrue);
    blur.dispose();
  });

  testWidgets('页面销毁中止待取帧，未知/失败截图不留下画面', (tester) async {
    final image = await _frame(tester);
    final gate = Completer<ui.Image?>();
    final blur = MiniAppModalBlur();
    final lease = blur.acquire(() => gate.future);
    blur.dispose();
    gate.complete(image);
    await tester.pump();
    expect(lease.hasFrame, isFalse);
    expect(image.debugDisposed, isTrue);
    final failed = MiniAppModalBlur();
    var attempts = 0;
    final failure = failed.acquire(() {
      attempts++;
      throw StateError('capture unavailable');
    });
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(seconds: 1));
    expect(attempts, greaterThanOrEqualTo(3), reason: '弹层仍在时持续退避重试');
    expect(failure.hasFrame, isFalse);
    failure.finish();
    final stopped = attempts;
    await tester.pump(const Duration(seconds: 3));
    expect(attempts, stopped, reason: '关闭弹层立刻取消重试');
    failed.dispose();
  });

  for (final throws in [false, true]) {
    testWidgets('暂时不可用后重试可恢复模糊：异常=$throws', (tester) async {
      final image = await _frame(tester);
      final blur = MiniAppModalBlur();
      var attempts = 0;
      final lease = blur.acquire(() async {
        if (++attempts == 1) {
          if (throws) throw StateError('视图刚恢复');
          return null;
        }
        return image;
      });
      await tester.pump();
      expect(blur.value, isFalse);
      await tester.pump(const Duration(milliseconds: 80));
      expect(attempts, 2);
      expect(lease.hasFrame, isTrue);
      lease.finish();
      await tester.pump();
      expect(image.debugDisposed, isTrue);
      blur.dispose();
    });
  }

  testWidgets('前两次为空不永久降级，后续有效帧仍能启用模糊', (tester) async {
    final image = await _frame(tester);
    final blur = MiniAppModalBlur();
    var attempts = 0;
    final lease = blur.acquire(() async => ++attempts < 3 ? null : image);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(blur.value, isFalse);
    await tester.pump(const Duration(milliseconds: 160));
    expect(attempts, 3);
    expect(lease.hasFrame, isTrue);
    await tester.pump(const Duration(seconds: 3));
    expect(attempts, 3, reason: '成功后停止取帧，不持续截游戏');
    lease.finish();
    await tester.pump();
    expect(image.debugDisposed, isTrue);
    blur.dispose();
  });

  testWidgets('旋转更新底图不闪回无模糊；新图绘制后才释放旧图', (tester) async {
    final first = await _frame(tester);
    final second = await _frame(tester);
    final blur = MiniAppModalBlur();
    final next = Completer<ui.Image?>();
    var attempts = 0;
    final lease = blur.acquire(
      () async => ++attempts == 1 ? first : next.future,
    );
    await tester.pump();
    blur.refresh();
    await tester.pump(const Duration(milliseconds: 400));
    expect(blur.image, same(first));
    expect(blur.value, isTrue);
    expect(first.debugDisposed, isFalse);
    next.complete(second);
    await tester.pump();
    expect(blur.image, same(second));
    await tester.pump();
    expect(first.debugDisposed, isTrue);
    lease.finish();
    await tester.pump();
    expect(second.debugDisposed, isTrue);
    blur.dispose();
  });
}
