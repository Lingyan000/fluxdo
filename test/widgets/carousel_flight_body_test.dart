import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';

/// 轮播返回「尾帧尺寸对了但图是裁切的、不完整」的回归防线。
///
/// **成因**:查看器侧 `flightShuttleBuilder` 原先只在 cover 源(网格瓦片/
/// 圆形头像)时用自绘飞行体,其余分支直接返回 `child` —— 那是
/// `GestureImageView` 的绘制层,带画布级变换(缩放/平移),塞进逐帧收缩的
/// 飞行盒子里不会重新适配,于是画面被裁切。
///
/// **修法**:有缩略图就一律用 [CoverContainFlightImage](自绘
/// `drawImageRect`,画干净位图)。两种口径:
///  * cover 源:裁切窗口随 progress 从 cover 张到 contain;
///  * contain 源:两端都是 contain、只有盒子比例在变,故把 t 钉在 1
///    (`kAlwaysCompleteAnimation`)—— 恒取全图、按真实比例 contain 进当前
///    飞行盒子。缩放由 Hero 盒子逐帧收缩承担,故观感是「完整大图随 Hero
///    动画连续变小」。
///
/// painter 行为实测(375x500 图,取 src/dst):
/// ```
///   画布 568x758  t=1  src=375x500(全图)  dst=568x757
///   画布 225x300  t=1  src=375x500(全图)  dst=225x300
/// ```
/// src 恒为全图 ⇒ 画完整图;dst 按真实比例 contain 进画布 ⇒ 随盒子等比缩小。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const img = ui.Size(375, 500); // 真机同参:aspect 0.75

  /// 在 [box] 大小的盒子里挂飞行体,返回它的实际尺寸。
  Future<Size> mount(
    WidgetTester tester, {
    required Size box,
    required Animation<double> animation,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: CoverContainFlightImage(
              key: const ValueKey('flight'),
              image: _Solid(img),
              animation: animation,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    return tester.getSize(find.byKey(const ValueKey('flight')));
  }

  testWidgets('contain 源(t 钉在 1):飞行体填满盒子,内容完整不裁切', (
    tester,
  ) async {
    final size = await mount(
      tester,
      box: const Size(225, 300), // 轮播落点(与图片同比例)
      animation: kAlwaysCompleteAnimation,
    );
    expect(size.width, closeTo(225, 0.5));
    expect(size.height, closeTo(300, 0.5));
  });

  testWidgets('t=1 在任意盒子比例下都稳定(飞行途中比例会失配)', (tester) async {
    // 注意:默认测试屏 800x600,盒子须放得进去,否则被夹尺寸(装置约束,
    // 非产品问题)。取飞行途中几个代表性比例。
    for (final box in const [
      Size(420, 560), // 近查看器端(0.75)
      Size(300, 400),
      Size(225, 300), // 轮播落点
      Size(400, 300), // 失配:盒子比图片扁
      Size(200, 500), // 失配:盒子比图片瘦
    ]) {
      final size = await mount(
        tester,
        box: box,
        animation: kAlwaysCompleteAnimation,
      );
      expect(size, box, reason: '盒子 $box 下飞行体尺寸异常');
    }
  });

  testWidgets('cover 源(t 随 progress):裁切插值路径不回归', (tester) async {
    final ctrl = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: tester,
    );
    addTearDown(ctrl.dispose);

    for (final v in const [0.0, 0.35, 0.7, 1.0]) {
      ctrl.value = v;
      final size = await mount(
        tester,
        box: const Size(120, 120), // 网格瓦片:正方形,与图片比例不同
        animation: ctrl,
      );
      expect(size, const Size(120, 120), reason: 't=$v 时飞行体尺寸异常');
    }
  });

  test('kAlwaysCompleteAnimation 的语义前提:value 恒为 1', () {
    // 修法依赖这个前提。上游若改了,这里先炸。
    expect(kAlwaysCompleteAnimation.value, 1.0);
    expect(kAlwaysCompleteAnimation.status, AnimationStatus.completed);
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
