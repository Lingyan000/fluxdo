/// 手机端 composer 滚动流回归:header(标题/元数据)注入 MarkdownEditor
/// 滚动容器后 —— header 与正文同滚、下方空白点击聚焦(旧 expands 整区
/// 可点行为)、光标越界时跟随外层滚动。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Widget> _wrap(Widget child) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: TranslationProvider(
      child: MaterialApp(
        locale: const Locale('zh'),
        navigatorKey: navigatorKey,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: AppLocaleUtils.supportedLocales,
        home: Scaffold(body: child),
      ),
    ),
  );
}

double _outerScrollOffset(WidgetTester tester) {
  final scrollView = tester.widget<CustomScrollView>(
    find.byType(CustomScrollView),
  );
  return scrollView.controller!.position.pixels;
}

void main() {
  testWidgets('header 与正文同一滚动流:上滑后 header 离场', (tester) async {
    final controller = TextEditingController(
      text: List.generate(120, (i) => '正文第 $i 行').join('\n'),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      await _wrap(
        MarkdownEditor(
          controller: controller,
          expands: true,
          header: const SizedBox(height: 120, child: Text('HEADER')),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('HEADER'), findsOneWidget);
    final before = tester.getTopLeft(find.text('HEADER')).dy;

    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -200),
      warnIfMissed: false,
    );
    await tester.pump();

    // header 必须随正文一起上移(固定头部时代它纹丝不动)
    expect(_outerScrollOffset(tester), greaterThan(0));
    final headerFinder = find.text('HEADER', skipOffstage: false);
    if (headerFinder.evaluate().isNotEmpty) {
      expect(tester.getTopLeft(headerFinder).dy, lessThan(before));
    }
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('正文下方空白点击 → 聚焦并光标置末', (tester) async {
    final controller = TextEditingController(text: 'abc');
    final focus = FocusNode();
    addTearDown(() {
      controller.dispose();
      focus.dispose();
    });

    await tester.pumpWidget(
      await _wrap(
        MarkdownEditor(
          controller: controller,
          focusNode: focus,
          expands: true,
          header: const SizedBox(height: 60, child: Text('HEADER')),
        ),
      ),
    );
    await tester.pump();

    expect(focus.hasFocus, isFalse);

    // TextField 只占内容高,其下方是空白填充区 —— 点它必须等价
    // "点在正文末尾"(外滚化前 expands TextField 整区可点的行为)
    final area = tester.getRect(find.byType(CustomScrollView));
    await tester.tapAt(Offset(area.center.dx, area.bottom - 100));
    await tester.pump();

    expect(focus.hasFocus, isTrue, reason: '空白区点击必须能唤起输入');
    expect(controller.selection.baseOffset, controller.text.length);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('光标越界时跟随外层滚动(打字换行不失焦点位)', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(() {
      controller.dispose();
      focus.dispose();
    });

    await tester.pumpWidget(
      await _wrap(
        MarkdownEditor(
          controller: controller,
          focusNode: focus,
          expands: true,
          header: const SizedBox(height: 80, child: Text('HEADER')),
        ),
      ),
    );
    await tester.pump();

    // 聚焦后灌入超过一屏的文本(IME 路径,光标置末)——外滚化后
    // EditableText 自己的 showCaretOnScreen 管不到外层,靠
    // _scrollToCursor 手动跟随
    await tester.tap(find.byType(TextField), warnIfMissed: false);
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      List.generate(120, (i) => '第 $i 行').join('\n'),
    );
    await tester.pump(); // postFrame 里计算越界
    await tester.pump(const Duration(milliseconds: 300)); // animateTo 完成

    expect(
      _outerScrollOffset(tester),
      greaterThan(0),
      reason: '光标在视口下方时外层滚动必须跟随',
    );
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('无 header(回复弹框形态)回归:点击聚焦正常', (tester) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(() {
      controller.dispose();
      focus.dispose();
    });

    await tester.pumpWidget(
      await _wrap(
        MarkdownEditor(
          controller: controller,
          focusNode: focus,
          expands: true,
        ),
      ),
    );
    await tester.pump();

    final area = tester.getRect(find.byType(CustomScrollView));
    await tester.tapAt(area.center);
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.pump(const Duration(seconds: 1));
  });
}
