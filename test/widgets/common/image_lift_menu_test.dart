/// 图片长按预览的手势、过渡、布局与返回行为。
library;

import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
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
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

Widget _host({
  required VoidCallback onOpen,
  VoidCallback? onTap,
  List<ImageLiftAction>? actions,
  WidgetBuilder? preview,
}) {
  return ImageLiftSource(
    key: const ValueKey('lift_source'),
    onShowMenu: (context, press) => ImageLiftMenu.show(
      context: context,
      press: press,
      previewBuilder:
          preview ??
          (_) => const ColoredBox(
            key: ValueKey('lift_preview'),
            color: Colors.red,
          ),
      actions:
          actions ??
          [
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
    ),
    child: GestureDetector(
      onTap: onTap,
      child: const SizedBox(
        width: 100,
        height: 80,
        child: ColoredBox(color: Colors.blue),
      ),
    ),
  );
}

final Finder _previewFinder = find.ancestor(
  of: find.byKey(const ValueKey('lift_preview')),
  matching: find.byType(ClipRSuperellipse),
);

Future<void> _openMenu(WidgetTester tester, Widget host) async {
  await tester.pumpWidget(_wrap(host));
  await tester.longPress(find.byKey(const ValueKey('lift_source')));
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

void _size(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('长按后图片浮起放大，底部操作面板滑入', (tester) async {
    _size(tester, const Size(390, 844));
    var runs = 0;
    await _openMenu(tester, _host(onOpen: () => runs++));

    // 动画进行中(100ms):预览已存在且正在放大(源 100×80 → 目标 358×286),
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
    expect(rect.width, closeTo(358, 1));
    expect(rect.height, closeTo(286.4, 1));
    expect(rect.left, closeTo(16, 1));
    expect(runs, 0);
  });

  testWidgets('短按和拖动不触发菜单，按住后松手不会打开大图', (tester) async {
    var taps = 0;
    final source = find.byKey(const ValueKey('lift_source'));
    await tester.pumpWidget(
      _wrap(
        ListView(
          children: [
            Center(
              child: _host(onOpen: () {}, onTap: () => taps++),
            ),
            const SizedBox(height: 1200),
          ],
        ),
      ),
    );
    final tap = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 300));
    expect(ImageLiftMenu.activeSource.value, isNull);
    await tap.up();
    expect(taps, 1);

    final scroll = await tester.startGesture(tester.getCenter(source));
    await scroll.moveBy(const Offset(0, -35));
    await tester.pump(const Duration(milliseconds: 400));
    expect(ImageLiftMenu.activeSource.value, isNull);
    await scroll.up();
    final held = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 360));
    expect(ImageLiftMenu.activeSource.value, isNotNull);
    await held.up();
    await tester.pumpAndSettle();
    expect(_previewFinder, findsOneWidget);
    expect(taps, 1);
  });

  testWidgets('图片先起步，中途关闭从当前几何位置返回且预览只挂载一次', (tester) async {
    _size(tester, const Size(390, 844));
    var builds = 0;
    await _openMenu(
      tester,
      _host(
        onOpen: () {},
        preview: (_) {
          builds++;
          return const ColoredBox(
            key: ValueKey('lift_preview'),
            color: Colors.red,
          );
        },
      ),
    );
    final source = tester.getRect(_previewFinder);
    await tester.pump(const Duration(milliseconds: 45));
    expect(tester.getRect(_previewFinder).width, greaterThan(source.width));
    expect(tester.getTopLeft(find.text('保存')).dy, greaterThan(844));
    await tester.pump(const Duration(milliseconds: 65));
    final mid = tester.getRect(_previewFinder);
    final row = tester.getTopLeft(find.text('保存'));
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(tester.getRect(_previewFinder), mid);
    expect(tester.getTopLeft(find.text('保存')), row);
    await tester.pump(const Duration(milliseconds: 30));
    expect(tester.getRect(_previewFinder).width, lessThan(mid.width));
    expect(builds, 1);
    await tester.pumpAndSettle();
    expect(ImageLiftMenu.activeSource.value, isNull);
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
    // 淡出刚开始时源图就已恢复。
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
    _size(tester, const Size(390, 844));
    var runs = 0;
    await _openMenu(tester, _host(onOpen: () => runs++));
    await tester.pumpAndSettle();

    await tester.drag(find.text('保存'), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(runs, 0);
    expect(find.byKey(const ValueKey('lift_preview')), findsNothing);
    expect(find.text('保存'), findsNothing);
  });

  testWidgets('面板下拉时图片同步回落，小幅拖动松手后两者一起归位', (tester) async {
    _size(tester, const Size(390, 844));
    await _openMenu(tester, _host(onOpen: () {}));
    await tester.pumpAndSettle();
    final row = find.text('保存');
    final start = tester.getCenter(row);
    final open = tester.getRect(_previewFinder);
    final drag = await tester.startGesture(start);
    await drag.moveBy(const Offset(0, 20));
    await tester.pump();
    final before = tester.getCenter(row);
    await drag.moveBy(const Offset(0, 24));
    await tester.pump();
    expect(tester.getCenter(row).dy, closeTo(before.dy + 24, 0.5));
    final held = tester.getRect(_previewFinder);
    expect(held.width, lessThan(open.width));
    await tester.pump(const Duration(milliseconds: 150));
    await drag.up();
    await tester.pump();
    expect(tester.getRect(_previewFinder), held);
    await tester.pumpAndSettle();
    expect(tester.getRect(_previewFinder), open);
    expect(tester.getCenter(row), start);
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

  testWidgets('矮窗口和大字号下操作纵向排列，列表可滚到底并执行最后一项', (tester) async {
    tester.view.physicalSize = const Size(390, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    int? selected;
    await _openMenu(
      tester,
      _host(
        onOpen: () {},
        actions: [
          for (var i = 0; i < 9; i++)
            ImageLiftAction(
              icon: Icons.copy,
              label: '动作$i',
              onTap: () => selected = i,
            ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final first = tester.getCenter(find.text('动作0'));
    final second = tester.getCenter(find.text('动作1'));
    expect(second.dx, first.dx);
    expect(second.dy - first.dy, greaterThanOrEqualTo(48));
    expect(tester.getRect(_previewFinder).bottom, lessThan(first.dy - 24));
    await tester.drag(find.text('动作1'), const Offset(0, -480));
    await tester.pumpAndSettle();
    await tester.tap(find.text('动作8'));
    await tester.pumpAndSettle();
    expect(selected, 8);
  });

  testWidgets('宽屏长按两侧的图，操作列表向有空间的一侧展开', (tester) async {
    _size(tester, const Size(1280, 800));
    for (final isLeft in [true, false]) {
      await _openMenu(
        tester,
        Align(
          alignment: isLeft
              ? const Alignment(-0.85, 0.45)
              : const Alignment(0.85, 0.45),
          child: _host(onOpen: () {}),
        ),
      );
      await tester.pumpAndSettle();
      final image = tester.getRect(_previewFinder);
      final menu = tester.getRect(find.byType(SingleChildScrollView));
      expect(image.width, greaterThan(480));
      expect(image.overlaps(menu), isFalse);
      expect(
        isLeft ? menu.left - image.right : image.left - menu.right,
        closeTo(16, 0.01),
      );
      expect(menu.top, greaterThan(24));
      expect(menu.bottom, lessThan(800 - 24));
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('横屏侧栏上拉能滚到末项，下拉到顶保留图片', (tester) async {
    _size(tester, const Size(920, 380));
    int? selected;
    await _openMenu(
      tester,
      _host(
        onOpen: () {},
        actions: [
          for (var i = 0; i < 12; i++)
            ImageLiftAction(
              icon: Icons.copy,
              label: '操作$i',
              onTap: () => selected = i,
            ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final image = tester.getRect(_previewFinder);
    final menu = find.byType(SingleChildScrollView);
    await tester.drag(menu, const Offset(0, 160));
    await tester.pumpAndSettle();
    expect(tester.getRect(_previewFinder), image);
    await tester.drag(menu, const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.tap(find.text('操作11'));
    await tester.pumpAndSettle();
    expect(selected, 11);
  });

  testWidgets('拖着底部面板扩窗后，预览和侧栏完成展开', (tester) async {
    _size(tester, const Size(390, 844));
    await _openMenu(tester, _host(onOpen: () {}));
    await tester.pumpAndSettle();
    final finger = await tester.startGesture(tester.getCenter(find.text('保存')));
    await finger.moveBy(const Offset(0, 20));
    await finger.moveBy(const Offset(0, 28));
    await tester.pump();
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    await finger.up();
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.byType(SingleChildScrollView));
    final image = tester.getRect(_previewFinder);
    expect(image.width, greaterThan(480));
    expect(image.right + 16, closeTo(menu.left, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏操作项接收方向键与回车，关闭后恢复正文焦点', (tester) async {
    _size(tester, const Size(1120, 780));
    final focus = FocusNode();
    addTearDown(focus.dispose);
    int? selected;
    await tester.pumpWidget(
      _wrap(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              focusNode: focus,
              autofocus: true,
              onPressed: () {},
              child: const Text('正文'),
            ),
            _host(
              onOpen: () {},
              actions: [
                for (var i = 0; i < 3; i++)
                  ImageLiftAction(
                    icon: Icons.copy,
                    label: '按键$i',
                    onTap: () => selected = i,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    await tester.longPress(find.byKey(const ValueKey('lift_source')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(_previewFinder, findsNothing);
    expect(focus.hasFocus, isTrue);
  });

  testWidgets('折叠屏预览与操作都落在图片所在的半屏', (tester) async {
    _size(tester, const Size(1440, 840));
    tester.view.displayFeatures = const [
      DisplayFeature(
        bounds: Rect.fromLTWH(712, 0, 16, 840),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.unknown,
      ),
    ];
    await _openMenu(
      tester,
      Align(
        alignment: const Alignment(0.8, 0.3),
        child: _host(onOpen: () {}),
      ),
    );
    await tester.pumpAndSettle();
    for (final rect in [
      tester.getRect(_previewFinder),
      tester.getRect(find.byType(SingleChildScrollView)),
    ]) {
      expect(rect.left, greaterThanOrEqualTo(728));
      expect(rect.right, lessThanOrEqualTo(1440));
    }
  });

  testWidgets('同一张图片跨过铰链时，从手指按住的半屏展开', (tester) async {
    _size(tester, const Size(1440, 840));
    tester.view.displayFeatures = const [
      DisplayFeature(
        bounds: Rect.fromLTWH(712, 0, 16, 840),
        type: DisplayFeatureType.hinge,
        state: DisplayFeatureState.unknown,
      ),
    ];
    await tester.pumpWidget(
      _wrap(SizedBox(width: 1000, height: 160, child: _host(onOpen: () {}))),
    );
    for (final x in [1040.0, 400.0]) {
      await tester.longPressAt(Offset(x, 420));
      await tester.pumpAndSettle();
      for (final rect in [
        tester.getRect(_previewFinder),
        tester.getRect(find.byType(SingleChildScrollView)),
      ]) {
        if (x > 728) {
          expect(rect.left, greaterThanOrEqualTo(728));
        } else {
          expect(rect.right, lessThanOrEqualTo(712));
        }
      }
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
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
        of: find.byType(ClipRSuperellipse),
        matching: find.byKey(const ValueKey('lift_preview')),
      ),
    );
    // 竖屏:预览宽 = 390 - 32 = 358。
    expect(rectBefore.width, closeTo(358, 1));

    // 桌面宽窗口尺寸变化(模拟拖拽窗口边缘/旋转)。
    tester.view.physicalSize = const Size(1000, 800);
    await tester.pump();
    await tester.pumpAndSettle();

    final rectAfter = tester.getRect(
      find.descendant(
        of: find.byType(ClipRSuperellipse),
        matching: find.byKey(const ValueKey('lift_preview')),
      ),
    );
    final panel = tester.getRect(find.byType(SingleChildScrollView));
    expect(rectAfter.width, greaterThan(480));
    expect(rectAfter.right, lessThan(panel.left));
    expect(rectAfter.overlaps(panel), isFalse);
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
      expect(
        r.right,
        lessThanOrEqualTo(395),
        reason: '第 $i 帧 right=${r.right}',
      );
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

    // 关闭:回落动画进行中,预览从目标位(居中,left=16)朝新源位
    // (left=60)移动且始终在窗口内。
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(); // 首帧:回落动画启动(ticker 起点)
    await tester.pump(const Duration(milliseconds: 60));
    var mid = tester.getRect(_previewFinder);
    expect(mid.left, greaterThan(16), reason: '应已离开目标位向源移动');
    expect(mid.left, lessThan(60), reason: '尚未到达源位');
    expect(mid.right, lessThanOrEqualTo(390));
    // 近终点:贴近新源位置(窗口缩窄后的 left≈60)。
    await tester.pump(const Duration(milliseconds: 145));
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

    final original = tester.getRect(find.byKey(const ValueKey('lift_source')));
    expect(
      tester.getRect(_previewFinder),
      original.intersect(const Rect.fromLTWH(0, 0, 1084, 800)),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('lift_preview'))),
      original,
    );

    // 动画全程逐帧断言:预览任何时刻都不越出窗口。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (_previewFinder.evaluate().isEmpty) continue;
      final r = tester.getRect(_previewFinder);
      expect(r.left, greaterThanOrEqualTo(0), reason: '第 $i 帧 left=${r.left}');
      expect(
        r.right,
        lessThanOrEqualTo(1084),
        reason: '第 $i 帧 right=${r.right}',
      );
    }
    await tester.pumpAndSettle();

    final rect = tester.getRect(_previewFinder);
    expect(rect.width, greaterThan(480));
    expect(rect.width / rect.height, closeTo(1.5, 0.01));
    expect(
      tester.getRect(find.byType(SingleChildScrollView)).right,
      lessThan(rect.left),
    );

    // 关闭:起点即 intersect 后的可见区,回落主体在窗口内。
    // 回落时裁切边界也沿原路收回。
    await tester.tapAt(const Offset(10, 10));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (_previewFinder.evaluate().isEmpty) break;
      final r = tester.getRect(_previewFinder);
      expect(
        r.left,
        greaterThanOrEqualTo(0),
        reason: '回落第 $i 帧 left=${r.left}',
      );
      expect(
        r.right,
        lessThanOrEqualTo(1084),
        reason: '回落第 $i 帧 right=${r.right}',
      );
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
              builder: (context, constraints) =>
                  SizedBox(height: constraints.maxWidth < 800 ? 5000 : 100),
            ),
            _host(onOpen: () {}),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('lift_source')));
    await tester.pumpAndSettle();

    var rect = tester.getRect(_previewFinder);
    expect(rect.width, greaterThan(480));
    expect(
      rect.overlaps(tester.getRect(find.byType(SingleChildScrollView))),
      isFalse,
    );

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
    expect(rect.width, closeTo(390 - 32, 1));

    // 关闭:源已卸载 → 原地淡出,菜单正常移除、源标记清理。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_previewFinder, findsNothing);
    expect(ImageLiftMenu.activeSource.value, isNull);
  });

  testWidgets('系统返回(maybePop):先关菜单而非 pop 页面', (tester) async {
    var runs = 0;
    await _openMenu(tester, _host(onOpen: () => runs++));
    await tester.pumpAndSettle();

    // 模拟系统返回/页面返回入口:LocalHistoryEntry 消费 → 关菜单。
    // 注意:maybePop 返回 true 只表示返回请求被「处理」(history 消费
    // 也算处理),页面是否真 pop 要看页面 widget 是否还在树上。
    await navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    // 菜单已关、页面未被 pop(home 的源 widget 仍在树上)。
    expect(find.byKey(const ValueKey('lift_preview')), findsNothing);
    expect(find.byKey(const ValueKey('lift_source')), findsOneWidget);
    expect(ImageLiftMenu.activeSource.value, isNull);
    expect(runs, 0);
  });

  testWidgets('预测返回的取消和提交都接续当前可见帧', (tester) async {
    Future<void> back(String method, [double progress = 0]) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'flutter/backgesture',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, {
              'touchOffset': <double>[0, 300],
              'progress': progress,
              'swipeEdge': 0,
            }),
          ),
          (_) {},
        );

    await _openMenu(tester, _host(onOpen: () {}));
    await tester.pumpAndSettle();
    final open = tester.getRect(_previewFinder);
    for (final finish in ['cancelBackGesture', 'commitBackGesture']) {
      await back('startBackGesture');
      await back('updateBackGestureProgress', 0.45);
      await tester.pump();
      final held = tester.getRect(_previewFinder);
      expect(held.width, lessThan(open.width));
      expect(held.width, greaterThan(100));
      await back(finish);
      await tester.pump();
      expect(tester.getRect(_previewFinder), held);
      await tester.pumpAndSettle();
      if (finish == 'cancelBackGesture') {
        expect(tester.getRect(_previewFinder), open);
      }
    }
    expect(_previewFinder, findsNothing);
    expect(ImageLiftMenu.activeSource.value, isNull);
  });
}
