/// 编辑器撤销/恢复:源码模式工具栏按钮。
///
/// 移动端无物理键盘,Cmd/Ctrl+Z 不可达 —— 工具栏按钮是唯一入口,
/// 故这里断言的是「按钮存在 + 可用性随历史栈变化 + 点击真的改文本」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:fluxdo/widgets/markdown_editor/content_actions_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpEditor(
  WidgetTester tester, {
  required TextEditingController controller,
  required FocusNode focusNode,
}) async {
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          locale: const Locale('zh'),
          navigatorKey: navigatorKey,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: MarkdownEditor(
              controller: controller,
              focusNode: focusNode,
              hintText: '',
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openActions(WidgetTester tester) async {
  await tester.tap(find.byType(ContentActionsButton));
  await tester.pumpAndSettle();
}

Finder _action(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(PopupMenuItem<int>),
);
bool _enabled(WidgetTester tester, Finder finder) =>
    tester.widget<PopupMenuItem<int>>(finder).enabled;

void main() {
  setUp(() => PlatformUtils.debugDesktopOverride = false);
  tearDown(() => PlatformUtils.debugDesktopOverride = null);
  testWidgets('源码模式:撤销/恢复按钮常驻,可用性随历史栈变化', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await _pumpEditor(tester, controller: controller, focusNode: focusNode);

    final undoBtn = _action('撤销');
    final redoBtn = _action('恢复');

    await _openActions(tester);
    expect(undoBtn, findsOneWidget, reason: '撤销按钮常驻工具栏');
    expect(redoBtn, findsOneWidget, reason: '恢复按钮常驻工具栏');

    // 空文档:两侧都不可用(置灰而非隐藏 —— 位置恒定不雪崩位移)
    expect(_enabled(tester, undoBtn), isFalse);
    expect(_enabled(tester, redoBtn), isFalse);

    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();

    // 输入一段文本(平台路径),等 UndoHistory 的 500ms 节流入栈。
    // 聚焦后先等一个节流窗口 —— UndoHistory 在 initState/聚焦时压入的
    // "空基线"和紧随其后的输入会被同一个节流定时器合并(框架行为),
    // 基线不落栈就撤不回空文档。真实用户「聚焦→思考→打字」天然跨窗口。
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 600));
    tester.testTextInput.enterText('hello');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await _openActions(tester);
    expect(_enabled(tester, undoBtn), isTrue, reason: '有编辑后可撤销');
    expect(_enabled(tester, redoBtn), isFalse, reason: '未撤销前无可恢复');
  });

  testWidgets('源码模式:点撤销回退文本,点恢复重新前进', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await _pumpEditor(tester, controller: controller, focusNode: focusNode);

    await tester.showKeyboard(find.byType(TextField));
    // 两个编辑节点,中间留足节流间隔各自成步
    tester.testTextInput.enterText('hello');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    tester.testTextInput.enterText('hello world');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.text, 'hello world');

    final undoBtn = _action('撤销');
    final redoBtn = _action('恢复');

    await _openActions(tester);
    await tester.tap(undoBtn);
    await tester.pump();
    expect(controller.text, 'hello', reason: '撤销回到上一步');
    await tester.pumpAndSettle();
    await _openActions(tester);
    expect(_enabled(tester, redoBtn), isTrue, reason: '撤销后可恢复');

    await tester.tap(redoBtn);
    await tester.pump();
    expect(controller.text, 'hello world', reason: '恢复重新前进');
  });
}
