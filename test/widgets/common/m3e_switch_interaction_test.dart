import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('拖动中禁用开关不提交，移除后无悬挂回调', (tester) async {
    var calls = 0;
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (_, active, _) => M3eSwitch(
              value: false,
              onChanged: active ? (_) => calls++ : null,
            ),
          ),
        ),
      ),
    );
    final drag = await tester.startGesture(
      tester.getCenter(find.byType(M3eSwitch)),
    );
    await drag.moveBy(const Offset(25, 0));
    await drag.moveBy(const Offset(20, 0));
    enabled.value = false;
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  Widget host(
    Widget child, {
    bool reduced = false,
    bool enabled = true,
    TextDirection direction = TextDirection.ltr,
  }) => MaterialApp(
    theme: ThemeData(extensions: [M3eFlags(enabled: enabled)]),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: Directionality(textDirection: direction, child: child!),
    ),
    home: Scaffold(body: Center(child: child)),
  );

  Finder thumb() => find
      .descendant(of: find.byType(M3eSwitch), matching: find.byType(Positioned))
      .first;

  testWidgets('占位和原开关一致，按压只改变滑块且取消复原', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: false,
              onChanged: (_) {},
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            M3eSwitch(
              value: false,
              onChanged: (_) => calls++,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
    final size = tester.getSize(find.byType(M3eSwitch));
    expect(size, tester.getSize(find.byType(Switch)));
    final before = tester.getRect(thumb());
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(M3eSwitch)),
    );
    await tester.pump(kPressTimeout);
    await tester.pump(const Duration(milliseconds: 130));
    expect(tester.getRect(thumb()).width, greaterThan(before.width));
    expect(tester.getSize(find.byType(M3eSwitch)), size);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.getRect(thumb()), before);
    expect(calls, 0);
  });

  testWidgets('整行与开关点击各提交一次，横拖不触发行点击或长按', (tester) async {
    var value = false;
    var calls = 0;
    var longPress = 0;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, update) => GestureDetector(
            onLongPress: () => longPress++,
            child: M3eSwitchListTile(
              title: const Text('setting'),
              value: value,
              onChanged: (v) => update(() {
                value = v;
                calls++;
              }),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('setting'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(value, isTrue);
    await tester.tap(find.byType(M3eSwitch));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(value, isFalse);
    final drag = await tester.startGesture(
      tester.getCenter(find.byType(M3eSwitch)),
    );
    await drag.moveBy(const Offset(25, 0));
    await drag.moveBy(const Offset(18, 0));
    await tester.pump(const Duration(milliseconds: 800));
    expect(calls, 2);
    expect(longPress, 0);
    await drag.up();
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(value, isTrue);
  });

  testWidgets('拖动取消、宿主拒绝和第二根手指均不误提交', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(M3eSwitch(value: false, onChanged: (_) => calls++)),
    );
    final start = tester.getCenter(find.byType(M3eSwitch));
    final before = tester.getRect(thumb());
    final drag = await tester.startGesture(start, pointer: 1);
    await drag.moveBy(const Offset(25, 0));
    await drag.moveBy(const Offset(20, 0));
    final extra = await tester.startGesture(start, pointer: 2);
    await extra.moveBy(const Offset(-80, 0));
    await extra.up();
    expect(calls, 0);
    await drag.cancel();
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(tester.getRect(thumb()), before);
    await tester.tap(find.byType(M3eSwitch));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.getRect(thumb()), before, reason: '宿主未接受新值');
  });

  testWidgets('竖向滑动仍滚动页面，不切换开关', (tester) async {
    var calls = 0;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      host(
        ListView(
          controller: scroll,
          children: [
            const SizedBox(height: 200),
            M3eSwitchListTile(
              title: const Text('setting'),
              value: false,
              onChanged: (_) => calls++,
            ),
            const SizedBox(height: 1200),
          ],
        ),
      ),
    );
    await tester.drag(find.byType(M3eSwitch), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(50));
    expect(calls, 0);
  });

  testWidgets('RTL 拖动、键盘和无障碍开关语义可用', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final semantics = tester.ensureSemantics();
    var value = false;
    var calls = 0;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, update) => M3eSwitch(
            value: value,
            focusNode: focus,
            semanticLabel: 'test switch',
            onChanged: (v) => update(() {
              value = v;
              calls++;
            }),
          ),
        ),
        reduced: true,
        direction: TextDirection.rtl,
      ),
    );
    final drag = await tester.startGesture(
      tester.getCenter(find.byType(M3eSwitch)),
    );
    await drag.moveBy(const Offset(-25, 0));
    await drag.moveBy(const Offset(-18, 0));
    await drag.up();
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(
      tester.getSemantics(find.bySemanticsLabel('test switch')),
      matchesSemantics(
        label: 'test switch',
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(value, isFalse);
    expect(calls, 2);
    semantics.dispose();
  });

  testWidgets('禁用不响应，关闭 M3E 自动回退原开关', (tester) async {
    await tester.pumpWidget(
      host(const M3eSwitch(value: false, onChanged: null)),
    );
    await tester.tap(find.byType(M3eSwitch));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      host(
        M3eSwitchListTile(
          value: false,
          onChanged: (_) {},
          title: const Text('setting'),
        ),
        enabled: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
  });
}
