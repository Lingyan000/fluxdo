import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/hero_visibility_controller.dart';

/// 放大态返回的飞行几何契约(修「大图先变小图,再播返回动画」)。
///
/// 旧实现:退场前把画布级缩放归位到 contain,再让 Hero 从全屏布局盒子
/// 起飞 —— 用户看到两段动作。现改为把「放大后图片的实际可见矩形」
/// (GestureDetails.destinationRect)发布给源端 Hero 作飞行起点,于是
/// 「放大 3x → 缩略图」是一段连续插值。参考 Telegram PhotoViewer
/// closePhoto:animationValues[0] 直接取当前 scale/translation。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => HeroVisibilityController.instance.setExitFlightRect(null));
  tearDown(() => HeroVisibilityController.instance.setExitFlightRect(null));

  /// 直接用产品代码那一个共享实现,不复刻 —— 复刻的话产品逻辑改坏了这里
  /// 照样过(自洽装置)。所有源端 Hero 都挂的就是它。
  const buildTween = viewerHeroRectTween;

  const viewerBox = Rect.fromLTWH(0, 0, 400, 800); // 查看器布局盒子(全屏)
  const thumbBox = Rect.fromLTWH(20, 300, 80, 80); // 源端缩略图

  test('未放大:走框架默认几何(起点=查看器布局盒子)', () {
    final tween = buildTween(viewerBox, thumbBox);
    expect(tween.begin, viewerBox);
    expect(tween.end, thumbBox);
  });

  test('放大态:起点换成放大后可见矩形,终点仍是缩略图', () {
    // 3x 放大且平移过:矩形远大于屏幕、原点为负
    const zoomed = Rect.fromLTWH(-400, -600, 1200, 2400);
    HeroVisibilityController.instance.setExitFlightRect(zoomed);

    final tween = buildTween(viewerBox, thumbBox);
    expect(tween.begin, zoomed, reason: '飞行必须从当前放大姿态起飞');
    expect(tween.end, thumbBox, reason: '终点始终是源端缩略图');

    // 插值全程连续:t=0 即放大态,t=1 即缩略图,中间单调收缩
    final t0 = tween.transform(0.0)!;
    final tMid = tween.transform(0.5)!;
    final t1 = tween.transform(1.0)!;
    expect(t0, zoomed);
    expect(t1, thumbBox);
    expect(tMid.width, lessThan(t0.width), reason: '中途应已在收缩');
    expect(tMid.width, greaterThan(t1.width));
  });

  test('缩放快照发布口径:仅放大态发布,scale<=1 与空矩形发 null', () {
    final ctrl = HeroVisibilityController.instance;

    // 与 _publishExitFlightRect 同构的判定
    Rect? publish({required double scale, Rect? rect}) =>
        (scale <= 1.0 || rect == null || rect.isEmpty) ? null : rect;

    expect(publish(scale: 1.0, rect: const Rect.fromLTWH(0, 0, 10, 10)), isNull);
    expect(publish(scale: 3.0, rect: null), isNull);
    expect(publish(scale: 3.0, rect: Rect.zero), isNull);
    expect(
      publish(scale: 3.0, rect: const Rect.fromLTWH(-10, -10, 100, 100)),
      const Rect.fromLTWH(-10, -10, 100, 100),
    );

    // clear 必须复位,否则下一次未放大的返回会误用陈旧矩形
    ctrl.setExitFlightRect(const Rect.fromLTWH(0, 0, 50, 50));
    ctrl.clear();
    expect(ctrl.exitFlightRect, isNull, reason: 'clear 必须复位快照');
  });
}
