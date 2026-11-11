import 'package:common_ui/common_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/app_localizations.dart';
import 'package:fluxdo/providers/message_bus/models.dart';
import 'package:fluxdo/providers/message_bus/notification_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/shape_presets.dart';
import 'package:fluxdo/widgets/common/skeleton.dart';
import 'package:fluxdo/widgets/common/notification_icon_button.dart';
import 'package:m3e_ui/m3e_ui.dart';

ThemeData _theme(
  ShapePreset preset,
  Brightness brightness, {
  bool m3e = true,
}) => buildAppTheme(
  ColorScheme.fromSeed(seedColor: Colors.teal, brightness: brightness),
  AppColors.material(brightness),
  preset.shapes,
  ThemeState(mode: ThemeMode.light, seedColor: Colors.teal, m3eEnabled: m3e),
  fullscreenSwipeBack: false,
  pageBackground: false,
);

BorderRadius _radius(ShapeBorder? shape) =>
    (shape! as RoundedSuperellipseBorder).borderRadius.resolve(
      TextDirection.ltr,
    );

class _NotificationCounts extends NotificationCountNotifier {
  @override
  NotificationCountState build() => const NotificationCountState(allUnread: 3);
}

void main() {
  testWidgets('通知图标在顶栏区域用强调色、在侧栏用次要色，徽标继续显示', (tester) async {
    for (final brightness in Brightness.values) {
      final theme = _theme(ShapePreset.standard, brightness);
      for (final topBar in [true, false]) {
        const button = NotificationIconButton(compact: true);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              notificationCountStateProvider.overrideWith(
                _NotificationCounts.new,
              ),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                theme: theme,
                home: Scaffold(
                  body: topBar ? const TopBarIconScope(child: button) : button,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final icon = tester.element(find.byIcon(Symbols.notifications_rounded));
        expect(
          IconTheme.of(icon).color,
          topBar
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        );
        expect(find.text('3'), findsOneWidget);
      }
    }
  });
  for (final preset in ShapePreset.values) {
    for (final brightness in Brightness.values) {
      for (final glass in [true, false]) {
        testWidgets('列表、玻璃、骨架、按钮组和导航跟随 $preset / $brightness / glass=$glass', (
          tester,
        ) async {
          final theme = _theme(preset, brightness);
          // 有意不更新全局 current，验证局部 Theme 和预览也能正确换角。
          final oldShapes = UiShapes.current;
          UiShapes.current = UiShapes.standard;
          addTearDown(() => UiShapes.current = oldShapes);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: GlassSettingsScope(
                settings: GlassSettings(
                  enabled: glass,
                  level: GlassEffectLevel.basic,
                ),
                child: Scaffold(
                  appBar: AppBar(
                    actions: [
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.search),
                      ),
                    ],
                  ),
                  body: Column(
                    children: [
                      const SegmentedCardGroup(
                        children: [
                          ListTile(
                            leading: Icon(Icons.folder),
                            title: Text('first'),
                          ),
                          ListTile(title: Text('last')),
                        ],
                      ),
                      const SizedBox(
                        width: 200,
                        height: 48,
                        child: GlassSurfaceFrame(
                          radius: 24,
                          child: SizedBox.expand(),
                        ),
                      ),
                      const SkeletonBox(
                        width: 120,
                        height: 32,
                        borderRadius: 12,
                      ),
                      M3eButtonGroup<int>(
                        selected: 0,
                        items: const [
                          M3eButtonGroupItem(value: 0, label: Text('one')),
                          M3eButtonGroupItem(value: 1, label: Text('two')),
                        ],
                        onSelected: (_) {},
                      ),
                    ],
                  ),
                  bottomNavigationBar: M3eNavigationBar(
                    selectedIndex: 0,
                    onDestinationSelected: (_) {},
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home),
                        label: 'home',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.person),
                        label: 'user',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final shapes = preset.shapes;
          final rows = tester
              .widgetList<Material>(
                find.descendant(
                  of: find.byType(SegmentedCardItem),
                  matching: find.byType(Material),
                ),
              )
              .toList();
          expect(_radius(rows.first.shape).topLeft, shapes.radius(20));
          expect(_radius(rows.first.shape).bottomLeft, shapes.radius(5));
          expect(_radius(rows.last.shape).bottomLeft, shapes.radius(20));
          final surface = tester.widget<GlassSurface>(
            find.byType(GlassSurface),
          );
          expect(_radius(surface.shape), shapes.borderRadius(24));
          expect(surface.fallbackBorderRadius, shapes.resolve(24));
          final clip = tester.widget<ClipRSuperellipse>(
            find
                .descendant(
                  of: find.byType(GlassSurfaceFrame),
                  matching: find.byType(ClipRSuperellipse),
                )
                .first,
          );
          expect(clip.borderRadius, shapes.borderRadius(24));
          final skeleton = tester.widget<Container>(
            find.descendant(
              of: find.byType(SkeletonBox),
              matching: find.byType(Container),
            ),
          );
          expect(
            _radius((skeleton.decoration as ShapeDecoration).shape),
            shapes.borderRadius(12),
          );
          final group = tester
              .widgetList<Material>(
                find.descendant(
                  of: find.byType(M3eButtonGroup<int>),
                  matching: find.byType(Material),
                ),
              )
              .toList();
          expect(_radius(group.first.shape).topLeft, shapes.radius(24));
          expect(_radius(group.last.shape).topLeft, shapes.radius(8));
          final indicator = tester
              .widgetList<Container>(
                find.descendant(
                  of: find.byType(M3eNavigationBar),
                  matching: find.byType(Container),
                ),
              )
              .where((c) => c.decoration is ShapeDecoration)
              .first;
          expect(
            _radius((indicator.decoration as ShapeDecoration).shape),
            shapes.borderRadius(9999),
          );
          expect(
            IconTheme.of(tester.element(find.byIcon(Icons.search))).color,
            theme.colorScheme.primary,
          );
          expect(
            IconTheme.of(tester.element(find.byIcon(Icons.folder))).color,
            theme.colorScheme.primary,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  test('已构建主题的按钮状态不被其他主题的全局圆角污染', () {
    for (final m3e in [true, false]) {
      final standard = _theme(ShapePreset.standard, Brightness.light, m3e: m3e);
      final sharp = _theme(ShapePreset.sharp, Brightness.dark, m3e: m3e);
      for (final states in [
        <WidgetState>{},
        {WidgetState.pressed},
        {WidgetState.selected},
      ]) {
        expect(
          _radius(sharp.iconButtonTheme.style!.shape!.resolve(states))
              .topLeft
              .x,
          lessThanOrEqualTo(3),
        );
        expect(
          _radius(standard.iconButtonTheme.style!.shape!.resolve(states))
              .topLeft
              .x,
          greaterThan(3),
        );
      }
    }
  });
}
