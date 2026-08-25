import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/hero_visibility_controller.dart';

/// **push Hero 飞行未跑完就被 pop 打断**(开图立刻返回/连点两下)时,
/// 源端缩略图必须恢复可见 —— 否则飞行体撤走的瞬间那个位置是空洞,
/// 表现为黑闪。
///
/// 缺陷机制(源码可判定,已实测):`startPopping()` 原先挂在源端
/// `flightShuttleBuilder` 的 `direction == pop` 分支里。而框架在
/// push 飞行被 pop 打断时走 `_HeroFlight.divert` 的 push→pop 分支,
/// 它只换 `_proxyAnimation.parent` 与 `heroRectTween`,**不清 `shuttle`**
/// (`heroes.dart`:`shuttle ??= manifest.shuttleBuilder(...)`)——于是
/// shuttleBuilder 全程只以 push 方向被调用一次,pop 分支永不执行,
/// `_isPopping` 恒 false ⇒ `shouldHide` 恒 true ⇒ 源端 Opacity 锁死在 0。
///
/// 实测对照:飞完再 pop 时 shuttle=[push, pop]、isPopping=true;
/// 中途打断时 shuttle=[push]、isPopping=false。
///
/// 修法:宣告退场改由查看器在「路由动画转 reverse」/「手势置位」时直接
/// 做,与 shuttle 是否重建无关。本文件锁住这个契约。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => HeroVisibilityController.instance.clear());

  const srcKey = Key('src');

  /// 记录 shuttleBuilder 被调用的方向序列 —— 用来证明「打断时 pop 分支
  /// 确实没被走到」这个前提仍然成立(上游若改了行为,这里会先暴露)。
  late List<String> shuttleDirections;

  Widget buildApp(GlobalKey<NavigatorState> nav) {
    shuttleDirections = [];
    return MaterialApp(
      navigatorKey: nav,
      home: Scaffold(
        body: Center(
          // 与 hero_image.dart 的源端结构同构
          child: ListenableBuilder(
            listenable: HeroVisibilityController.instance,
            builder: (context, _) {
              final ctrl = HeroVisibilityController.instance;
              final shouldHide =
                  !ctrl.isPopping && ctrl.hiddenHeroTag == 'img';
              return Opacity(
                opacity: shouldHide ? 0.0 : 1.0,
                child: Hero(
                  tag: 'img',
                  transitionOnUserGestures: true,
                  flightShuttleBuilder: (_, _, direction, _, _) {
                    shuttleDirections.add(direction.name);
                    return const SizedBox(width: 60, height: 60);
                  },
                  child: const SizedBox(key: srcKey, width: 60, height: 60),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 源端当前的不透明度;-1 = 源端不在树上(飞行中被 placeholder 取代)
  double srcOpacity(WidgetTester tester) {
    final found = tester.widgetList<Opacity>(
      find.ancestor(of: find.byKey(srcKey), matching: find.byType(Opacity)),
    );
    return found.isEmpty ? -1 : found.first.opacity;
  }

  /// 打开查看器:等价于 initState 隐藏源端 + didChangeDependencies 挂
  /// 路由动画监听(即 _onRouteAnimationStatus)。
  void openViewer(GlobalKey<NavigatorState> nav) {
    HeroVisibilityController.instance.setHiddenTagSilent('img');
    final route = PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (_, _, _) => Hero(
        tag: 'img',
        transitionOnUserGestures: true,
        child: Container(color: const Color(0xFF000000)),
      ),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    );
    nav.currentState!.push(route);
    route.animation!.addStatusListener((status) {
      if (status == AnimationStatus.reverse) {
        HeroVisibilityController.instance.startPopping();
      }
    });
  }

  testWidgets('push 飞行中途 pop 打断:源端必须恢复可见(不留空洞)', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(buildApp(nav));

    openViewer(nav);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    // 前提校验:此刻 push 飞行确实在途,且只构建过 push 方向的 shuttle
    expect(
      shuttleDirections,
      ['push'],
      reason: '前提:必须停在 push 飞行中途',
    );

    // ★ 飞行远未跑完就打断
    nav.currentState!.pop();
    await tester.pump();

    // 关键断言:退场一开始就得宣告,不能等 shuttle 的 pop 分支
    expect(
      HeroVisibilityController.instance.isPopping,
      isTrue,
      reason:
          'isPopping 未置位 ⇒ 源端 Opacity 锁死在 0 ⇒ 飞行体撤走后是空洞'
          '(黑闪)。shuttle 方向序列=$shuttleDirections',
    );

    // 前提再校验:pop 方向的 shuttle 确实**没有**被构建 —— 这正是旧实现
    // 失效的原因;若上游哪天改成重建 shuttle,这里会失败提醒重新评估。
    expect(
      shuttleDirections,
      ['push'],
      reason:
          'pop 方向 shuttle 被重建了 ⇒ 上游 divert 行为已变,'
          '本缺陷的成因描述需要重新评估',
    );

    // 整段退场:源端一旦回到树上就必须是可见的,不许出现 0
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final o = srcOpacity(tester);
      expect(
        o,
        anyOf(equals(-1.0), equals(1.0)),
        reason: '第 $i 帧源端 opacity=$o —— 在树上却不可见 = 空洞黑闪',
      );
    }
    await tester.pumpAndSettle();
  });

  testWidgets('飞行跑完再 pop:同样宣告退场(不得回归)', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(buildApp(nav));

    openViewer(nav);
    await tester.pumpAndSettle();
    expect(shuttleDirections, ['push']);

    nav.currentState!.pop();
    await tester.pump();
    expect(HeroVisibilityController.instance.isPopping, isTrue);

    await tester.pumpAndSettle();
    expect(find.byKey(srcKey), findsOneWidget);
    expect(srcOpacity(tester), 1.0, reason: '收尾后源端必须可见');
  });

  testWidgets('clear() 归零:isPopping 与 hiddenTag 都复位', (tester) async {
    HeroVisibilityController.instance.setHiddenTagSilent('img');
    HeroVisibilityController.instance.startPopping();
    expect(HeroVisibilityController.instance.isPopping, isTrue);

    HeroVisibilityController.instance.clear();
    expect(HeroVisibilityController.instance.isPopping, isFalse);
    expect(HeroVisibilityController.instance.hiddenHeroTag, isNull);
    expect(HeroVisibilityController.instance.exitFlightRect, isNull);
  });
}
