import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/hero_visibility_controller.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';

/// cover 源(聊天气泡)返回「两端完整、中间帧被裁」的回归防线。
///
/// **成因**:飞行体的贴源端裁窗原先按**飞行途中逐帧变化的画布比例**算。
/// 气泡盒子恰好等于图片比例(`h = w/ratio` 未撞 clamp)时,气泡里显示的
/// 本是完整图 —— 但飞行盒子从查看器(屏幕比例)连续变到气泡(图片比例),
/// 中途比例既不是源端也不是查看器,cover 裁窗就把本不该裁的裁掉了:
/// 两端(盒子≈源端 / t 权重归零)完整、唯独中间帧被裁。contain 源(正文)
/// 贴源端恒取全图,故不受影响 —— 这正是「帖子内容图片正常」的原因。
///
/// **修法**:裁窗按 [CoverContainFlightImage.sourceAspect](源端盒子的**固定**
/// 宽高比)算,不取动态画布比例。源端比例==图片比例时,裁窗恒等于全图,
/// 全程不裁。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const img = ui.Size(240, 320); // 图片:aspect 0.75
  const imgRect = Rect.fromLTWH(0, 0, 240, 320);

  setUp(() =>
      HeroVisibilityController.instance.setExitVisibleFraction(null));
  tearDown(() {
    HeroVisibilityController.instance.setExitVisibleFraction(null);
    CoverContainFlightImage.debugLastSrc = null;
  });

  /// 在 [box] 里以 [t] 挂 cover 飞行体,返回实际绘制的 src 窗口(全图像素)。
  Future<Rect> srcAt(
    WidgetTester tester, {
    required Size box,
    required double t,
    required double? sourceAspect,
  }) async {
    final ctrl = AnimationController(vsync: tester);
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
              coverSource: true,
              sourceAspect: sourceAspect,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    return CoverContainFlightImage.debugLastSrc!;
  }

  testWidgets('源端比例==图片比例:全程取全图,任何飞行盒子下都不裁', (
    tester,
  ) async {
    // 气泡未撞 clamp 的场景:sourceAspect = 图片比例 0.75。
    // 途中喂几个**失配**的飞行盒子(屏幕比例、方形…),src 必须恒为全图。
    for (final box in const [
      Size(400, 700), // 近查看器(屏幕比例,与图片失配)
      Size(360, 480),
      Size(240, 320), // 落点(==源端)
      Size(500, 300), // 极端失配:扁盒子
    ]) {
      for (final t in const [0.0, 0.25, 0.5, 0.75, 1.0]) {
        final src = await srcAt(
          tester,
          box: box,
          t: t,
          sourceAspect: 0.75,
        );
        expect(
          src,
          imgRect,
          reason: 'box=$box t=$t 下 src 被裁($src),应恒为全图 $imgRect',
        );
      }
    }
  });

  testWidgets('源端比例≠图片比例(气泡撞 clamp):贴源端确按源端比例裁,不受飞行盒子影响', (
    tester,
  ) async {
    // 图片很高(0.5),气泡撞 clamp 后盒子 0.75 → 贴源端应纵向裁:满宽、裁高。
    const tall = ui.Size(300, 600); // aspect 0.5
    final ctrl = AnimationController(vsync: tester);
    addTearDown(ctrl.dispose);
    ctrl.value = 0.0; // 贴源端

    Future<Rect> paintIn(Size box) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: box.width,
              height: box.height,
              child: CoverContainFlightImage(
                image: _Solid(tall),
                animation: ctrl,
                coverSource: true,
                sourceAspect: 0.75, // 源端气泡固定比例
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      return CoverContainFlightImage.debugLastSrc!;
    }

    // 无论飞行盒子当前是什么比例,贴源端(t=0)裁窗都由 sourceAspect 决定:
    // winW=imgW=300, winH=imgW/0.75=400,居中。
    const expected = Rect.fromLTWH(0, 100, 300, 400);
    for (final box in const [Size(300, 400), Size(400, 500), Size(500, 300)]) {
      final src = await paintIn(box);
      expect(src.left, closeTo(expected.left, 0.5), reason: 'box=$box');
      expect(src.top, closeTo(expected.top, 0.5), reason: 'box=$box');
      expect(src.width, closeTo(expected.width, 0.5), reason: 'box=$box');
      expect(src.height, closeTo(expected.height, 0.5), reason: 'box=$box');
    }
  });

  test('反向验证锚:旧算式(按画布比例裁)在失配盒子下必产裁窗', () {
    // 这条固化「若退回用动态画布比例,中间帧就会被裁」的算术,守住修法方向。
    // 画布 400x700(屏幕比例)、图 240x320:cover 裁窗 = 满高、裁宽。
    const size = Size(400, 700);
    const imgW = 240.0, imgH = 320.0;
    final coverScale =
        (size.width / imgW) > (size.height / imgH)
            ? size.width / imgW
            : size.height / imgH;
    final winW = size.width / coverScale;
    final winH = size.height / coverScale;
    // 结论:旧算式在此盒子下 winW < imgW(被裁),故中间帧不完整。
    expect(winW, lessThan(imgW - 1));
    expect(winH, closeTo(imgH, 0.5));
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
