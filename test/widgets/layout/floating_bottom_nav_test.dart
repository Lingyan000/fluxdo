import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/layout/adaptive_navigation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 悬浮胶囊底栏的几何与选中态回归。
///
/// 几何：item 高 48（无字 40）+ 内边距 4×2，距屏底 8、距左右 12。
/// 比 Telegram 的 56 紧凑 —— 参考设计实测 pill 高 ≈36dp，
/// 悬浮形态的关键是「压实」。
void main() {
  const screen = Size(390, 844);
  const safeBottom = 34.0;

  Future<void> pumpBar(
    WidgetTester tester, {
    required bool labelless,
    double textScale = 1.0,
    int count = 5,
    int selectedIndex = 0,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      'pref_bottom_nav_floating': true,
      'pref_bottom_nav_labelless': labelless,
      'pref_bottom_nav_floating_blur': true,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: screen,
              padding: const EdgeInsets.only(bottom: safeBottom),
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              extendBody: true,
              bottomNavigationBar: AdaptiveBottomNavigation(
                selectedIndex: selectedIndex,
                onDestinationSelected: (_) {},
                destinations: [
                  for (var i = 0; i < count; i++)
                    AdaptiveDestination(
                      id: 'id$i',
                      icon: const Icon(Icons.home_outlined),
                      selectedIcon: const Icon(Icons.home),
                      label: '标签$i',
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 胶囊本体（ClipRRect 是最外层裁切，等于胶囊可见范围）
  RenderBox capsuleOf(WidgetTester tester) =>
      tester.renderObject<RenderBox>(find.byType(ClipRRect).first);

  testWidgets('带字态胶囊高 56，贴屏底 8 / 距左右 12', (tester) async {
    await pumpBar(tester, labelless: false);
    final box = capsuleOf(tester);
    expect(box.size.height, 56, reason: 'item 48 + inset 4×2');
    final topLeft = box.localToGlobal(Offset.zero);
    expect(topLeft.dx, 12, reason: '左外边距（TG iOS sideInset）');
    expect(
      screen.height - (topLeft.dy + box.size.height),
      safeBottom + 8,
      reason: '安全区之外再让 8（TG 双端一致）',
    );
  });

  testWidgets('无字态胶囊收到 48 高', (tester) async {
    await pumpBar(tester, labelless: true);
    expect(capsuleOf(tester).size.height, 48, reason: 'item 40 + inset 4×2');
  });

  testWidgets('大字号下带字态高度上浮，不裁标签', (tester) async {
    await pumpBar(tester, labelless: false, textScale: 2.0);
    expect(
      capsuleOf(tester).size.height,
      greaterThan(56),
      reason: '标签行高超出基准时补偿高度',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('无字态高度不随字号变化', (tester) async {
    await pumpBar(tester, labelless: true, textScale: 2.0);
    expect(capsuleOf(tester).size.height, 48);
  });

  testWidgets('宽屏不铺满：胶囊宽度受上限约束并居中', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({
      'pref_bottom_nav_floating': true,
      'pref_bottom_nav_floating_blur': true,
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(1200, 900)),
            child: Scaffold(
              extendBody: true,
              bottomNavigationBar: AdaptiveBottomNavigation(
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                destinations: [
                  for (var i = 0; i < 5; i++)
                    AdaptiveDestination(
                      id: 'id$i',
                      icon: const Icon(Icons.home_outlined),
                      selectedIcon: const Icon(Icons.home),
                      label: '标签$i',
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final box = capsuleOf(tester);
    expect(box.size.width, lessThan(1200), reason: '宽屏不拉满');
    final left = box.localToGlobal(Offset.zero).dx;
    expect(
      left,
      closeTo((1200 - box.size.width) / 2, 0.5),
      reason: '水平居中悬浮',
    );
  });

  testWidgets('选中 pill 铺满整个条目槽位（非 M3 的只包图标短胶囊）', (tester) async {
    const count = 5;
    await pumpBar(tester, labelless: false, count: count);

    final capsule = capsuleOf(tester);
    // pill 是 StadiumBorder 的 DecoratedBox；条目的墨水层也用 StadiumBorder，
    // 这里按尺寸筛出 pill（宽 = 槽宽、高 = item 高）
    final itemHeight = capsule.size.height - 4 * 2;
    final slot = (capsule.size.width - 4 * 2) / count;

    final pill = find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final d = w.decoration;
      return d is ShapeDecoration && d.shape is StadiumBorder;
    });
    expect(pill, findsWidgets);

    final pillBox = tester.renderObject<RenderBox>(pill.first);
    expect(pillBox.size.width, closeTo(slot, 0.5), reason: 'pill 宽 = 槽宽');
    expect(
      pillBox.size.height,
      closeTo(itemHeight, 0.5),
      reason: 'pill 满高铺满条目（含标签），不是只包图标',
    );
  });

  testWidgets('槽宽随 item 高等比缩放：pill 比例恒定 1.6', (tester) async {
    final pill = find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final d = w.decoration;
      return d is ShapeDecoration && d.shape is StadiumBorder;
    });

    // 入口数少到不触发宽度压缩（5 项在 390 宽下会被 maxWidth 压窄）
    await pumpBar(tester, labelless: false, count: 3);
    final labeled = tester.renderObject<RenderBox>(pill.first).size;
    expect(
      labeled.width / labeled.height,
      closeTo(1.6, 0.02),
      reason: '带字态槽宽 = item 高 × 1.6',
    );

    await pumpBar(tester, labelless: true, count: 3);
    final bare = tester.renderObject<RenderBox>(pill.first).size;
    expect(
      bare.width / bare.height,
      closeTo(1.6, 0.02),
      reason: '无字态同比例 —— 槽宽不是硬编码常量，随高一起收',
    );
    expect(
      bare.width,
      lessThan(labeled.width),
      reason: '无字态更矮，槽宽也应更窄',
    );
  });

  testWidgets('切换选中项时 pill 滑动到新槽位', (tester) async {
    await pumpBar(tester, labelless: false, selectedIndex: 0);
    final pill = find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final d = w.decoration;
      return d is ShapeDecoration && d.shape is StadiumBorder;
    });
    final startX = tester
        .renderObject<RenderBox>(pill.first)
        .localToGlobal(Offset.zero)
        .dx;

    await pumpBar(tester, labelless: false, selectedIndex: 3);
    final endX = tester
        .renderObject<RenderBox>(pill.first)
        .localToGlobal(Offset.zero)
        .dx;

    expect(endX, greaterThan(startX), reason: 'pill 随选中项右移');
  });
}
