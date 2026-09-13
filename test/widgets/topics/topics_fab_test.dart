import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/shortcut_binding.dart';
import 'package:fluxdo/providers/shortcut_provider.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/preferences_provider.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/widgets/keyboard_shortcut_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/pages/topics_page.dart' show barVisibilityProvider;
import 'package:fluxdo/widgets/topics/topics_fab.dart';

void main() {
  final trigger = find.byKey(const ValueKey('topics-create-menu'));
  final refresh = find.byKey(const ValueKey('topics-refresh'));
  final items = find.byType(FilledButton);
  late int refreshCount;
  late int createCount;
  late int draftsCount;
  late ProviderContainer container;
  late GlobalKey<NavigatorState> navigatorKey;

  setUp(() async {
    navigatorKey = GlobalKey<NavigatorState>();
    SharedPreferences.setMockInitialValues({'pref_home_refresh_button': true});
    final prefs = await SharedPreferences.getInstance();
    refreshCount = createCount = draftsCount = 0;
    container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
  });
  tearDown(() => container.dispose());

  Future<void> pumpFab(
    WidgetTester tester, {
    bool canCreate = true,
    bool isActive = true,
    double textScale = 1,
    bool disableAnimations = false,
    Size screen = const Size(390, 844),
    double? paneWidth,
    bool settle = true,
    bool mimicTabTicker = false,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: KeyboardShortcutHandler(
          navigatorKey: navigatorKey,
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              home: MediaQuery(
                data: MediaQueryData(
                  size: screen,
                  padding: const EdgeInsets.only(bottom: 80),
                  viewPadding: const EdgeInsets.only(bottom: 24),
                  textScaler: TextScaler.linear(textScale),
                  disableAnimations: disableAnimations,
                ),
                child: Scaffold(
                  body: SizedBox(
                    width: paneWidth ?? screen.width,
                    height: screen.height,
                    child: Stack(
                      children: [
                        const Positioned(left: 20, top: 20, child: Text('列表')),
                        Positioned(
                          right: 16,
                          bottom: 40,
                          child: TickerMode(
                            enabled: !mimicTabTicker || isActive,
                            child: TopicsFab(
                              canCreate: canCreate,
                              isActive: isActive,
                              onRefresh: () => refreshCount++,
                              onCreateTopic: () => createCount++,
                              onOpenDrafts: () => draftsCount++,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('刷新独立触发，底栏变化不改变主按钮功能', (tester) async {
    await pumpFab(tester);
    expect(items, findsNothing);
    final barrierCount = find.byType(ModalBarrier).evaluate().length;
    await tester.tap(refresh);
    expect(refreshCount, 1);
    final before = tester.getCenter(trigger);
    container.read(barVisibilityProvider.notifier).state = 0;
    await tester.pumpAndSettle();
    expect(tester.getCenter(trigger).dy - before.dy, 56);
    expect(trigger.hitTestable(), findsNothing);
    container.read(barVisibilityProvider.notifier).state = 1;
    await tester.pumpAndSettle();
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(items, findsNWidgets(2));
    expect(refresh.hitTestable(), findsNothing);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ModalBarrier), findsNWidgets(barrierCount));
    expect(tester.takeException(), isNull);
  });

  testWidgets('菜单整块可点击且右对齐，发帖和草稿各触发一次', (tester) async {
    await pumpFab(tester);
    final before = tester.getCenter(trigger);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(tester.getCenter(trigger), before);
    for (final item in items.evaluate()) {
      final rect = tester.getRect(find.byWidget(item.widget));
      expect(rect.height, greaterThanOrEqualTo(56));
      expect(rect.right, 374);
      expect(rect.bottom, lessThan(tester.getTopLeft(trigger).dy));
    }
    await tester.tap(items.last);
    await tester.pumpAndSettle();
    expect(createCount, 1);
    expect(items, findsNothing);
    expect(refresh.hitTestable(), findsOneWidget);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tap(items.first);
    await tester.pumpAndSettle();
    expect(draftsCount, 1);
    expect(refreshCount, 0);
  });

  testWidgets('外部点击、ESC 和返回均收起菜单', (tester) async {
    await pumpFab(tester);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(30, 30));
    await tester.pumpAndSettle();
    expect(items, findsNothing);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(items, findsNothing);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final context = tester.element(trigger);
    await Navigator.of(context).maybePop();
    await tester.pumpAndSettle();
    expect(items, findsNothing);
    expect(trigger, findsOneWidget);
  });

  testWidgets('快速开合不残留菜单，非活跃和卸载时自动清理', (tester) async {
    await pumpFab(tester);
    await tester.tap(trigger);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(trigger);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(items, findsNWidgets(2));
    await pumpFab(tester, isActive: false);
    expect(items, findsNothing);
    await pumpFab(tester);
    await tester.tap(trigger);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登录保留刷新，大字体和减少动画仍可使用菜单', (tester) async {
    await pumpFab(tester, canCreate: false);
    expect(trigger, findsNothing);
    await tester.tap(refresh);
    expect(refreshCount, 1);
    await pumpFab(tester, textScale: 2, disableAnimations: true);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(items, findsNWidgets(2));
    for (final item in items.evaluate()) {
      final rect = tester.getRect(find.byWidget(item.widget));
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.top, greaterThan(0));
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('访客直接卸载不在 dispose 创建 ticker', (tester) async {
    await pumpFab(tester, canCreate: false);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面全局快捷键不会穿透菜单关闭详情或打开话题', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);
    await pumpFab(tester);
    var detailClosed = 0;
    var topicOpened = 0;
    final registry = container.read(shortcutScopeRegistryProvider.notifier);
    final owner = Object();
    registry.register(
      scope: ShortcutScope.detail,
      owner: owner,
      route: ModalRoute.of(tester.element(trigger)),
      callbacks: {
        ShortcutAction.closeOverlay: () => detailClosed++,
        ShortcutAction.openItem: () => topicOpened++,
      },
    );
    container.read(activePaneProvider.notifier).state = ActivePane.detail;
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(items, findsNothing);
    expect(detailClosed, 0);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    Focus.of(
      tester.element(
        find.text(
          Translations.of(tester.element(trigger)).topicsScreen_createTopic,
        ),
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(createCount, 1);
    expect(topicOpened, 0);
    expect(items, findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(
      container.read(shortcutSurfaceRegistryProvider).registrations,
      isEmpty,
    );
  });
  double opacity(WidgetTester tester, [String id = 'create']) => tester
      .widget<Opacity>(find.byKey(ValueKey('topics-$id-appearance-opacity')))
      .opacity;

  double scale(WidgetTester tester) => tester
      .widget<Transform>(
        find.byKey(const ValueKey('topics-create-appearance-scale')),
      )
      .transform
      .storage[0];

  testWidgets('入场从中心缩放淡入，活跃切换反向退场且滚动不重播', (tester) async {
    await pumpFab(tester, settle: false);
    expect(opacity(tester), 0);
    expect(scale(tester), 0);
    final center = tester.getCenter(trigger);
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester), inExclusiveRange(0, 1));
    expect(scale(tester), inExclusiveRange(0, 1));
    expect(tester.getCenter(trigger), center);
    await tester.pumpAndSettle();
    expect(opacity(tester), 1);
    await pumpFab(tester, isActive: false, settle: false);
    expect(trigger.hitTestable(), findsNothing);
    await tester.pump(const Duration(milliseconds: 90));
    expect(opacity(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(opacity(tester), 0);
    await pumpFab(tester, settle: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    container.read(barVisibilityProvider.notifier).state = 0.4;
    await tester.pump();
    expect(opacity(tester), closeTo(0.4, 0.001));
    expect(scale(tester), closeTo(0.4, 0.001));
    expect(opacity(tester, 'refresh'), closeTo(0.4, 0.001));
    container.read(barVisibilityProvider.notifier).state = 1;
    await tester.pump();
    expect(opacity(tester), 1);
  });

  testWidgets('底栏切换禁用 ticker 后快速返回仍重播入场', (tester) async {
    await pumpFab(tester, mimicTabTicker: true);
    await pumpFab(tester, isActive: false, mimicTabTicker: true, settle: false);
    await tester.pump(const Duration(milliseconds: 20));
    await pumpFab(tester, mimicTabTicker: true, settle: false);
    expect(opacity(tester), lessThan(1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(opacity(tester), 1);
  });

  testWidgets('滚动隐藏立即清理菜单，恢复时不自动展开', (tester) async {
    await pumpFab(tester);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    container.read(barVisibilityProvider.notifier).state = 0.7;
    await tester.pumpAndSettle();
    expect(items, findsNothing);
    expect(trigger.hitTestable(), findsNothing);
    expect(
      container.read(shortcutSurfaceRegistryProvider).registrations,
      isEmpty,
    );
    container.read(barVisibilityProvider.notifier).state = 0;
    await tester.pump();
    expect(opacity(tester), 0);
    container.read(barVisibilityProvider.notifier).state = 1;
    await tester.pump();
    expect(trigger.hitTestable(), findsOneWidget);
    expect(items, findsNothing);
  });

  testWidgets('关闭滚动隐藏时与底栏同样恒显，宽屏不跟随不存在的底栏', (tester) async {
    await pumpFab(tester);
    await container
        .read(preferencesProvider.notifier)
        .setHideBarOnScroll(false);
    container.read(barVisibilityProvider.notifier).state = 0.4;
    await tester.pump();
    expect(opacity(tester), 1);
    container.read(barVisibilityProvider.notifier).state = 0;
    await tester.pump();
    expect(opacity(tester), 0);
    await pumpFab(tester, screen: const Size(1000, 800));
    expect(opacity(tester), 1);
  });

  testWidgets('刷新开关实时生效且不移动主按钮', (tester) async {
    await pumpFab(tester);
    final center = tester.getCenter(trigger);
    await container
        .read(preferencesProvider.notifier)
        .setHomeRefreshButton(false);
    await tester.pump();
    expect(refresh, findsNothing);
    expect(tester.getCenter(trigger), center);
    await container
        .read(preferencesProvider.notifier)
        .setHomeRefreshButton(true);
    await tester.pump();
    expect(refresh, findsOneWidget);
    expect(tester.getCenter(trigger), center);
  });

  testWidgets('减少动画直接显示与隐藏，不播放缩放', (tester) async {
    await pumpFab(tester, disableAnimations: true, settle: false);
    expect(opacity(tester), 1);
    expect(scale(tester), 1);
    await pumpFab(
      tester,
      disableAnimations: true,
      isActive: false,
      settle: false,
    );
    expect(opacity(tester), 0);
    expect(scale(tester), 1);
    await pumpFab(tester, disableAnimations: true, settle: false);
    expect(opacity(tester), 1);
  });

  testWidgets('push 覆盖时退场，pop 回列表时重新入场', (tester) async {
    await pumpFab(tester);
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('详情'))),
    );
    await tester.pumpAndSettle();
    expect(trigger.hitTestable(), findsNothing);
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(opacity(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(opacity(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄 master 与横屏大字体菜单不越界且可以滚动', (tester) async {
    await pumpFab(
      tester,
      screen: const Size(1000, 390),
      paneWidth: 240,
      textScale: 2,
    );
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final scroll = find.byType(SingleChildScrollView);
    final rect = tester.getRect(scroll);
    expect(rect.left, greaterThanOrEqualTo(16));
    expect(rect.right, lessThanOrEqualTo(224));
    expect(rect.top, greaterThanOrEqualTo(16));
    await tester.drag(scroll, const Offset(0, 150));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
