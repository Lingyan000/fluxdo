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

enum _RegistrationKind { searchSurface, detailScope }

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
}
