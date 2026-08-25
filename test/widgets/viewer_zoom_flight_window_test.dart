import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/utils/hero_visibility_controller.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';

/// 放大后返回,飞行过程中取景框必须张回完整图。
///
/// **症状**:放大图片后返回,飞行全程画面都是放大态那个局部视图,**落地才
/// 突然变完整图**。
///
/// **成因**(源码 + 算术实证):飞行体 `_CoverContainPainter` 原先只拿
/// image/animation/radius/circular,对放大态零感知;而 `exitFlightRect` 只喂
/// Hero 的**盒子**。于是 painter 把完整图 contain 铺满每一帧的盒子 ——
/// 放大态的盒子远超屏幕,完整图被撑到同样大,用户只看到中间一块:
/// ```
///   放大 3x(1212x758 屏 / 500x500 图 / contain 基线 758):
///   t=1.00  盒子 2274px  屏幕只露 53%   ← 起飞就在裁切
///   t=0.50  盒子 1327px         露 91%
///   t=0.25  盒子  854px         露 100%  ← "落地才变完整"
/// ```
/// contain 源(轮播/正文)更糟:`t` 被钉在 kAlwaysCompleteAnimation,窗口
/// 永不张开。cover 源(网格/头像)不受影响,因为 coverSrc 由画布**比例**算,
/// 与盒子绝对尺寸无关。
///
/// **修法**:查看器发布 `exitVisibleFraction`(此刻看得见的那部分图,全图
/// 归一化),painter 以它作 src 起点插值回全图;且放大态不再钉住 `t`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => HeroVisibilityController.instance.clear());

  group('可见窗口归一化算式', () {
    // 真机同参
    const viewport = Size(1212, 758);

    test('未放大(画面完全在视口内):返回 null,不插值', () {
      // contain 基线 758x758 居中,完全落在 1212x758 视口内
      const baseline = Rect.fromLTRB(227, 0, 985, 758);
      expect(
        ImageViewerPage.visibleFractionOf(baseline, viewport),
        isNull,
        reason: '没被裁切 ⇒ 可见即完整图,飞行体应走原有口径',
      );
    });

    test('放大 3x 居中:窗口≈中间那块,比例与溢出量吻合', () {
      // 758 基线放大 3x = 2274,居中于 1212x758 视口
      final zoomed = Rect.fromCenter(
        center: const Offset(606, 379),
        width: 2274,
        height: 2274,
      );
      final f = ImageViewerPage.visibleFractionOf(zoomed, viewport)!;

      // 横向:视口 1212 / 画面 2274 = 0.533
      expect(f.width, closeTo(1212 / 2274, 0.01),
          reason: '横向可见比例应等于 视口宽/画面宽');
      // 纵向:视口 758 / 画面 2274 = 0.333
      expect(f.height, closeTo(758 / 2274, 0.01));
      // 居中 ⇒ 窗口也居中于 0.5
      expect(f.center.dx, closeTo(0.5, 0.01));
      expect(f.center.dy, closeTo(0.5, 0.01));
      // 必须落在 0~1 内(归一化坐标)
      expect(f.left, greaterThanOrEqualTo(0));
      expect(f.right, lessThanOrEqualTo(1));
    });

    test('放大且平移到左上:窗口偏向左上', () {
      // 画面原点为负(向左上平移过)
      const zoomed = Rect.fromLTRB(-1000, -1400, 1274, 874);
      final f = ImageViewerPage.visibleFractionOf(zoomed, viewport)!;
      expect(f.left, greaterThan(0.3),
          reason: '画面左边被移出屏幕 ⇒ 可见窗口从图的中后段开始');
      expect(f.top, greaterThan(0.5));
    });

    test('画面完全在视口外:返回 null(交集为空)', () {
      const offscreen = Rect.fromLTRB(3000, 3000, 3500, 3500);
      expect(ImageViewerPage.visibleFractionOf(offscreen, viewport), isNull);
    });

    test('空矩形 / 非有限:返回 null', () {
      expect(ImageViewerPage.visibleFractionOf(Rect.zero, viewport), isNull);
      expect(
        ImageViewerPage.visibleFractionOf(
          const Rect.fromLTRB(
            double.nan,
            double.nan,
            double.nan,
            double.nan,
          ),
          viewport,
        ),
        isNull,
      );
      expect(
        ImageViewerPage.visibleFractionOf(
          const Rect.fromLTRB(0, 0, double.infinity, double.infinity),
          viewport,
        ),
        isNull,
      );
    });
  });

  group('飞行体 src 窗口', () {
    const img = ui.Size(500, 500);

    /// 挂飞行体并返回它实际绘制的 src 矩形(通过 painter 暴露的钩子读)
    Future<Rect> srcAt(
      WidgetTester tester, {
      required double t,
      required Rect? zoomFraction,
      Size box = const Size(400, 400),
      bool coverSource = true,
    }) async {
      HeroVisibilityController.instance.setExitVisibleFraction(zoomFraction);
      final ctrl = AnimationController(
        duration: const Duration(milliseconds: 300),
        vsync: tester,
      );
      addTearDown(ctrl.dispose);
      ctrl.value = t;

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: box.width,
              height: box.height,
              child: CoverContainFlightImage(
                image: _Solid(img),
                animation: ctrl,
                coverSource: coverSource,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      return CoverContainFlightImage.debugLastSrc!;
    }

    // t 语义:0=贴源(缩略图), 1=在查看器。pop 时 t 从 1 走到 0。
    // 放大态下查看器端(t=1)是那个放大的局部窗口,贴源端(t=0)是完整缩略图。

    testWidgets('放大态 t=1(在查看器):src = 可见窗口,不是全图', (tester) async {
      // 只看到中间 50% 宽 / 33% 高
      const frac = Rect.fromLTRB(0.25, 0.335, 0.75, 0.665);
      final src = await srcAt(tester, t: 1.0, zoomFraction: frac);
      expect(src.width, closeTo(500 * 0.5, 2),
          reason: '查看器端应是可见窗口(全图的一半宽),不是全图');
      expect(src.height, closeTo(500 * 0.33, 4));
    });

    testWidgets('contain 源 + 放大态 t=0(贴源):src = 全图', (tester) async {
      const frac = Rect.fromLTRB(0.25, 0.335, 0.75, 0.665);
      final src = await srcAt(
        tester,
        t: 0.0,
        zoomFraction: frac,
        coverSource: false, // 轮播/正文:源端 contain 展示
      );
      expect(src.width, closeTo(500, 1), reason: 'contain 源落地端是完整图');
      expect(src.height, closeTo(500, 1));
    });

    testWidgets('cover 源 + 放大态 t=0(贴源):src = 裁切窗口,不是全图', (
      tester,
    ) async {
      // 这条守的是真机报的:聊天气泡本就纵向裁切(clamp 夹高 ⇒ cover 只显示
      // 中段),若贴源端算成完整图,落地瞬间画面会从「裁切一条」突变为完整
      // 长图。两端必须都与真实所见一致。
      const frac = Rect.fromLTRB(0.25, 0.335, 0.75, 0.665);
      // 画布 240x320(气泡形态)、图 500x500 ⇒ cover 纵向要裁
      final src = await srcAt(
        tester,
        t: 0.0,
        zoomFraction: frac,
        box: const Size(240, 320),
        coverSource: true,
      );
      // cover: scale=max(240/500, 320/500)=0.64 ⇒ src=375x500(横向被裁)
      expect(
        src.width,
        lessThan(500),
        reason: 'cover 源贴源端必须是裁切窗口 —— 算成完整图会让落地瞬间突变',
      );
      expect(src.width, closeTo(240 / 0.64, 2));
      expect(src.height, closeTo(500, 2), reason: '纵向已铺满,不该再裁');
    });

    testWidgets('cover 源纵向裁切(气泡夹高形态):贴源端窗口纵向收窄', (
      tester,
    ) async {
      // 竖长图放进被夹高的气泡:cover 会裁掉上下
      // 画布 240x320、图 500x1000 ⇒ scale=max(0.48, 0.32)=0.48
      //   ⇒ src = 500 x 666(纵向从 1000 裁到 666,即 67%)
      HeroVisibilityController.instance.setExitVisibleFraction(null);
      final ctrl = AnimationController(
        duration: const Duration(milliseconds: 300),
        vsync: tester,
      );
      addTearDown(ctrl.dispose);
      ctrl.value = 0.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 240,
              height: 320,
              child: CoverContainFlightImage(
                image: _Solid(const ui.Size(500, 1000)),
                animation: ctrl,
                coverSource: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final src = CoverContainFlightImage.debugLastSrc!;
      expect(src.width, closeTo(500, 2), reason: '横向铺满');
      expect(src.height, closeTo(320 / 0.48, 4),
          reason: '纵向应收窄到约 67%,与气泡里 cover 的实际可见区域一致');
      expect(src.height, lessThan(1000));
    });

    testWidgets('放大态整段退场:src 单调张开到全图', (tester) async {
      const frac = Rect.fromLTRB(0.25, 0.335, 0.75, 0.665);
      // pop:t 从 1 → 0,取景框应单调张大
      double prev = 0;
      for (final t in [1.0, 0.75, 0.5, 0.25, 0.0]) {
        final src = await srcAt(tester, t: t, zoomFraction: frac);
        expect(src.width, greaterThanOrEqualTo(prev - 0.01),
            reason: 't=$t 处窗口反而收窄了,取景框没在张开');
        prev = src.width;
      }
      expect(prev, closeTo(500, 1), reason: '落地必须是完整图');
    });

    testWidgets('未放大(fraction=null):维持 cover 口径不回归', (tester) async {
      // 方形画布 + 方形图 ⇒ coverSrc 就是全图
      final src = await srcAt(tester, t: 0.0, zoomFraction: null);
      expect(src.width, closeTo(500, 1));

      // 非方形画布 ⇒ coverSrc 按画布比例裁窗口(这是 cover 源的既有行为)
      final wide = await srcAt(
        tester,
        t: 0.0,
        zoomFraction: null,
        box: const Size(400, 200),
      );
      expect(wide.height, lessThan(500),
          reason: 'cover 口径:宽画布下 src 高度被裁,这是既有行为,不该丢');
    });
  });

  group('飞行体进度判据(放大态不得钉住 t)', () {
    // 产品代码与本组读同一个实现(ImageViewerPage.debugFlightNeedsProgress),
    // 不复刻判据 —— 复刻等于自洽装置。
    test('contain 源 + 未放大:钉在 1(两端都是完整图,不必插值)', () {
      expect(
        ImageViewerPage.debugFlightNeedsProgress(
          coverSource: false,
          zoomed: false,
        ),
        isFalse,
      );
    });

    test('contain 源 + 放大:必须用真实进度', () {
      expect(
        ImageViewerPage.debugFlightNeedsProgress(
          coverSource: false,
          zoomed: true,
        ),
        isTrue,
        reason: '钉在 1 ⇒ 取景框永不张开 ⇒ 飞行全程停在局部视图(真机症状);'
            'contain 源一直走的就是这条分支,所以轮播/正文最明显',
      );
    });

    test('cover 源:一直用真实进度(既有行为,不得回归)', () {
      expect(
        ImageViewerPage.debugFlightNeedsProgress(
          coverSource: true,
          zoomed: false,
        ),
        isTrue,
      );
      expect(
        ImageViewerPage.debugFlightNeedsProgress(
          coverSource: true,
          zoomed: true,
        ),
        isTrue,
      );
    });
  });
}

class _Solid extends ImageProvider<_Solid> {
  _Solid(this.size);
  final ui.Size size;
  @override
  Future<_Solid> obtainKey(ImageConfiguration configuration) async => this;
  @override
  ImageStreamCompleter loadImage(_Solid key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_frame());
  Future<ImageInfo> _frame() async {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF3366FF),
    );
    final image = await rec.endRecording().toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    return ImageInfo(image: image);
  }

  @override
  bool operator ==(Object other) => other is _Solid && other.size == size;
  @override
  int get hashCode => size.hashCode;

}
