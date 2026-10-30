import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_anchor.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_panel.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_workbench.dart';

import 'composer_interaction_test.dart' show pumpApp;

Future<ComposerToolsAnchor> pumpToolbar(
  WidgetTester tester, {
  required Brightness brightness,
  required Size size,
  bool reducedMotion = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final anchor = ComposerToolsAnchor();
  await pumpApp(
    tester,
    Builder(
      builder: (context) => Theme(
        data: ThemeData(brightness: brightness),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: reducedMotion,
            textScaler: const TextScaler.linear(1.5),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ComposerWorkbench(
                toolsAnchor: anchor,
                controls: const [],
                onExpandTools: () => anchor.expand([
                  ComposerToolAction(
                    id: 'bold',
                    label: '粗体',
                    icon: const Icon(Icons.format_bold),
                    run: () {},
                  ),
                ], const []),
                tools: SizedBox(
                  width: double.infinity,
                  child: ComposerCompactTools(
                    anchor: anchor,
                    child: const Icon(Icons.format_bold),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    desktop: false,
  );
  await tester.pumpAndSettle();
  return anchor;
}

void main() {
  for (final brightness in Brightness.values) {
    for (final size in [const Size(375, 760), const Size(760, 375)]) {
      testWidgets('玻璃与按钮随展开进度变化，反向不中断 $brightness $size', (tester) async {
        final anchor = await pumpToolbar(
          tester,
          brightness: brightness,
          size: size,
        );
        final surface = find.byType(GlassSurface);
        final originalState = tester.state(surface);
        GlassRecipe recipe() => tester.widget<GlassSurface>(surface).recipe;
        double compactOpacity() => tester
            .widget<Opacity>(
              find.byKey(const ValueKey('composer-compact-visibility')),
            )
            .opacity;
        expect(recipe(), same(GlassRecipe.toolbar));
        await tester.tap(find.byKey(const ValueKey('composer-tools-handle')));
        await tester.pump();
        expect(recipe(), same(GlassRecipe.toolbar), reason: '展开通知不能立即切换材质');
        expect(compactOpacity(), 1, reason: '按钮从原位置淡出，首帧不消失');
        await tester.pump(const Duration(milliseconds: 16));
        expect(compactOpacity(), inExclusiveRange(0, 1));
        final partial = recipe();
        expect(partial.blurSigmaPx, inExclusiveRange(32, 64));
        expect(
          partial.tintAlphaFor(brightness == Brightness.dark),
          inExclusiveRange(
            GlassRecipe.toolbar.tintAlphaFor(brightness == Brightness.dark),
            GlassRecipe.sheet.tintAlphaFor(brightness == Brightness.dark),
          ),
        );
        anchor.collapse();
        await tester.pump();
        expect(
          recipe().blurSigmaPx,
          partial.blurSigmaPx,
          reason: '收起从当前材质接续，不提前切回工具栏配方',
        );
        anchor.reopen();
        await tester.pump();
        expect(recipe().blurSigmaPx, partial.blurSigmaPx);
        var previous = partial.blurSigmaPx;
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(recipe().blurSigmaPx, greaterThanOrEqualTo(previous));
          previous = recipe().blurSigmaPx;
        }
        expect(recipe(), same(GlassRecipe.sheet));
        expect(compactOpacity(), 0);
        anchor.collapse();
        await tester.pump();
        expect(recipe(), same(GlassRecipe.sheet), reason: '收起首帧同样保持材质');
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(recipe().blurSigmaPx, lessThanOrEqualTo(previous));
          previous = recipe().blurSigmaPx;
        }
        expect(recipe(), same(GlassRecipe.toolbar));
        expect(compactOpacity(), 1);
        expect(tester.state(surface), same(originalState), reason: '复用单一玻璃表面');
        expect(anchor.presenting, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        anchor.dispose();
      });
    }

    testWidgets('减少动态效果时直接完成展开收起 $brightness', (tester) async {
      final anchor = await pumpToolbar(
        tester,
        brightness: brightness,
        size: const Size(375, 760),
        reducedMotion: true,
      );
      await tester.tap(find.byKey(const ValueKey('composer-tools-handle')));
      await tester.pump();
      expect(
        tester.widget<GlassSurface>(find.byType(GlassSurface)).recipe,
        same(GlassRecipe.sheet),
      );
      anchor.collapse();
      await tester.pump();
      expect(
        tester.widget<GlassSurface>(find.byType(GlassSurface)).recipe,
        same(GlassRecipe.toolbar),
      );
      expect(anchor.presenting, isFalse);
      expect(anchor.animation, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      anchor.dispose();
    });
  }
}
