import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';

/// 退场飞行起点(exitFlightRect)的发布判据。
///
/// **症状**:从查看器返回时,大图先跳成另一个尺寸,再从那儿播 Hero 动画 ——
/// 而不是从当前所见连续缩回缩略图。
///
/// **成因**:旧判据是 `totalScale > 1`,以为「>1 就是用户放大过」。但
/// totalScale 的 1.0 不代表"贴合屏幕":双击缩放的智能档位会给小图算出 >1
/// 的比例(`DoubleTapZoomController._calculateSmartScale`:正方形图在
/// 1212x758 屏上得 `scaleToFitWidth = 1212/758 ≈ 1.6`),此后即使视觉上看着
/// 没放大,totalScale 仍停在 1.6。
///
/// **真机实测**(本文件期望值直接取自它):500x500 的图、用户没主动放大,
/// 旧判据却发布了 `(0.1, -191.4, 1211.9, 1020.5)` = 1212x1212 的矩形 ——
/// contain 基线本应是 758x758,且这个矩形上下各溢出屏幕 191px。拿它当飞行
/// 起点,整条路径都歪。
///
/// **修法**:判「可见矩形是否偏离 contain 基线」。基线取
/// `GestureDetails.rawDestinationRect`(extended_image_lite 里缩放前的
/// contain 矩形),两者近似相等即视为未偏离。
void main() {
  // 真机同参:1212x758 屏、500x500 图 ⇒ contain 基线 758x758 居中
  const baseline = Rect.fromLTRB(227, 0, 985, 758);

  test('视觉归位(矩形=contain 基线):不发布 —— 这是新旧判据的分水岭', () {
    // 旧判据只看 totalScale,而双击智能档位会把它留在 1.6,于是这种"看着
    // 没放大"的状态也被当成放大态,发布出溢出屏幕的起点。新判据看矩形本身:
    // 与基线一致就是没偏离,无论 totalScale 是多少。
    expect(
      ImageViewerPage.debugIsDisplacedFromBaseline(baseline, baseline),
      isFalse,
      reason: '矩形等于 contain 基线 = 没偏离,不该发布飞行起点',
    );
  });

  test('真放大(3x 且平移过):必须发布', () {
    const zoomed = Rect.fromLTRB(-400, -600, 1200, 2400);
    expect(
      ImageViewerPage.debugIsDisplacedFromBaseline(zoomed, baseline),
      isTrue,
      reason: '真放大态必须发布,否则「大图→缩略图」又会变成两段动作',
    );
  });

  test('只平移未缩放:也算偏离,必须发布', () {
    // 尺寸与基线相同但位置挪了 —— 起点若用布局盒子会跳位
    final shifted = baseline.shift(const Offset(120, -80));
    expect(
      ImageViewerPage.debugIsDisplacedFromBaseline(shifted, baseline),
      isTrue,
    );
  });

  test('亚像素微差(浮点/像素对齐)不算偏离', () {
    final jitter = Rect.fromLTRB(
      baseline.left + 0.4,
      baseline.top - 0.3,
      baseline.right + 0.2,
      baseline.bottom + 0.5,
    );
    expect(
      ImageViewerPage.debugIsDisplacedFromBaseline(jitter, baseline),
      isFalse,
      reason: '容差内的微差不该触发发布,否则每次返回都走放大态路径',
    );
  });

  test('刚超出容差:算偏离', () {
    final nudged = baseline.shift(const Offset(2, 0));
    expect(
      ImageViewerPage.debugIsDisplacedFromBaseline(nudged, baseline),
      isTrue,
    );
  });

  test('缩放但位置不变(纯放大):必须发布', () {
    // 与真机那个 1212x1212 同构:居中放大,左右上下都溢出
    final scaled = Rect.fromCenter(
      center: baseline.center,
      width: baseline.width * 1.6,
      height: baseline.height * 1.6,
    );
    expect(
      ImageViewerPage.debugIsDisplacedFromBaseline(scaled, baseline),
      isTrue,
    );
  });

  group('缺数据时保守退回(不发布,走框架默认几何)', () {
    test('矩形为 null', () {
      expect(
        ImageViewerPage.debugIsDisplacedFromBaseline(null, baseline),
        isFalse,
      );
    });

    test('基线为 null —— 拿不到基线就无从判断,不该乱发布', () {
      expect(
        ImageViewerPage.debugIsDisplacedFromBaseline(
          const Rect.fromLTRB(0, 0, 1212, 1212),
          null,
        ),
        isFalse,
        reason: '旧实现在这种情况下会发布,等于把未知当成放大态',
      );
    });

    test('空矩形', () {
      expect(
        ImageViewerPage.debugIsDisplacedFromBaseline(Rect.zero, baseline),
        isFalse,
      );
    });

    test('非有限矩形', () {
      const nan =
          Rect.fromLTRB(double.nan, double.nan, double.nan, double.nan);
      expect(
        ImageViewerPage.debugIsDisplacedFromBaseline(nan, baseline),
        isFalse,
      );
      const inf = Rect.fromLTRB(0, 0, double.infinity, double.infinity);
      expect(
        ImageViewerPage.debugIsDisplacedFromBaseline(inf, baseline),
        isFalse,
      );
    });
  });
}
