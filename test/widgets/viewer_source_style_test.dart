import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/common/hero_image.dart';

/// [ViewerSourceStyle] 是「源端展示方式」的单一真相:一次给出,同时产出
/// Hero 飞行体参数与 `openViewer` 的 `heroSource*` 参数。
///
/// 为什么需要它:这套契约原先分散在**源端 widget** 与 **openViewer 调用**
/// 两处,还要求两边手工对齐。真机因此先后暴露过:
///  * 轮播漏 createRectTween(放大后返回大图瞬间变小)
///  * 聊天漏 heroSourceFit(飞行体不走裁切插值)
///  * 用户头像源端圆角 12 而 openViewer 传 8(两处不同步)
///
/// 本文件锁住「同源」这件事:同一个 style 产出的两侧参数必须自洽。
void main() {
  group('cover 源(网格瓦片/聊天气泡/方形头像)', () {
    const style = ViewerSourceStyle.cover(radius: 10);

    test('源端展示参数', () {
      expect(style.fit, BoxFit.cover, reason: '源端 Image 应按此 fit 展示');
      expect(style.radius, 10);
      expect(style.isCover, isTrue);
      expect(style.isCircular, isFalse);
    });

    test('openViewer 参数与源端同源', () {
      final args = style.openViewerArgs;
      expect(args.fit, BoxFit.cover, reason: 'cover 源必须告知查看器');
      expect(
        args.radius,
        style.radius,
        reason: '两侧圆角必须相等 —— 头像那处曾源端 12 / 查看器 8',
      );
      expect(args.circular, isFalse);
    });
  });

  group('contain 源(轮播/正文单图)', () {
    const style = ViewerSourceStyle.contain();

    test('源端展示参数', () {
      expect(style.fit, BoxFit.contain);
      expect(style.isCover, isFalse);
      expect(style.isCircular, isFalse);
    });

    test('openViewer 不传 heroSourceFit(留 null)', () {
      expect(
        style.openViewerArgs.fit,
        isNull,
        reason: 'contain 源两端本就都是完整图,传了会让飞行体做多余的窗口插值',
      );
    });

    test('带圆角的 contain 源:圆角仍要同步', () {
      const rounded = ViewerSourceStyle.contain(radius: 8);
      expect(rounded.openViewerArgs.radius, 8);
      expect(rounded.openViewerArgs.fit, isNull, reason: '仍是 contain');
    });
  });

  group('圆形源(圆形头像)', () {
    const style = ViewerSourceStyle.circular();

    test('圆形视为 cover 裁切(飞行体要做窗口插值)', () {
      expect(style.isCircular, isTrue);
      expect(style.isCover, isTrue, reason: '圆形必然是裁切展示');
      expect(style.fit, BoxFit.cover);
    });

    test('openViewer 参数带 circular', () {
      final args = style.openViewerArgs;
      expect(args.circular, isTrue);
      expect(args.fit, BoxFit.cover);
      expect(args.radius, 0, reason: '圆形由 circular 表达,不用 radius');
    });
  });

  group('HeroImage 从 style 派生飞行参数', () {
    test('给了 style:effective* 以它为准', () {
      const w = HeroImage(
        heroTag: 't',
        style: ViewerSourceStyle.cover(radius: 4),
        child: SizedBox(),
      );
      expect(w.effectiveCover, isTrue);
      expect(w.effectiveRadius, 4);
      expect(w.effectiveCircular, isFalse);
    });

    test('圆形 style', () {
      const w = HeroImage(
        heroTag: 't',
        style: ViewerSourceStyle.circular(),
        child: SizedBox(),
      );
      expect(w.effectiveCover, isTrue);
      expect(w.effectiveCircular, isTrue);
    });

    test('contain style:不走裁切飞行体', () {
      const w = HeroImage(
        heroTag: 't',
        style: ViewerSourceStyle.contain(),
        child: SizedBox(),
      );
      expect(w.effectiveCover, isFalse);
    });

    test('未给 style:回落到旧的散参(兼容既有调用点)', () {
      const w = HeroImage(
        heroTag: 't',
        coverFlight: true,
        flightRadius: 6,
        child: SizedBox(),
      );
      expect(w.effectiveCover, isTrue);
      expect(w.effectiveRadius, 6);
    });
  });

  group('aspectRatio:让 Hero 盒子 ≡ 画面', () {
    testWidgets('给了比例:盒子按比例收拢,不铺满外层', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: HeroImage(
                heroTag: 'a',
                aspectRatio: 0.75, // 3:4 竖图
                style: ViewerSourceStyle.contain(),
                child: SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      final box = tester.getRect(find.byType(Hero));
      // 0.75 比例进 400x300 ⇒ 受高度约束 → 225x300
      expect(box.width, closeTo(225, 1),
          reason: 'Hero 盒子应按比例收到画面宽,否则尾帧铺满外层盒子');
      expect(box.height, closeTo(300, 1));
    });

    testWidgets('未给比例:盒子就是 child 的尺寸(旧行为)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: HeroImage(
                heroTag: 'b',
                style: ViewerSourceStyle.cover(radius: 0),
                child: SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      final box = tester.getRect(find.byType(Hero));
      expect(box.width, closeTo(400, 1));
      expect(box.height, closeTo(300, 1));
    });
  });

  test('相等性与可读性(便于在 widget 树里 diff)', () {
    expect(
      const ViewerSourceStyle.cover(radius: 4),
      const ViewerSourceStyle.cover(radius: 4),
    );
    expect(
      const ViewerSourceStyle.cover(radius: 4),
      isNot(const ViewerSourceStyle.cover(radius: 8)),
    );
    expect(
      const ViewerSourceStyle.contain(),
      isNot(const ViewerSourceStyle.cover(radius: 0)),
    );
    expect(
      const ViewerSourceStyle.circular().toString(),
      contains('circular'),
    );
  });
}
