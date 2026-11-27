import 'package:common_ui/common_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_style.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _testTheme({
  ThemeStyle style = ThemeStyle.material,
  Brightness brightness = Brightness.light,
}) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3366CC),
    brightness: brightness,
  );
  return buildAppTheme(
    scheme,
    AppColors.material(brightness),
    UiShapes.standard,
    const ThemeState(mode: ThemeMode.light, seedColor: Color(0xFF3366CC)),
    fullscreenSwipeBack: false,
    pageBackground: false,
    style: style,
  );
}

void main() {
  group('AppDropdown', () {
    testWidgets('展开附着菜单、选择选项并关闭', (tester) async {
      String? selected = 'a';
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) => SizedBox(
                  width: 240,
                  child: AppDropdown<String>(
                    value: selected,
                    isExpanded: true,
                    items: const [
                      AppDropdownItem(value: 'a', label: '选项 A'),
                      AppDropdownItem(
                        value: 'b',
                        label: '选项 B',
                        subtitle: '辅助说明',
                      ),
                      AppDropdownItem(
                        value: 'c',
                        label: '禁用项',
                        enabled: false,
                      ),
                    ],
                    onChanged: (v) => setState(() => selected = v),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('选项 A'), findsOneWidget);
      await tester.tap(find.text('选项 A'));
      await tester.pumpAndSettle();

      // 菜单已展开，包含禁用项与副标题
      expect(find.text('选项 B'), findsOneWidget);
      expect(find.text('辅助说明'), findsOneWidget);
      expect(find.text('禁用项'), findsOneWidget);

      // 点击禁用项不关闭菜单也不更改值
      await tester.tap(find.text('禁用项'));
      await tester.pumpAndSettle();
      expect(selected, 'a');
      expect(find.text('选项 B'), findsOneWidget);

      // 点击选项 B 选中并关闭
      await tester.tap(find.text('选项 B'));
      await tester.pumpAndSettle();
      expect(selected, 'b');
      expect(find.text('辅助说明'), findsNothing);
    });

    testWidgets('compact 模式与空白处点击关闭正常工作', (tester) async {
      var selected = 'relevance';
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(
            style: const ThemeStyle(
              surfaces: SurfaceStyle.flat,
              controls: ControlStyle.ink,
              inputs: InputStyle.underline,
              shadows: false,
            ),
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: StatefulBuilder(
                  builder: (context, setState) => AppDropdown<String>(
                    value: selected,
                    compact: true,
                    items: const [
                      AppDropdownItem(value: 'relevance', label: '相关性'),
                      AppDropdownItem(value: 'latest', label: '最新发布'),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => selected = v);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('相关性'));
      await tester.pumpAndSettle();
      expect(find.text('最新发布'), findsOneWidget);

      // 点击空白区域取消关闭
      await tester.tapAt(const Offset(500, 500));
      await tester.pumpAndSettle();
      expect(find.text('最新发布'), findsNothing);
      expect(selected, 'relevance');
    });

    testWidgets('支持键盘方向键导航与回车确认', (tester) async {
      var selected = 'first';
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) => AppDropdown<String>(
                  value: selected,
                  items: const [
                    AppDropdownItem(value: 'first', label: '第一项'),
                    AppDropdownItem(value: 'second', label: '第二项'),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => selected = v);
                  },
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('第一项'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(selected, 'second');
    });

    testWidgets('展开与收起过程中触发器及自适应弹框尺寸零抖动', (tester) async {
      const sheetKey = ValueKey('sheet-box');
      const dropdownKey = ValueKey('engine-dropdown');
      const siblingKey = ValueKey('target-dropdown');
      var engine = 'ai';
      var target = 'zh';

      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                key: sheetKey,
                padding: const EdgeInsets.all(16),
                child: StatefulBuilder(
                  builder: (context, setState) => Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          AppDropdown<String>(
                            key: dropdownKey,
                            value: engine,
                            isDense: true,
                            items: const [
                              AppDropdownItem(value: 'ai', label: 'AI 翻译'),
                              AppDropdownItem(value: 'google', label: 'Google'),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => engine = v);
                            },
                          ),
                          AppDropdown<String>(
                            key: siblingKey,
                            value: target,
                            isDense: true,
                            items: const [
                              AppDropdownItem(value: 'zh', label: '简体中文'),
                              AppDropdownItem(value: 'en', label: 'English'),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => target = v);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 120),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final initialSheet = tester.getRect(find.byKey(sheetKey));
      final initialDropdown = tester.getRect(find.byKey(dropdownKey));
      final initialSibling = tester.getRect(find.byKey(siblingKey));

      await tester.tap(find.byKey(dropdownKey));
      await tester.pump(const Duration(milliseconds: 70));
      expect(tester.getRect(find.byKey(sheetKey)), initialSheet);
      expect(tester.getRect(find.byKey(dropdownKey)), initialDropdown);
      expect(tester.getRect(find.byKey(siblingKey)), initialSibling);

      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(sheetKey)), initialSheet);
      expect(tester.getRect(find.byKey(dropdownKey)), initialDropdown);
      expect(tester.getRect(find.byKey(siblingKey)), initialSibling);

      // 点击空白处收起，同样不得发生尺寸变化
      await tester.tapAt(const Offset(10, 10));
      await tester.pump(const Duration(milliseconds: 70));
      expect(tester.getRect(find.byKey(sheetKey)), initialSheet);
      expect(tester.getRect(find.byKey(dropdownKey)), initialDropdown);
      expect(tester.getRect(find.byKey(siblingKey)), initialSibling);

      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(sheetKey)), initialSheet);
      expect(tester.getRect(find.byKey(dropdownKey)), initialDropdown);
      expect(tester.getRect(find.byKey(siblingKey)), initialSibling);
    });
  });

  group('AppDropdownFormField', () {
    testWidgets('支持可空值选择、表单校验与主题输入框风格', (tester) async {
      final formKey = GlobalKey<FormState>();
      String? value;
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme(
            style: const ThemeStyle(inputs: InputStyle.outlined),
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: formKey,
                child: AppDropdownFormField<String?>(
                  initialValue: value,
                  decoration: const InputDecoration(labelText: '指派状态'),
                  items: const [
                    AppDropdownItem(value: null, label: '未设置'),
                    AppDropdownItem(value: 'open', label: '处理中'),
                  ],
                  validator: (v) => v == null ? '请选择状态' : null,
                  onChanged: (v) => value = v,
                ),
              ),
            ),
          ),
        ),
      );

      expect(formKey.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('请选择状态'), findsOneWidget);

      await tester.tap(find.text('未设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('处理中'));
      await tester.pumpAndSettle();

      expect(value, 'open');
      expect(formKey.currentState!.validate(), isTrue);
    });
  });
}
