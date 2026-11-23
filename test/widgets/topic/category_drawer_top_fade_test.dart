import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/tag_search_result.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/theme/app_colors.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_style.dart';
import 'package:fluxdo/widgets/common/top_fade_scrim.dart';
import 'package:fluxdo/widgets/topic/category_drawer.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/input_field_shell.dart';

class _SignedOutUser extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;
}

void main() {
  final sampleCategories = [
    for (var i = 1; i <= 25; i++)
      Category(
        id: i,
        name: '分类 $i',
        color: '3B82F6',
        textColor: 'FFFFFF',
        slug: 'cat-$i',
      ),
  ];

  final sampleTagGroups = [
    SiteTagGroup(
      name: '分组一',
      tags: [
        for (var i = 1; i <= 10; i++)
          TagInfo(name: 'alpha-$i', text: 'alpha-$i', count: 100 - i),
      ],
    ),
    SiteTagGroup(
      name: '分组二',
      tags: [
        for (var i = 1; i <= 10; i++)
          TagInfo(name: 'beta-$i', text: 'beta-$i', count: 80 - i),
      ],
    ),
    SiteTagGroup(
      name: '分组三',
      tags: [
        for (var i = 1; i <= 10; i++)
          TagInfo(name: 'gamma-$i', text: 'gamma-$i', count: 60 - i),
      ],
    ),
  ];

  Future<void> pumpDrawer(WidgetTester tester, {ThemeData? theme}) async {
    await tester.binding.setSurfaceSize(const Size(390, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          categoriesProvider.overrideWith((_) async => sampleCategories),
          siteTagGroupsProvider.overrideWith((_) async => sampleTagGroups),
          currentUserProvider.overrideWith(_SignedOutUser.new),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            theme: theme,
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(390, 700),
                padding: EdgeInsets.only(top: 44, bottom: 20),
              ),
              child: Scaffold(
                body: CategoryDrawer(
                  onPinnedSelected: (_) {},
                  onRequestClose: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  AnimatedOpacity findScrimOpacity(WidgetTester tester) {
    final scrimFinder = find.byType(TopFadeScrim);
    expect(scrimFinder, findsOneWidget);
    return tester.widget<AnimatedOpacity>(
      find.ancestor(of: scrimFinder, matching: find.byType(AnimatedOpacity)),
    );
  }

  TopFadeScrim findScrim(WidgetTester tester) {
    return tester.widget<TopFadeScrim>(find.byType(TopFadeScrim));
  }

  testWidgets('分类页签静止时遮罩透明，滚动后淡入且滚回顶部归零', (tester) async {
    await pumpDrawer(tester);

    expect(findScrimOpacity(tester).opacity, 0.0);
    final categoryScrim = findScrim(tester);
    expect(categoryScrim.solidHeight, closeTo(44.0, 1.0));

    // 向下浏览（手指上滑）让内容进入悬浮头部下方
    await tester.drag(find.byType(ListView).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(findScrimOpacity(tester).opacity, 1.0);

    // 滚回顶部后遮罩淡出
    await tester.drag(find.byType(ListView).first, const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(findScrimOpacity(tester).opacity, 0.0);
  });

  testWidgets('切到标签页签后重置遮罩并自适应多行头部高度，横滑组导航不误触发遮罩', (tester) async {
    await pumpDrawer(tester);

    final categoryScrimHeight = findScrim(tester).height;

    // 先在分类页滚出遮罩
    await tester.drag(find.byType(ListView).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(findScrimOpacity(tester).opacity, 1.0);

    // 切到标签页签：遮罩自动归零，且遮罩高度扩大以覆盖搜索框和组导航
    await tester.tap(find.text(S.current.tag_tabTags));
    await tester.pumpAndSettle();
    expect(findScrimOpacity(tester).opacity, 0.0);

    final tagScrim = findScrim(tester);
    expect(tagScrim.height, greaterThan(categoryScrimHeight + 60));
    expect(tagScrim.solidHeight, greaterThan(44.0));

    // 横滑组导航不触发垂直滚动遮罩
    await tester.drag(find.text('分组二'), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(findScrimOpacity(tester).opacity, 0.0);

    // 点击「分组三」跳转后，列表滚动并触发顶栏渐隐遮罩
    await tester.tap(find.text('分组三'));
    await tester.pumpAndSettle();
    expect(findScrimOpacity(tester).opacity, 1.0);
  });

  final searchCapsule = find.ancestor(
    of: find.byType(TextField),
    matching: find.byWidgetPredicate(
      (widget) => widget is Material && widget.clipBehavior == Clip.antiAlias,
    ),
  );

  for (final inputs in InputStyle.values) {
    testWidgets('$inputs 标签搜索胶囊跟随输入框主题', (tester) async {
      const seed = Color(0xFFB9532F);
      final theme = buildAppTheme(
        ColorScheme.fromSeed(seedColor: seed),
        AppColors.material(Brightness.light),
        UiShapes.standard,
        const ThemeState(mode: ThemeMode.light, seedColor: seed),
        fullscreenSwipeBack: false,
        pageBackground: false,
        style: ThemeRegistry.minimal.style.copyWith(inputs: inputs),
      );
      await pumpDrawer(tester, theme: theme);
      await tester.tap(find.text(S.current.tag_tabTags));
      await tester.pumpAndSettle();

      final field = find.byType(TextField);
      Material capsule() => tester.widget<Material>(searchCapsule);
      final inputTheme = theme.inputDecorationTheme;
      final outline = RoundedSuperellipseBorder(
        borderRadius: UiShapes.standard.borderRadius(20),
      );
      void expectStroke(InputBorder? themeBorder) {
        expectInputShellStroke(
          stroke: capsule().shape!,
          outline: outline,
          size: tester.getSize(searchCapsule),
          themeBorder: themeBorder,
        );
      }

      final enabledShape = capsule().shape;
      if (inputs == InputStyle.filled) {
        expect(enabledShape, isA<RoundedSuperellipseBorder>());
        final side = (enabledShape! as RoundedSuperellipseBorder).side;
        expect(side.color.a, 0);
      } else {
        expectStroke(inputTheme.enabledBorder);
        await tester.drag(find.byType(ListView).first, const Offset(0, -180));
        await tester.pumpAndSettle();
        expect(findScrimOpacity(tester).opacity, 1.0);
        expectStroke(inputTheme.enabledBorder);
      }
      expect(tester.getRect(searchCapsule), tester.getRect(field));

      final decorator = find.descendant(
        of: field,
        matching: find.byType(InputDecorator),
      );
      expect(
        tester.widget<InputDecorator>(decorator).decoration.enabledBorder,
        InputBorder.none,
      );

      await tester.tap(field);
      await tester.pumpAndSettle();
      final focused = tester.widget<InputDecorator>(decorator);
      expect(focused.isFocused, isTrue);
      expect(focused.decoration.focusedBorder, InputBorder.none);
      if (inputs == InputStyle.filled) {
        expect(capsule().shape, enabledShape);
      } else {
        expectStroke(inputTheme.focusedBorder);
      }

      await tester.enterText(field, 'beta');
      await tester.pumpAndSettle();
      expect(find.text('beta-1'), findsOneWidget);
      expect(find.text('alpha-1'), findsNothing);
      expect(tester.widget<InputDecorator>(decorator).isFocused, isTrue);

      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pumpAndSettle();
      expect(capsule().shape, enabledShape);
    });
  }

  testWidgets('标签搜索框所在胶囊保留滚动阴影', (tester) async {
    await pumpDrawer(tester);
    await tester.tap(find.text(S.current.tag_tabTags));
    await tester.pumpAndSettle();

    expect(tester.widget<Material>(searchCapsule).elevation, 0);
    await tester.drag(find.byType(ListView).first, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(tester.widget<Material>(searchCapsule).elevation, greaterThan(0));
  });
}
