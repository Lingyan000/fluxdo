/// 复现:富文本 → 源码切换后 TextField 能否正常输入/删除。
/// 结构照宿主页:共享 controller+focusNode,AnimatedSwitcher 150ms。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/widgets/markdown_editor/markdown_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Host extends StatefulWidget {
  const _Host({required this.controller, required this.focusNode});
  final TextEditingController controller;
  final FocusNode focusNode;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool rich = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        TextButton(
          onPressed: () => setState(() => rich = false),
          child: const Text('SWITCH'),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: rich
                // 简化的"富态占位":真 RichComposer 依赖 cook 引擎,测试
                // 环境起不来;关键变量是 focusNode 已聚焦 + controller
                // selection 状态,由下面手工制造
                ? const SizedBox.expand(key: ValueKey('rich'))
                : MarkdownEditor(
                    key: const ValueKey('md'),
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    hintText: '',
                  ),
          ),
        ),
      ]),
    );
  }
}

void main() {
  testWidgets('切换后(flush 致 selection=-1)输入与退格仍有效',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(ProviderScope(
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
          home: _Host(controller: controller, focusNode: focusNode),
        ),
      ),
    ));

    // 制造切换前状态:焦点在共享 node 上(富文本态),flush 回写文本
    // (TextEditingController.text setter → selection = collapsed(-1))
    focusNode.requestFocus();
    await tester.pump();
    controller.text = 'hello world';
    expect(controller.selection.isValid, isFalse, reason: 'flush 后选区无效');

    await tester.tap(find.text('SWITCH'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200)); // 动画完

    // 用户点正文
    await tester.tap(find.byType(TextField).last);
    await tester.pump();

    // 平台键入
    await tester.showKeyboard(find.byType(TextField).last);
    tester.testTextInput.enterText('hello worldX');
    await tester.pump();
    expect(controller.text, 'hello worldX', reason: '能输入');

    // 退格(平台路径:直接回灌删一位后的值)
    tester.testTextInput.enterText('hello world');
    await tester.pump();
    expect(controller.text, 'hello world', reason: '能删除');
  });

  testWidgets('程序化聚焦(无 tap):平台收到的选区必须有效',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(ProviderScope(
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
          home: _Host(controller: controller, focusNode: focusNode),
        ),
      ),
    ));

    // 旧 flush 缺陷路径:text setter → selection = collapsed(-1)。
    // 真实 flushToController 已改原子赋值(选区合法),这里故意保留
    // -1 制造最坏情况,验证平台侧最终看到的选区仍必须合法。
    controller.text = 'hello world';
    expect(controller.selection.isValid, isFalse);

    await tester.tap(find.text('SWITCH'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 程序化聚焦(reply_sheet 的 requestFocus 流,无 tap 落点)
    tester.testTextInput.log.clear();
    focusNode.requestFocus();
    await tester.pump();

    // 断言:发给平台的编辑状态选区有效(-1 会让 Android IME 的
    // deleteSurroundingText 永远无效 = 真机"无法删除")
    final states = tester.testTextInput.log
        .where((c) => c.method == 'TextInput.setEditingState')
        .toList();
    expect(states, isNotEmpty, reason: '聚焦即 attach 并喂状态');
    final last = (states.last.arguments as Map).cast<String, dynamic>();
    expect(last['selectionBase'], greaterThanOrEqualTo(0),
        reason: '平台侧选区必须有效');
  });
}
