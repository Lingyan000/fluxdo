import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/shortcut_binding.dart';
import 'package:fluxdo/providers/shortcut_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/keyboard_shortcut_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum _RegistrationKind { searchSurface, detailScope, inactiveDetailScope }

class _ShortcutTextFieldHost extends ConsumerStatefulWidget {
  const _ShortcutTextFieldHost({
    required this.kind,
    required this.onClose,
    this.onNext,
  });

  final _RegistrationKind kind;
  final VoidCallback onClose;
  final VoidCallback? onNext;

  @override
  ConsumerState<_ShortcutTextFieldHost> createState() =>
      _ShortcutTextFieldHostState();
}

class _ShortcutTextFieldHostState
    extends ConsumerState<_ShortcutTextFieldHost> {
  ShortcutSurfaceBinding? _surfaceBinding;
  ShortcutScopeBinding? _scopeBinding;
  bool _registrationScheduled = false;

  @override
  void initState() {
    super.initState();
    switch (widget.kind) {
      case _RegistrationKind.searchSurface:
        _surfaceBinding = ShortcutSurfaceBinding(
          ref: ref,
          id: 'test.search',
          triggerAction: ShortcutAction.openSearch,
          kind: ShortcutSurfaceKind.route,
        );
      case _RegistrationKind.detailScope:
        _scopeBinding = ShortcutScopeBinding(
          ref: ref,
          scope: ShortcutScope.detail,
        );
      case _RegistrationKind.inactiveDetailScope:
        // 模拟 IndexedStack 非活跃 tab 的注册:enabled 恒 false
        _scopeBinding = ShortcutScopeBinding(
          ref: ref,
          scope: ShortcutScope.detail,
          enabled: () => false,
        );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_registrationScheduled) return;
    _registrationScheduled = true;
    switch (widget.kind) {
      case _RegistrationKind.searchSurface:
        _surfaceBinding!.registerDeferred(context, onClose: widget.onClose);
      case _RegistrationKind.detailScope:
      case _RegistrationKind.inactiveDetailScope:
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(activePaneProvider.notifier).state = ActivePane.detail;
          _scopeBinding!.register(context, {
            ShortcutAction.closeOverlay: widget.onClose,
            if (widget.onNext != null) ShortcutAction.nextItem: widget.onNext!,
          });
        });
    }
  }

  @override
  void dispose() {
    _surfaceBinding?.dispose();
    _scopeBinding?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: TextField(autofocus: true));
  }
}

Future<void> _pumpShortcutHost(
  WidgetTester tester, {
  required _RegistrationKind kind,
  required VoidCallback onClose,
  VoidCallback? onNext,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final navigatorKey = GlobalKey<NavigatorState>();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: KeyboardShortcutHandler(
        navigatorKey: navigatorKey,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: _ShortcutTextFieldHost(
            kind: kind,
            onClose: onClose,
            onNext: onNext,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => PlatformUtils.debugDesktopOverride = true);
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  testWidgets('搜索页文本框聚焦时 Esc 仍关闭搜索页', (tester) async {
    var closeCalls = 0;
    await _pumpShortcutHost(
      tester,
      kind: _RegistrationKind.searchSurface,
      onClose: () => closeCalls++,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(closeCalls, 1);
  });

  testWidgets('IME 组字期间 Esc 不关闭界面，组字结束后恢复关闭语义', (tester) async {
    var closeCalls = 0;
    await _pumpShortcutHost(
      tester,
      kind: _RegistrationKind.searchSurface,
      onClose: () => closeCalls++,
    );

    // 模拟不合规输入法:组字中（composing 区间有效）Esc 被原样放行到框架
    await tester.showKeyboard(find.byType(TextField));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'nihao',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closeCalls, 0, reason: '组字中 Esc 的语义是取消候选,不能关闭界面');

    // 组字结束（候选上屏/取消,composing 清空）后 Esc 恢复关闭语义
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closeCalls, 1);
  });

  testWidgets('详情文本框只放行 Esc，不抢占可打印字符快捷键', (tester) async {
    var closeCalls = 0;
    var nextCalls = 0;
    await _pumpShortcutHost(
      tester,
      kind: _RegistrationKind.detailScope,
      onClose: () => closeCalls++,
      onNext: () => nextCalls++,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(nextCalls, 0);
    expect(closeCalls, 1);
  });

  testWidgets('活跃面板在 master 时 Esc 回退到 detail 的 closeOverlay', (tester) async {
    var closeCalls = 0;
    var nextCalls = 0;
    await _pumpShortcutHost(
      tester,
      kind: _RegistrationKind.detailScope,
      onClose: () => closeCalls++,
      onNext: () => nextCalls++,
    );

    // 焦点/活跃面板切到左栏列表——master 侧没有注册 closeOverlay,
    // Esc 应回退命中 detail 的关闭回调(关掉右栏);导航动作不回退。
    final element = tester.element(find.byType(TextField));
    final container = ProviderScope.containerOf(element, listen: false);
    container.read(activePaneProvider.notifier).state = ActivePane.master;

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(nextCalls, 0, reason: '导航动作严格按活跃面板分发,不回退');
    expect(closeCalls, 1, reason: 'closeOverlay 在 master 未注册时回退 detail');
  });

  testWidgets('enabled=false 的注册不参与分发(非活跃 tab 不截胡按键)', (tester) async {
    var closeCalls = 0;
    await _pumpShortcutHost(
      tester,
      kind: _RegistrationKind.inactiveDetailScope,
      onClose: () => closeCalls++,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(
      closeCalls,
      0,
      reason: 'IndexedStack 非活跃 tab 的注册必须失效,否则截胡活跃 tab 的 ESC',
    );
  });
}
