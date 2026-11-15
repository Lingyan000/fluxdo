import 'dart:io';
import 'dart:ui' as ui;

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

const _items = [
  M3eButtonGroupItem(
    value: 0,
    label: Text('发现应用'),
    icon: Icon(Symbols.explore_rounded),
  ),
  M3eButtonGroupItem(
    value: 1,
    label: Text('已收藏'),
    icon: Icon(Symbols.bookmark_rounded),
  ),
];

void main() {
  Widget host(
    Widget child, {
    bool reduced = false,
    TextDirection direction = TextDirection.ltr,
    double scale = 1,
  }) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reduced,
        textScaler: TextScaler.linear(scale),
      ),
      child: Directionality(textDirection: direction, child: child!),
    ),
    home: Scaffold(body: Center(child: child)),
  );

  Finder buttons() => find.descendant(
    of: find.byType(M3eButtonGroup<int>),
    matching: find.byType(Material),
  );

  testWidgets('独立按钮形变不重复激活，保留长按和起手滚动', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var taps = 0, holds = 0;
    await tester.pumpWidget(
      host(
        ListView(
          controller: scroll,
          children: [
            const SizedBox(height: 80),
            Center(
              child: M3eElasticPress(
                child: FilledButton.tonal(
                  onPressed: () => taps++,
                  onLongPress: () => holds++,
                  child: const Text('Action'),
                ),
              ),
            ),
            const SizedBox(height: 1000),
          ],
        ),
      ),
    );
    final button = find.text('Action');
    final idle = tester.getRect(button);
    final gesture = await tester.startGesture(idle.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(tester.getRect(button).width, greaterThan(idle.width));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.getRect(button), idle);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.longPress(button);
    await tester.pumpAndSettle();
    await tester.drag(button, const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(20));
    expect([taps, holds], [1, 1]);
  });

  testWidgets('联排按钮选中时渐变颜色与圆角，按压只改变绘制尺寸，取消后复原', (tester) async {
    var selected = 0;
    var calls = 0;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, update) => SizedBox(
            width: 358,
            child: M3eButtonGroup<int>(
              items: _items,
              selected: selected,
              onSelected: (value) => update(() {
                selected = value;
                calls++;
              }),
            ),
          ),
        ),
      ),
    );
    final originalSize = tester.getSize(find.byType(M3eButtonGroup<int>));
    expect(originalSize.height, lessThanOrEqualTo(42));
    final before = tester.getRect(buttons().last);
    final neighbor = tester.getRect(buttons().first);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('已收藏')),
    );
    await tester.pump(kPressTimeout);
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getRect(buttons().last).width, greaterThan(before.width));
    expect(tester.getRect(buttons().first), neighbor);
    expect(tester.getSize(find.byType(M3eButtonGroup<int>)), originalSize);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(tester.getRect(buttons().last).width, closeTo(before.width, .05));

    final initial = tester.widget<Material>(buttons().last).color!;
    await tester.tap(find.text('已收藏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final middle = tester.widget<Material>(buttons().last);
    final scheme = Theme.of(tester.element(buttons().last)).colorScheme;
    expect(middle.color, isNot(initial));
    expect(middle.color, isNot(scheme.primary));
    final middleShape = middle.shape! as RoundedSuperellipseBorder;
    expect(
      middleShape.borderRadius.resolve(TextDirection.ltr).topLeft.x,
      greaterThan(8),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Material>(buttons().last).color, scheme.primary);
    expect(calls, 1);
    expect(tester.getSize(find.byType(M3eButtonGroup<int>)), originalSize);
  });

  testWidgets('联排按钮保留键盘激活和选中语义，RTL、大字体和关闭动效不溢出', (tester) async {
    final semantics = tester.ensureSemantics();
    var selected = 0;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, update) => SizedBox(
            width: 260,
            child: M3eButtonGroup<int>(
              items: _items,
              selected: selected,
              onSelected: (value) => update(() => selected = value),
            ),
          ),
        ),
        reduced: true,
        direction: TextDirection.rtl,
        scale: 2,
      ),
    );
    final focus = Focus.of(tester.element(find.text('已收藏')));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected, 1);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('联排按钮随触摸和鼠标拖动双轴拉伸，反向连续且松开回弹', (tester) async {
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      var calls = 0;
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 358,
            child: M3eButtonGroup<int>(
              items: _items,
              selected: 0,
              onSelected: (_) => calls++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rest = tester.getRect(buttons().last);
      final neighbor = tester.getRect(buttons().first);
      final groupSize = tester.getSize(find.byType(M3eButtonGroup<int>));
      final gesture = await tester.startGesture(rest.center, kind: kind);
      await tester.pumpAndSettle();
      final pressed = tester.getRect(buttons().last);

      await gesture.moveBy(const Offset(60, 0));
      await tester.pumpAndSettle();
      final right = tester.getRect(buttons().last);
      expect(right.center.dx, greaterThan(pressed.center.dx + 3));
      expect(right.width, greaterThan(pressed.width + 2));
      expect(right.height, closeTo(pressed.height, .05));
      expect(calls, 0);

      await gesture.moveTo(rest.center + const Offset(-60, 32));
      await tester.pump();
      // 改变目标的这一帧不跳位，弹簧延续原来的位置和速度。
      expect(tester.getRect(buttons().last), right);
      await tester.pumpAndSettle();
      final diagonal = tester.getRect(buttons().last);
      expect(diagonal.center.dx, lessThan(rest.center.dx - 3));
      expect(diagonal.center.dy, greaterThan(rest.center.dy + 3));
      expect(diagonal.height, greaterThan(pressed.height + 1));

      await gesture.moveTo(rest.center + const Offset(1000, 1000));
      await tester.pumpAndSettle();
      final far = tester.getRect(buttons().last);
      expect(far.center.dx - rest.center.dx, lessThan(rest.height / 4));
      expect(far.center.dy - rest.center.dy, lessThan(rest.height / 4));
      expect(tester.getRect(buttons().first), neighbor);
      expect(tester.getSize(find.byType(M3eButtonGroup<int>)), groupSize);

      await gesture.up();
      await tester.pump();
      expect(tester.getRect(buttons().last), far);
      await tester.pumpAndSettle();
      expect(tester.getRect(buttons().last), rest);
      expect(calls, 0);
      await gesture.removePointer();
      // 拖动取消点击后，下一次正常点击仍只触发一次。
      await tester.tap(find.text('已收藏'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('三项按钮组逐项拖过邻项时只形变起手按钮，LTR 与 RTL 一致', (tester) async {
    for (final direction in TextDirection.values) {
      var calls = 0;
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 358,
            child: M3eButtonGroup<int>(
              items: const [
                M3eButtonGroupItem(value: 0, label: Text('规则')),
                M3eButtonGroupItem(value: 1, label: Text('全局')),
                M3eButtonGroupItem(value: 2, label: Text('直连')),
              ],
              selected: 0,
              onSelected: (_) => calls++,
            ),
          ),
          direction: direction,
        ),
      );
      await tester.pumpAndSettle();
      final group = find.byType(M3eButtonGroup<int>);
      final bounds = tester.getRect(group);
      final resting = [
        for (var i = 0; i < 3; i++) tester.getRect(buttons().at(i)),
      ];
      for (var active = 0; active < 3; active++) {
        final gesture = await tester.startGesture(resting[active].center);
        await tester.pumpAndSettle();
        for (final dx in [140.0, -140.0]) {
          await gesture.moveTo(resting[active].center + Offset(dx, 25));
          await tester.pumpAndSettle();
          expect(tester.getRect(group), bounds);
          for (var i = 0; i < 3; i++) {
            final actual = tester.getRect(buttons().at(i));
            if (i == active) {
              expect(actual.width, greaterThan(resting[i].width));
              expect(actual.center.dy, greaterThan(resting[i].center.dy));
            } else {
              expect(actual, resting[i]);
            }
          }
        }
        await gesture.up();
        await tester.pumpAndSettle();
        for (var i = 0; i < 3; i++) {
          expect(tester.getRect(buttons().at(i)), resting[i]);
        }
        expect(calls, active);
        await tester.tap(buttons().at(active));
        await tester.pumpAndSettle();
        expect(calls, active + 1);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('拖动只跟踪首个主指针，取消及减少动画时复原', (tester) async {
    var calls = 0;
    var reduced = false;
    late StateSetter updateHost;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, update) {
          updateHost = update;
          return host(
            SizedBox(
              width: 358,
              child: M3eButtonGroup<int>(
                items: _items,
                selected: 0,
                onSelected: (_) => calls++,
              ),
            ),
            reduced: reduced,
            direction: TextDirection.rtl,
          );
        },
      ),
    );
    final rest = tester.getRect(buttons().last);
    final gesture = await tester.startGesture(rest.center, pointer: 21);
    await gesture.moveBy(const Offset(60, 0));
    await tester.pumpAndSettle();
    final pulled = tester.getRect(buttons().last);
    expect(pulled.center.dx, greaterThan(rest.center.dx + 3));
    final second = await tester.startGesture(rest.center, pointer: 22);
    await second.moveBy(const Offset(-80, -80));
    await second.cancel();
    await tester.pumpAndSettle();
    expect(tester.getRect(buttons().last), pulled);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.getRect(buttons().last), rest);
    expect(calls, 0);

    final active = await tester.startGesture(rest.center, pointer: 23);
    await active.moveBy(const Offset(-60, 30));
    await tester.pumpAndSettle();
    updateHost(() => reduced = true);
    await tester.pump();
    expect(tester.getRect(buttons().last), rest);
    await active.moveBy(const Offset(120, 0));
    await active.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(buttons().last), rest);
    expect(calls, 0);

    updateHost(() => reduced = false);
    await tester.pump();
    final secondary = await tester.startGesture(
      rest.center,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.moveBy(const Offset(60, 20));
    await tester.pumpAndSettle();
    expect(tester.getRect(buttons().last), rest);
    await secondary.up();
    await secondary.removePointer();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按钮拖动独占手势，不触发滚动或选择，区域外仍可滚动', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var calls = 0;
    await tester.pumpWidget(
      host(
        ListView(
          controller: scroll,
          children: [
            const SizedBox(height: 200),
            M3eButtonGroup<int>(
              items: _items,
              selected: 0,
              onSelected: (_) => calls++,
            ),
            const SizedBox(height: 1200),
          ],
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('已收藏')),
    );
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.offset, 0);
    expect(calls, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('已收藏'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.dragFrom(const Offset(100, 500), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(50));
    final removed = await tester.startGesture(
      tester.getCenter(find.text('已收藏')),
    );
    await removed.moveBy(const Offset(60, 0));
    await tester.pumpWidget(const SizedBox());
    await removed.moveBy(const Offset(0, -20));
    await removed.up();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按钮高频拖动不触发父级点击、长按或拖动，只在松手后恢复点击', (tester) async {
    var selected = 0;
    var parentEvents = 0;
    await tester.pumpWidget(
      host(
        GestureDetector(
          onTap: () => parentEvents++,
          onLongPress: () => parentEvents++,
          onPanUpdate: (_) => parentEvents++,
          child: SizedBox(
            width: 358,
            child: M3eButtonGroup<int>(
              items: _items,
              selected: 0,
              onSelected: (_) => selected++,
            ),
          ),
        ),
      ),
    );
    final origin = tester.getCenter(find.text('已收藏'));
    final gesture = await tester.startGesture(origin);
    await gesture.moveBy(const Offset(30, 0));
    for (var frame = 0; frame < 12; frame++) {
      for (var event = 0; event < 20; event++) {
        await gesture.moveTo(origin + Offset(30 + frame * 3 + event / 20, 12));
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 600));
    expect(selected, 0);
    expect(parentEvents, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 0);
    expect(parentEvents, 0);
    await tester.tap(find.text('已收藏'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(parentEvents, 0);
  });

  testWidgets('菜单形变中内容保持文字比例，选项回调及禁用状态保持原语义', (tester) async {
    var selected = 0;
    var tapped = 0;
    await tester.pumpWidget(
      host(
        Align(
          alignment: Alignment.bottomRight,
          child: SwipeDismissiblePopupMenuButton<int>(
            position: PopupMenuPosition.under,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 1,
                onTap: () => tapped++,
                child: const Text('Newest'),
              ),
              const PopupMenuItem(
                value: 2,
                enabled: false,
                child: Text('Disabled'),
              ),
            ],
            onSelected: (value) => selected = value,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Sort'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Sort'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final movingText = tester.getRect(find.text('Newest'));
    await tester.pumpAndSettle();
    final finalText = tester.getRect(find.text('Newest'));
    expect(movingText.width / finalText.width, lessThan(.95));
    expect(
      movingText.height / movingText.width,
      closeTo(finalText.height / finalText.width, .01),
    );
    expect(movingText.top, isNot(closeTo(finalText.top, 1)));
    await tester.tap(find.text('Disabled'));
    await tester.pumpAndSettle();
    expect(selected, 0);
    await tester.tap(find.text('Newest'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(tapped, 1);
    expect(find.text('Newest'), findsNothing);
  });

  testWidgets('菜单展开中返回再打开不残留，减少动画时开关均立即完成', (tester) async {
    for (final reduced in [false, true]) {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: child!,
          ),
          home: Scaffold(
            body: SwipeDismissiblePopupMenuButton<int>(
              itemBuilder: (_) => const [
                PopupMenuItem(value: 1, child: Text('One')),
              ],
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final beforeReverse = tester.getRect(find.text('One'));
      final route =
          ModalRoute.of(tester.element(find.text('One'))) as TransitionRoute;
      if (reduced) {
        expect(route.transitionDuration, Duration.zero);
        expect(route.reverseTransitionDuration, Duration.zero);
      }
      await navigator.currentState!.maybePop();
      await tester.pump();
      if (!reduced) {
        final afterReverse = tester.getRect(find.text('One'));
        expect(afterReverse.left, closeTo(beforeReverse.left, .1));
        expect(afterReverse.top, closeTo(beforeReverse.top, .1));
      }
      await tester.pumpAndSettle();
      expect(find.text('One'), findsNothing);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('One').hitTestable(), findsOneWidget);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('菜单子项选中关闭整链，自定义外壳与指定 Navigator 保持兼容', (tester) async {
    final nested = GlobalKey<NavigatorState>();
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Builder(
                builder: (context) => SwipeDismissiblePopupMenuButton<int>(
                  menuNavigatorKey: nested,
                  itemBuilder: (_) => const [
                    ExpandablePopupMenuEntry<int>(
                      icon: Icons.settings,
                      label: 'More',
                      children: [
                        ExpandableMenuChild(
                          value: 7,
                          icon: Icons.check,
                          label: 'Child',
                        ),
                      ],
                    ),
                  ],
                  onSelected: (value) => selected = value,
                  child: const Text('Open'),
                ),
              ),
              Expanded(
                child: Navigator(
                  key: nested,
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Child'));
    await tester.pumpAndSettle();
    expect(selected, 7);
    expect(find.text('More'), findsNothing);
    expect(nested.currentState!.canPop(), isFalse);

    final context = tester.element(find.text('Open'));
    final result = showSwipeDismissibleMenu<int>(
      context: context,
      position: const RelativeRect.fromLTRB(30, 60, 300, 300),
      animationAnchorRect: const Rect.fromLTWH(30, 30, 60, 30),
      surfaceBuilder: (_, child) => Material(
        key: const ValueKey('custom-menu-surface'),
        color: Colors.teal,
        child: child,
      ),
      items: const [PopupMenuItem(value: 9, child: Text('Custom'))],
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('custom-menu-surface')), findsOneWidget);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    expect(await result, 9);
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实公共组件的亮暗主题和交互帧预览', (tester) async {
    const directory = String.fromEnvironment('SHARED_CONTROL_PREVIEW_DIR');
    if (directory.isEmpty) return;
    final originalShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = originalShadows);
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader(
          'packages/material_symbols_icons/${Symbols.apps_rounded.fontFamily}',
        )..addFont(
          rootBundle.load(
            'packages/material_symbols_icons/lib/fonts/MaterialSymbolsRounded.ttf',
          ),
        ))
        .load();
    tester.view.physicalSize = const Size(390, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    final dragPointer = ValueNotifier<Offset?>(null);
    addTearDown(dragPointer.dispose);
    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(directory).create(recursive: true);
        await File('$directory/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final brightness in Brightness.values) {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      var selected = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            builder: (context, child) => Stack(
              children: [
                child!,
                ValueListenableBuilder<Offset?>(
                  valueListenable: dragPointer,
                  builder: (context, position, _) => position == null
                      ? const SizedBox.shrink()
                      : Positioned(
                          left: position.dx - 7,
                          top: position.dy - 7,
                          child: IgnorePointer(
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: .8),
                                border: Border.all(
                                  color: Colors.black54,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
            theme: ThemeData(
              fontFamily: 'MiSans',
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff74612c),
                brightness: brightness,
              ),
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                child: StatefulBuilder(
                  builder: (context, update) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '公共组件预览',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        '联排选择按钮',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      M3eButtonGroup<int>(
                        items: _items,
                        selected: selected,
                        onSelected: (value) => update(() => selected = value),
                      ),
                      const SizedBox(height: 20),
                      M3eButtonGroup<int>(
                        items: const [
                          M3eButtonGroupItem(
                            value: 0,
                            label: Text('规则'),
                            icon: Icon(Symbols.rule_rounded),
                          ),
                          M3eButtonGroupItem(
                            value: 1,
                            label: Text('全局'),
                            icon: Icon(Symbols.language_rounded),
                          ),
                          M3eButtonGroupItem(
                            value: 2,
                            label: Text('直连'),
                            icon: Icon(Symbols.adjust_rounded),
                          ),
                        ],
                        selected: selected,
                        onSelected: (value) => update(() => selected = value),
                      ),
                      const SizedBox(height: 36),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '下拉菜单',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          SwipeDismissiblePopupMenuButton<int>(
                            initialValue: 0,
                            position: PopupMenuPosition.under,
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            itemBuilder: (_) => const [
                              CheckedPopupMenuItem(
                                value: 0,
                                checked: true,
                                child: Text('最新上线'),
                              ),
                              CheckedPopupMenuItem(
                                value: 1,
                                checked: false,
                                child: Text('最多使用'),
                              ),
                              CheckedPopupMenuItem(
                                value: 2,
                                checked: false,
                                child: Text('评分最高'),
                              ),
                              ExpandablePopupMenuEntry<int>(
                                icon: Icons.tune,
                                label: '更多排序',
                                children: [
                                  ExpandableMenuChild(
                                    value: 3,
                                    icon: Icons.favorite_outline,
                                    label: '收藏最多',
                                  ),
                                  ExpandableMenuChild(
                                    value: 4,
                                    icon: Icons.update,
                                    label: '最近更新',
                                  ),
                                ],
                              ),
                            ],
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Text('最新上线'),
                                  SizedBox(width: 6),
                                  Icon(Symbols.sort_rounded, size: 20),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await capture('${brightness.name}-rest');
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('已收藏')),
      );
      await tester.pump(kPressTimeout);
      await tester.pump(const Duration(milliseconds: 160));
      await capture('${brightness.name}-pressed');
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await capture('${brightness.name}-switching');
      await tester.pumpAndSettle();
      var dragFrame = 0;
      Future<void> captureDrag() => capture(
        '${brightness.name}-drag-${(dragFrame++).toString().padLeft(2, '0')}',
      );
      await captureDrag();
      final origin = tester.getCenter(find.text('全局'));
      dragPointer.value = origin;
      final drag = await tester.startGesture(origin);
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        await captureDrag();
      }
      for (var frame = 1; frame <= 6; frame++) {
        final position = origin + Offset(frame * 10, 0);
        dragPointer.value = position;
        await drag.moveTo(position);
        await tester.pump(const Duration(milliseconds: 40));
        await captureDrag();
      }
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        await captureDrag();
      }
      for (var frame = 1; frame <= 12; frame++) {
        final position = origin + Offset(60 - frame * 10, -frame.toDouble());
        dragPointer.value = position;
        await drag.moveTo(position);
        await tester.pump(const Duration(milliseconds: 40));
        await captureDrag();
      }
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        await captureDrag();
      }
      dragPointer.value = null;
      await drag.up();
      for (var frame = 0; frame < 15; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        await captureDrag();
      }
      await tester.pumpAndSettle();
      var menuFrame = 0;
      Future<void> captureMenuPress() => capture(
        '${brightness.name}-menu-press-${(menuFrame++).toString().padLeft(2, '0')}',
      );
      await captureMenuPress();
      final menuOrigin = tester.getCenter(find.text('最新上线'));
      dragPointer.value = menuOrigin;
      final menuPress = await tester.startGesture(menuOrigin);
      await tester.pump();
      for (var frame = 0; frame < 7; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        await captureMenuPress();
      }
      Future<void> slideMenu(String label) async {
        final start = dragPointer.value!;
        final end = tester.getCenter(find.text(label));
        for (var frame = 1; frame <= 6; frame++) {
          final position = Offset.lerp(start, end, frame / 6)!;
          dragPointer.value = position;
          await menuPress.moveTo(position);
          await tester.pump(const Duration(milliseconds: 40));
          await captureMenuPress();
        }
      }

      await slideMenu('最多使用');
      await slideMenu('更多排序');
      for (var frame = 0; frame < 18; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        await captureMenuPress();
      }
      await slideMenu('最近更新');
      dragPointer.value = null;
      await menuPress.up();
      for (var frame = 0; frame < 9; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        await captureMenuPress();
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('最新上线'));
      await tester.pump();
      await capture('${brightness.name}-menu-frame-00');
      for (var frame = 1; frame <= 7; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        await capture('${brightness.name}-menu-frame-0$frame');
      }
      await tester.pumpAndSettle();
      final menuContext = tester.element(find.text('最多使用'));
      Navigator.of(menuContext).pop();
      await tester.pump();
      for (var frame = 8; frame <= 13; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        await capture(
          '${brightness.name}-menu-frame-${frame.toString().padLeft(2, '0')}',
        );
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('最新上线'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await capture('${brightness.name}-menu-opening');
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('最多使用')));
      await tester.pumpAndSettle();
      await capture('${brightness.name}-menu-open');
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    }
    debugDisableShadows = originalShadows;
  });
}
