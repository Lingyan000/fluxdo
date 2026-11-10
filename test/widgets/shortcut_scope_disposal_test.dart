import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/shortcut_binding.dart';
import 'package:fluxdo/providers/shortcut_provider.dart';
import 'package:fluxdo/utils/platform_utils.dart';

class _Pane extends ConsumerStatefulWidget {
  const _Pane();

  @override
  ConsumerState<_Pane> createState() => _PaneState();
}

class _PaneState extends ConsumerState<_Pane> {
  late final _binding = PaneHostEscBinding(ref: ref);

  @override
  Widget build(BuildContext context) {
    _binding.sync(context, paneOpen: false);
    return const SizedBox();
  }

  @override
  void dispose() {
    _binding.dispose();
    super.dispose();
  }
}

void main() {
  setUp(() => PlatformUtils.debugDesktopOverride = true);
  tearDown(() => PlatformUtils.debugDesktopOverride = null);

  testWidgets('销毁双栏宿主时安全注销 ESC，不在 unmount 期间通知 provider', (tester) async {
    final visible = ValueNotifier(true);
    final container = ProviderContainer();
    addTearDown(visible.dispose);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(shortcutScopeRegistryProvider);
              return ValueListenableBuilder(
                valueListenable: visible,
                builder: (_, value, _) =>
                    value ? const _Pane() : const SizedBox(),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final registered = container.read(shortcutScopeRegistryProvider);
    expect(registered.context, hasLength(1));
    expect(registered.context.values.single.isEnabled, true);
    visible.value = false;
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(registered.context.values.single.isEnabled, false);
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.read(shortcutScopeRegistryProvider).context, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('延迟注销前禁止再次注册，ProviderScope 销毁后跳过通知', (tester) async {
    late ShortcutScopeBinding binding;
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (context, ref, _) {
            binding = ShortcutScopeBinding(
              ref: ref,
              scope: ShortcutScope.detail,
            );
            container = ProviderScope.containerOf(context, listen: false);
            return const SizedBox();
          },
        ),
      ),
    );
    binding.registerForRoute(null, {ShortcutAction.closeOverlay: () {}});
    binding.disposeDeferred();
    binding.registerForRoute(null, {ShortcutAction.nextItem: () {}});
    expect(
      container
          .read(shortcutScopeRegistryProvider)
          .detail
          .values
          .single
          .callbacks
          .keys,
      [ShortcutAction.closeOverlay],
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.takeException(), isNull);
  });
}
