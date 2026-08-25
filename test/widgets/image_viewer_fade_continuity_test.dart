import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';

/// Hero 飞行未结束就关闭查看器 → 黑闪 的回归防线。
///
/// 根因(源码可判定,已实测):[CurvedAnimation] 用跨帧字段
/// `_curveDirection` 记住「进入动画时的方向」以保证换向不跳变
/// (`animations.dart`:`_curveDirection ?? status`),而构造函数拿
/// **当帧 status** 初始化它。`_ModalScopeState` 用 ListenableBuilder
/// 监听路由动画,转场树每帧重建 —— 若在 transitionsBuilder 里直接 new
/// 一份 CurvedAnimation,方向记忆每帧被抹成当帧值,机制彻底失效。
///
/// 叠加查看器前后不对称的区间(fwd `Interval(0,0.6)` / rev
/// `Interval(0.4,1)`),后果是中途反向那一帧 **parent 值不变而 alpha
/// 断崖**:实测 parent 恒为 0.427,alpha 0.879 → 0.004。观感即黑底
/// 瞬间消失、底页全露,而 Hero 还在飞 = 用户报的黑闪。
///
/// 测试必须复现「转场树每帧重建」这个前提([_EveryFrameRebuild] 模拟
/// _ModalScopeState 的 ListenableBuilder),否则 build 只跑一次,缺陷
/// 不会被触发,断言就是摆设 —— 反向验证时已实测到这个陷阱。
void main() {
  const target = Key('fade-target');

  /// 当前帧真实生效的不透明度:定位到 [target] 的最近 FadeTransition
  /// 祖先,避开 MaterialApp 自带的那些。
  double renderedOpacity(WidgetTester tester) {
    final FadeTransition fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(target),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    return fade.opacity.value;
  }

  /// 查看器真实使用的写法:跨帧持有(壳内 State 持有曲线)
  Widget heldFade(Animation<double> animation, Widget child) =>
      ImageViewerPage.debugRouteFade(animation: animation, child: child);

  /// 对照组 —— 错误写法:每帧现场 new 一份曲线。
  /// 它必须在中途反向时断崖,否则说明本文件的断言失去鉴别力。
  Widget freshFade(Animation<double> animation, Widget child) => FadeTransition(
    opacity: CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      reverseCurve: const Interval(0.4, 1.0, curve: Curves.easeIn),
    ),
    child: child,
  );

  /// 推进到「Hero 还在飞」的中途后反向,返回 (反向前 alpha, 反向后 alpha)。
  Future<(double, double)> alphaAcrossReversal(
    WidgetTester tester,
    Widget Function(Animation<double>, Widget) builder,
  ) async {
    final controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 300),
      vsync: tester,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: _EveryFrameRebuild(
          animation: controller,
          builder: builder,
          child: const SizedBox(key: target, width: 10, height: 10),
        ),
      ),
    );

    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(
      controller.status,
      AnimationStatus.forward,
      reason: '前置条件:必须停在飞行中途,不能已 settle',
    );
    final double before = renderedOpacity(tester);

    // 飞行未结束就关闭
    controller.reverse();
    await tester.pump();
    final double after = renderedOpacity(tester);

    controller.stop();
    return (before, after);
  }

  testWidgets('Hero 飞行中途关闭:查看器整页 alpha 不得断崖', (tester) async {
    final (before, after) = await alphaAcrossReversal(tester, heldFade);

    expect(before, greaterThan(0.3), reason: '半途 alpha 应已可观');
    expect(
      (after - before).abs(),
      lessThan(0.05),
      reason:
          '反向瞬间 alpha 断崖 = 黑闪。'
          '${before.toStringAsFixed(3)} → ${after.toStringAsFixed(3)}',
    );
  });

  testWidgets('对照组:每帧新建曲线必须复现断崖(保证上一条有鉴别力)', (
    tester,
  ) async {
    final (before, after) = await alphaAcrossReversal(tester, freshFade);

    expect(before, greaterThan(0.3));
    expect(
      (after - before).abs(),
      greaterThan(0.5),
      reason:
          '对照组未复现缺陷 ⇒ 本文件失去鉴别力(可能是测试装置没做到每帧'
          '重建,或上游 CurvedAnimation 行为变了),需重新评估。'
          '${before.toStringAsFixed(3)} → ${after.toStringAsFixed(3)}',
    );
  });

  testWidgets('中途关闭后整段退场:alpha 单调不增并收敛到 0', (tester) async {
    final controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 300),
      vsync: tester,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: _EveryFrameRebuild(
          animation: controller,
          builder: heldFade,
          child: const SizedBox(key: target, width: 10, height: 10),
        ),
      ),
    );

    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    controller.reverse();
    await tester.pump();

    double prev = renderedOpacity(tester);
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final v = renderedOpacity(tester);
      expect(v, lessThanOrEqualTo(prev + 0.001), reason: '退场 alpha 回升');
      prev = v;
      if (controller.status == AnimationStatus.dismissed) break;
    }
    expect(prev, 0.0, reason: '退场应收敛到全透明');
  });

  testWidgets('完整打开后再关闭:端点场景不跳(守住不回归)', (tester) async {
    final controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 300),
      vsync: tester,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: _EveryFrameRebuild(
          animation: controller,
          builder: heldFade,
          child: const SizedBox(key: target, width: 10, height: 10),
        ),
      ),
    );

    controller.value = 1.0;
    await tester.pump();
    expect(renderedOpacity(tester), 1.0);

    controller.reverse();
    await tester.pump();
    expect(renderedOpacity(tester), closeTo(1.0, 0.01));
    controller.stop();
  });
}

/// 复现 `_ModalScopeState` 的关键行为:用 ListenableBuilder 监听路由
/// 动画,**每帧重建整棵转场树**(routes.dart:1204-1209)。
///
/// 少了这一层,`pumpWidget` 只会 build 一次,「每帧新建曲线」的缺陷
/// 根本不会被触发 —— 测试会在有 bug 的代码上照样通过。
class _EveryFrameRebuild extends StatelessWidget {
  const _EveryFrameRebuild({
    required this.animation,
    required this.builder,
    required this.child,
  });

  final Animation<double> animation;
  final Widget Function(Animation<double>, Widget) builder;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: animation,
      builder: (context, _) => builder(animation, child),
    );
  }
}
