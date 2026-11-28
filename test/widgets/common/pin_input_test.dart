import 'package:common_ui/common_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late TextEditingController controller;
  late FocusNode focus;

  setUp(() {
    controller = TextEditingController();
    focus = FocusNode();
  });
  tearDown(() {
    controller.dispose();
    focus.dispose();
  });

  Widget app({
    String? status,
    bool reduceMotion = false,
    double textScale = 1,
    double width = 328,
    Brightness brightness = Brightness.light,
  }) => MaterialApp(
    theme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: brightness,
      extensions: const [UiShapes(scale: .5)],
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: reduceMotion,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: PinInput(
            controller: controller,
            focusNode: focus,
            label: '支付密码',
            statusLabel: status,
          ),
        ),
      ),
    ),
  );

  Finder slot(int index) => find.descendant(
    of: find.byType(PinInput),
    matching: find.byKey(ValueKey(index)),
  );

  Finder dotTransform() => find
      .ancestor(of: find.text('•').first, matching: find.byType(Transform))
      .first;

  double dotOpacity(WidgetTester tester, int index) => tester
      .widget<Opacity>(
        find.descendant(of: slot(index), matching: find.byType(Opacity)),
      )
      .opacity;

  double statusOpacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find.ancestor(of: find.text('正在支付…'), matching: find.byType(Opacity)),
      )
      .opacity;

  testWidgets('圆点按弹簧落入，焦点与删除跟随输入且不显示密码', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(app());
    focus.requestFocus();
    await tester.pumpAndSettle();
    controller.text = '1';
    await tester.pump();
    expect(
      tester.widget<Transform>(dotTransform()).transform.getTranslation().y,
      -14,
    );
    await tester.pump(const Duration(milliseconds: 50));
    final expected = SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 520, damping: 16),
      -14,
      0,
      0,
    ).x(.05);
    expect(
      tester.widget<Transform>(dotTransform()).transform.getTranslation().y,
      closeTo(expected, .001),
    );
    await tester.pumpAndSettle();
    final decoration = tester.widget<DecoratedBox>(
      find.descendant(of: slot(1), matching: find.byType(DecoratedBox)),
    );
    final shape =
        (decoration.decoration as ShapeDecoration).shape
            as RoundedSuperellipseBorder;
    expect(shape.side.width, closeTo(2, .001));
    expect(shape.borderRadius.resolve(TextDirection.ltr).topLeft.x, 7);
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.obscureText, isTrue);
    expect(
      find
          .text('1', findRichText: true)
          .evaluate()
          .where((element) => element.widget is Text),
      isEmpty,
    );
    expect(tester.getSemantics(find.byType(EditableText)).value, '•');
    controller.clear();
    await tester.pumpAndSettle();
    expect(dotOpacity(tester, 0), 0);
    expect(tester.getSemantics(find.byType(EditableText)).value, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('六位完成保持输入态，提交才合拢，取消处理后可重新输入', (tester) async {
    await tester.pumpWidget(app());
    controller.text = '123456';
    await tester.pumpAndSettle();
    final before = tester.getRect(slot(0));
    expect(tester.getRect(slot(1)).left - before.right, 8);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await tester.pumpWidget(app(status: '正在支付…'));
    await tester.pump(const Duration(milliseconds: 50));
    final current = tester.getRect(slot(0));
    expect(current.left, greaterThan(before.left));
    expect(current.height, before.height);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(slot(1)).left,
      lessThanOrEqualTo(tester.getRect(slot(0)).right),
    );
    expect(find.text('正在支付…'), findsOneWidget);
    controller.clear();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(tester.getRect(slot(0)), before);
    for (var index = 0; index < 6; index++) {
      expect(dotOpacity(tester, index), 0);
    }
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await tester.enterText(find.byType(TextField), '12a345678');
    await tester.pumpAndSettle();
    expect(controller.text, '123456');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('同位替换保持遮罩，控制器替换与过渡中退出安全', (tester) async {
    await tester.pumpWidget(app());
    controller.text = '1';
    await tester.pumpAndSettle();
    controller.text = '2';
    await tester.pump();
    expect(
      tester.widget<Transform>(dotTransform()).transform.getTranslation().y,
      closeTo(0, .001),
    );
    final previous = controller;
    controller = TextEditingController(text: '3');
    await tester.pumpWidget(app());
    previous.dispose();
    await tester.pumpWidget(app(status: '正在支付…'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('合拢保持遮罩再淡出，控制器立即清空且动画不重建输入框', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(app());
    controller.text = '123456';
    await tester.pumpAndSettle();
    controller.clear();
    await tester.pumpWidget(app(status: '正在支付…'));
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller!.text, isEmpty);
    expect(
      tester.getSemantics(find.byType(PinInput)).toStringDeep(),
      isNot(contains('123456')),
    );
    expect(dotOpacity(tester, 0), 1);
    expect(statusOpacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 150));
    expect(dotOpacity(tester, 0), 1);
    expect(tester.widget<TextField>(find.byType(TextField)), same(input));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump(const Duration(milliseconds: 80));
    expect(dotOpacity(tester, 0), inExclusiveRange(0, 1));
    expect(statusOpacity(tester), inExclusiveRange(0, 1));
    expect(tester.widget<TextField>(find.byType(TextField)), same(input));
    await tester.pumpAndSettle();
    expect(dotOpacity(tester, 0), 0);
    expect(statusOpacity(tester), 1);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('删除后快速重填不闪回起点，退出处理态连续淡出', (tester) async {
    await tester.pumpWidget(app());
    controller.text = '1';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final beforeDelete = dotOpacity(tester, 0);
    controller.clear();
    await tester.pump();
    expect(dotOpacity(tester, 0), closeTo(beforeDelete, .001));
    await tester.pump(const Duration(milliseconds: 40));
    final beforeRefill = dotOpacity(tester, 0);
    final beforeY = tester
        .widget<Transform>(dotTransform())
        .transform
        .getTranslation()
        .y;
    controller.text = '2';
    await tester.pump();
    expect(dotOpacity(tester, 0), closeTo(beforeRefill, .001));
    expect(
      tester.widget<Transform>(dotTransform()).transform.getTranslation().y,
      closeTo(beforeY, .001),
    );
    await tester.pumpAndSettle();
    controller.clear();
    await tester.pumpWidget(app(status: '正在支付…'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app());
    expect(statusOpacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(statusOpacity(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(find.text('正在支付…'), findsNothing);
    expect(dotOpacity(tester, 0), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('合拢中取消再提交不会遗留延时状态', (tester) async {
    await tester.pumpWidget(app());
    controller.text = '123456';
    await tester.pumpAndSettle();
    controller.clear();
    await tester.pumpWidget(app(status: '正在支付…'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 80));
    controller.text = '123456';
    await tester.pumpWidget(app(status: '正在支付…'));
    await tester.pumpAndSettle();
    expect(statusOpacity(tester), 1);
    await tester.pumpWidget(app(reduceMotion: true));
    expect(find.text('正在支付…'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('减少动态效果与窄屏大字 ${brightness.name}', (tester) async {
      await tester.pumpWidget(
        app(
          reduceMotion: true,
          width: 252,
          textScale: 2,
          brightness: brightness,
        ),
      );
      controller.text = '123456';
      await tester.pump();
      expect(
        tester.widget<Transform>(dotTransform()).transform.getTranslation().y,
        0,
      );
      await tester.pumpWidget(
        app(
          status: 'Processing payment…',
          reduceMotion: true,
          width: 252,
          textScale: 2,
          brightness: brightness,
        ),
      );
      final bounds = tester.getRect(slot(0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getRect(slot(0)), bounds);
      expect(
        tester.getRect(slot(1)).left,
        lessThanOrEqualTo(tester.getRect(slot(0)).right),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
