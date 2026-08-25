/// X 风格图片长按浮起菜单(ImageLiftMenu)行为测试:
/// 浮起预览与动作面板同时出现、点选动作执行回调、点遮罩/面板下拉关闭、
/// 源图会话隐藏(activeSource 生命周期)、ESC surface 注册与关闭。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/shortcut_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/common/image_lift_menu.dart';

Widget _wrap(Widget child) {
  return TranslationProvider(
    child: ProviderScope(
      child: MaterialApp(
        locale: const Locale('zh'),
        navigatorKey: navigatorKey,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

Widget _host({required VoidCallback onOpen}) {
  return Builder(
    key: const ValueKey('lift_source'),
    builder: (context) => GestureDetector(
      onLongPress: () {
        ImageLiftMenu.show(
          context: context,
          previewBuilder: (_) => const KeyedSubtree(
            key: ValueKey('lift_preview'),
            child: ColoredBox(color: Colors.red),
          ),
          actions: [
            ImageLiftAction(
              icon: Icons.save_outlined,
              label: '保存',
              onTap: onOpen,
            ),
            ImageLiftAction(
              icon: Icons.copy_outlined,
              label: '复制',
              onTap: onOpen,
            ),
          ],
        );
      },
      // ColoredBox 参与命中测试(空 SizedBox 不吸收指针,长按无从触发)。
      child: const SizedBox(
        width: 100,
        height: 80,
        child: ColoredBox(color: Colors.blue),
      ),
    ),
  );
}

final Finder _previewFinder = find.descendant(
  of: find.byType(ClipRRect),
  matching: find.byKey(const ValueKey('lift_preview')),
);

Future<void> _openMenu(WidgetTester tester, Widget host) async {
  await tester.pumpWidget(_wrap(host));
  await tester.pump();
  await tester.longPress(find.byKey(const ValueKey('lift_source')));
  // 第一帧:测量面板(waitingMeasure,遮罩全透明);
  // 第二帧起:浮起动画进行中。
  await tester.pump();
  await tester.pump();
}

/// 从 widget 树里解析当前 imageLiftMenu surface 注册项(存在时)。
ShortcutSurfaceRegistration? _liftSurfaceRegistration(WidgetTester tester) {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Scaffold)),
    listen: false,
  );
  final registry = container.read(shortcutSurfaceRegistryProvider);
  for (final registration in registry.registrations.values) {
    if (registration.id == ShortcutSurfaceIds.imageLiftMenu) {
      return registration;
    }
  }
  return null;
}

void main() {
  testWidgets('长按:预览与动作面板同时出现,预览浮起放大', (tester) async {
    var runs = 0;
    await _openMenu(tester, _host(onOpen: () => runs++));

    // 动画进行中(100ms):预览已存在且正在放大(源 100×80 → 目标 ~390×312),
    // 动作面板同时在滑入(按钮已在树中且未到位)。
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('lift_preview')), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    final midRect = tester.getRect(find.byKey(const ValueKey('lift_preview')));
    expect(midRect.width, greaterThan(100));
    expect(midRect.width, lessThan(500));

    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(const ValueKey('lift_preview')));
    // 浮起到屏幕中上部:明显大于源图、水平居中。
    expect(rect.width, closeTo(390, 30));
    expect(rect.height, closeTo(312, 30));
    expect(rect.left, greaterThan(100));
    expect(runs, 0);
  });

  testWidgets('会话期间源图标记隐藏,关闭后恢复', (tester) async {
    var runs = 0;
    await _openMenu(tester, _host(onOpen: () => runs++));

    // 源 element 已登记:源图据此 Opacity(0) 隐藏(lift「拿走」语义)。
    expect(ImageLiftMenu.activeSource.value, isNotNull);

    await tester.pumpAndSettle();
    expect(ImageLiftMenu.activeSource.value, isNotNull);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    // 回落完成:源图恢复可见,菜单移除。
    expect(ImageLiftMenu.activeSource.value, isNull);
    expect(find.byKey(const ValueKey('lift_preview')), findsNothing);
    expect(runs, 0);
  });

  testWidgets('点选动作:菜单消散后执行回调,源图立即恢复(交叉淡出)', (tester) async {
    var runs = 0;
    await _openMenu(tester, _host(onOpen: () => runs++));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    // 淡出动画刚开始:源图已恢复(iOS 交叉淡出语义)。
    await tester.pump();
    expect(ImageLiftMenu.activeSource.value, isNull);

    await tester.pumpAndSettle();
    expect(runs, 1);
    expect(find.byKey(const ValueKey('lift_preview')), findsNothing);
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('点遮罩:预览回落、菜单整体收回,不触发动作', (tester) async {
    var runs = 0;
    await _openMenu(tester, _host(onOpen: () => runs++));
    await tester.pumpAndSettle();

    // 点击预览与面板之外的遮罩区域(屏幕左上角)。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(runs, 0);
    expect(find.byKey(const ValueKey('lift_preview')), findsNothing);
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('面板下拉:跟手滑出后整体收回', (tester) async {
    var runs = 0;
    await _openMenu(tester, _host(onOpen: () => runs++));
    await tester.pumpAndSettle();

    await tester.drag(find.text('保存'), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(runs, 0);
    expect(find.byKey(const ValueKey('lift_preview')), findsNothing);
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('ESC surface:注册压过页面,关菜单而非页面,关闭后注销', (tester) async {
    var runs = 0;
    await _openMenu(tester, _host(onOpen: () => runs++));
    await tester.pumpAndSettle();

    // 菜单打开期间:overlay surface 已注册,ESC 走 onClose。
    final registration = _liftSurfaceRegistration(tester);
    expect(registration, isNotNull);
    expect(registration!.blocksShortcuts, isTrue);

    // 模拟全局快捷键分发端调用 onClose(ESC 路径)。
    registration.onClose!();
    await tester.pumpAndSettle();

    // 菜单收回,动作未触发,surface 已注销。
    expect(runs, 0);
    expect(find.byKey(const ValueKey('lift_preview')), findsNothing);
    expect(_liftSurfaceRegistration(tester), isNull);
    expect(ImageLiftMenu.activeSource.value, isNull);
  });

  testWidgets('动作多时单行不换行(横向滚动)', (tester) async {
    var runs = 0;
    // 7 个动作(内容图全量场景)× 76px = 532px,超过手机宽必然溢出。
    await tester.pumpWidget(
      _wrap(
        Builder(
          key: const ValueKey('lift_source'),
          builder: (context) => GestureDetector(
            onLongPress: () => ImageLiftMenu.show(
              context: context,
              previewBuilder: (_) => const ColoredBox(color: Colors.red),
              actions: [
                for (var i = 0; i < 7; i++)
                  ImageLiftAction(
                    icon: Icons.save_outlined,
                    label: '动作$i',
                    onTap: () => runs++,
                  ),
              ],
            ),
            child: const SizedBox(
              width: 100,
              height: 80,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('lift_source')));
    await tester.pumpAndSettle();

    // 所有按钮图标同一 y(单行):取 7 个图标中心,极差为 0。
    final centers = find
        .byIcon(Icons.save_outlined)
        .evaluate()
        .map((e) => tester.getCenter(find.byWidget(e.widget)));
    final ys = centers.map((c) => c.dy).toList()..sort();
    expect(ys.length, 7);
    expect(ys.last - ys.first, lessThan(1));

    // 横向可滚动(内容溢出面板宽度)。
    final scrollable = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byType(Row),
    );
    expect(scrollable, findsOneWidget);
  });

  testWidgets('窗口尺寸变化:预览与面板自适应新布局', (tester) async {
    var runs = 0;
    // 手机竖屏尺寸打开(tester.view 驱动物理尺寸,didChangeMetrics 生效)。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _openMenu(tester, _host(onOpen: () => runs++));
    await tester.pumpAndSettle();

    final rectBefore = tester.getRect(
      find.descendant(
        of: find.byType(ClipRRect),
        matching: find.byKey(const ValueKey('lift_preview')),
      ),
    );
    // 竖屏:预览宽 = 390 - 48 = 342。
    expect(rectBefore.width, closeTo(342, 1));

    // 桌面宽窗口尺寸变化(模拟拖拽窗口边缘/旋转)。
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pump();
    await tester.pumpAndSettle();

    final rectAfter = tester.getRect(
      find.descendant(
        of: find.byType(ClipRRect),
        matching: find.byKey(const ValueKey('lift_preview')),
      ),
    );
    // 宽窗口:预览宽 = min(1000-48, 480) = 480,且在新窗口内水平居中。
    expect(rectAfter.width, closeTo(480, 1));
    expect(rectAfter.left, closeTo((1000 - 480) / 2, 2));
    expect(runs, 0);
  });

  testWidgets('窗口大改后源图被推出视口:关闭原地淡出,不飞出屏幕', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 源图钉在宽窗口右侧(x≈900):缩窄后必然整体落在视口外 ——
    // 复现「文档流大重排把源图推出屏幕」的场景。
    await tester.pumpWidget(
      _wrap(
        Stack(
          children: [
            Positioned(
              left: 900,
              top: 400,
              child: Builder(
                key: const ValueKey('lift_source'),
                builder: (context) => GestureDetector(
                  onLongPress: () => ImageLiftMenu.show(
                    context: context,
                    previewBuilder: (_) => const KeyedSubtree(
                      key: ValueKey('lift_preview'),
                      child: ColoredBox(color: Colors.red),
                    ),
                    actions: [
                      ImageLiftAction(
                        icon: Icons.save_outlined,
                        label: '保存',
                        onTap: () {},
                      ),
                    ],
                  ),
                  child: const SizedBox(
                    width: 100,
                    height: 80,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('lift_source')));
    await tester.pumpAndSettle();

    // 宽窗口内一切正常:预览居中。
    var rect = tester.getRect(_previewFinder);
    expect(rect.left, greaterThan(0));

    // 大幅缩窄:源图(重测后 x≈900)整幅落在 390 宽窗口外。
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();

    // 预览仍然居中在视口内(未跟随源跑出屏幕)。
    rect = tester.getRect(_previewFinder);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(390));

    // 点遮罩关闭:源不可见 → 原地淡出,回落途中任何时刻都不越出窗口。
    await tester.tapAt(const Offset(10, 10));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!_previewFinder.evaluate().isNotEmpty) break;
      final r = tester.getRect(_previewFinder);
      expect(r.left, greaterThanOrEqualTo(-5), reason: '第 $i 帧 left=${r.left}');
      expect(r.right, lessThanOrEqualTo(395), reason: '第 $i 帧 right=${r.right}');
    }
    await tester.pumpAndSettle();
    expect(_previewFinder, findsNothing);
  });

  testWidgets('窗口变化后源图仍在视口:关闭飞向新位置', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 源图钉在左侧,窗口缩窄后仍在视口内(位置移动)。
    await tester.pumpWidget(
      _wrap(
        Stack(
          children: [
            Positioned(
              left: 60,
              top: 300,
              child: Builder(
                key: const ValueKey('lift_source'),
                builder: (context) => GestureDetector(
                  onLongPress: () => ImageLiftMenu.show(
                    context: context,
                    previewBuilder: (_) => const KeyedSubtree(
                      key: ValueKey('lift_preview'),
                      child: ColoredBox(color: Colors.red),
                    ),
                    actions: [
                      ImageLiftAction(
                        icon: Icons.save_outlined,
                        label: '保存',
                        onTap: () {},
                      ),
                    ],
                  ),
                  child: const SizedBox(
                    width: 100,
                    height: 80,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('lift_source')));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();

    // 关闭:回落动画进行中,预览从目标位(居中,left=24)朝新源位
    // (left=60)移动且始终在窗口内。
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(); // 首帧:回落动画启动(ticker 起点)
    await tester.pump(const Duration(milliseconds: 60));
    var mid = tester.getRect(_previewFinder);
    expect(mid.left, greaterThan(24), reason: '应已离开目标位向源移动');
    expect(mid.left, lessThan(60), reason: '尚未到达源位');
    expect(mid.right, lessThanOrEqualTo(390));
    // 近终点:贴近新源位置(窗口缩窄后的 left≈60)。
    await tester.pump(const Duration(milliseconds: 240));
    mid = tester.getRect(_previewFinder);
    expect(mid.left, closeTo(60, 8));
    await tester.pumpAndSettle();
    expect(_previewFinder, findsNothing);
  });

  testWidgets('源盒子超屏(unbounded 容器):起点收在窗口内,全程不出屏', (tester) async {
    tester.view.physicalSize = const Size(1084, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 模拟 cooked 图在 unbounded 容器里按原图尺寸排版的场景:
    // 盒子 3000×2000,左侧 320 起,大部分在屏幕外 —— 用户实际只能
    // 看到 (320..1084) 的 764 宽一段。
    await tester.pumpWidget(
      _wrap(
        Stack(
          children: [
            Positioned(
              left: 320,
              top: 400,
              child: Builder(
                key: const ValueKey('lift_source'),
                builder: (context) => GestureDetector(
                  onLongPress: () => ImageLiftMenu.show(
                    context: context,
                    previewBuilder: (_) => const KeyedSubtree(
                      key: ValueKey('lift_preview'),
                      child: ColoredBox(color: Colors.red),
                    ),
                    actions: [
                      ImageLiftAction(
                        icon: Icons.save_outlined,
                        label: '保存',
                        onTap: () {},
                      ),
                    ],
                  ),
                  child: const SizedBox(
                    width: 3000,
                    height: 2000,
                    child: ColoredBox(color: Colors.blue),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    // 长按可见区域内一点(盒子中心在屏幕外,longPress(finder) 会落空)。
    await tester.longPressAt(const Offset(500, 500));

    // 动画全程逐帧断言:预览任何时刻都不越出窗口。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (_previewFinder.evaluate().isEmpty) continue;
      final r = tester.getRect(_previewFinder);
      expect(r.left, greaterThanOrEqualTo(0), reason: '第 $i 帧 left=${r.left}');
      expect(r.right, lessThanOrEqualTo(1084), reason: '第 $i 帧 right=${r.right}');
    }
    await tester.pumpAndSettle();

    // 稳态:按完整宽高比(1.5)居中,480×320。
    final rect = tester.getRect(_previewFinder);
    expect(rect.width, closeTo(480, 1));
    expect(rect.height, closeTo(320, 1));
    expect(rect.left, closeTo((1084 - 480) / 2, 1));

    // 关闭:起点即 intersect 后的可见区,回落主体在窗口内。
    // 弹簧过冲(liftT 微负 → source 端外推 ~2%)允许贴边侧 ~8px 的
    // 瞬时越界——这是 damping 0.78 弹簧的自然回弹,量级与 iOS 一致。
    await tester.tapAt(const Offset(10, 10));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (_previewFinder.evaluate().isEmpty) break;
      final r = tester.getRect(_previewFinder);
      expect(r.left, greaterThanOrEqualTo(-8), reason: '回落第 $i 帧 left=${r.left}');
      expect(r.right, lessThanOrEqualTo(1092), reason: '回落第 $i 帧 right=${r.right}');
    }
    await tester.pumpAndSettle();
    expect(_previewFinder, findsNothing);
  });

  testWidgets('resize 重排卸载源 element:不中断重测,预览稳态收在新窗口内', (tester) async {
    // 复现桌面端真实路径:菜单打开时拖拽缩窗 → 窄列文档流暴涨把源图
    // 顶出视口 → sliver 回收源 element(defunct)。此前重测对 defunct
    // 元素调 findRenderObject 在 debug 下抛 FlutterError,settle 回调链
    // 中断,目标矩形永远停留在旧宽窗口的居中位 → 预览稳态越出右缘。
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        // 上方占位高度随窗宽变化:窄窗口下把源图顶出视口触发回收。
        ListView(
          children: [
            LayoutBuilder(
              builder: (context, constraints) => SizedBox(
                height: constraints.maxWidth < 800 ? 5000 : 100,
              ),
            ),
            _host(onOpen: () {}),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('lift_source')));
    await tester.pumpAndSettle();

    // 宽窗口稳态:480 宽居中。
    var rect = tester.getRect(_previewFinder);
    expect(rect.width, closeTo(480, 1));
    expect(rect.left, closeTo((1200 - 480) / 2, 1));

    // 收窄:上方占位暴涨,源 element 被回收卸载。
    tester.view.physicalSize = const Size(390, 800);
    await tester.pump();
    // 单帧即跟上新窗口(目标矩形 build 期派生,不等待重测回调链)。
    rect = tester.getRect(_previewFinder);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(390));
    await tester.pumpAndSettle();

    // 全程无异常(settle 链未被卸载的源 element 中断),稳态不越屏。
    expect(tester.takeException(), isNull);
    rect = tester.getRect(_previewFinder);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(390));
    expect(rect.width, closeTo(390 - 48, 1));

    // 关闭:源已卸载 → 原地淡出,菜单正常移除、源标记清理。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_previewFinder, findsNothing);
    expect(ImageLiftMenu.activeSource.value, isNull);
  });
}
