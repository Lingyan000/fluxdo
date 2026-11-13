import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_anchored_panel.dart';

void main() {
  testWidgets('浮层在键盘、安全区和尺寸约束变化后重新布局', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late StateSetter update;
    var insets = EdgeInsets.zero;
    var padding = const EdgeInsets.only(top: 48);
    Rect? viewport;
    var width = 320.0;
    var maxHeight = 440.0;
    const panelKey = ValueKey('panel-content');

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(viewPadding: padding, viewInsets: insets),
              child: ComposerAnchoredSurface(
                anchor: const Rect.fromLTWH(16, 100, 40, 40),
                animation: const AlwaysStoppedAnimation(1),
                fitBesideAnchor: false,
                viewport: viewport,
                width: width,
                maxHeight: maxHeight,
                child: const SizedBox(
                  key: panelKey,
                  height: 1000,
                  child: Text('测试菜单项'),
                ),
              ),
            );
          },
        ),
      ),
    );

    void expectPanel(Size size, Rect bounds) {
      expect(tester.takeException(), isNull);
      final panel = find.byKey(panelKey);
      expect(tester.getSize(panel), size);
      final rect = tester.getRect(panel);
      expect(rect.left, greaterThanOrEqualTo(bounds.left));
      expect(rect.top, greaterThanOrEqualTo(bounds.top));
      expect(rect.right, lessThanOrEqualTo(bounds.right));
      expect(rect.bottom, lessThanOrEqualTo(bounds.bottom));
    }

    expectPanel(const Size(320, 440), const Rect.fromLTRB(8, 56, 392, 792));
    update(() => insets = const EdgeInsets.only(bottom: 500));
    await tester.pump();
    expectPanel(const Size(320, 236), const Rect.fromLTRB(8, 56, 392, 292));

    update(() => insets = EdgeInsets.zero);
    await tester.pump();
    expectPanel(const Size(320, 440), const Rect.fromLTRB(8, 56, 392, 792));

    update(() => viewport = const Rect.fromLTRB(0, 100, 400, 300));
    await tester.pump();
    expectPanel(const Size(320, 184), const Rect.fromLTRB(8, 108, 392, 292));

    update(() {
      viewport = null;
      padding = const EdgeInsets.only(top: 48, left: 100, right: 100);
    });
    await tester.pump();
    expectPanel(const Size(184, 440), const Rect.fromLTRB(108, 56, 292, 792));

    update(() {
      width = 120;
      maxHeight = 160;
    });
    await tester.pump();
    expectPanel(const Size(120, 160), const Rect.fromLTRB(108, 56, 292, 792));
  });

  for (final scenario in ['nested', 'keyboard', 'large-text']) {
    testWidgets('anchored panel bounds and actions: $scenario', (tester) async {
      final landscape = scenario == 'keyboard';
      tester.view.physicalSize = landscape
          ? const Size(844, 390)
          : const Size(800, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final anchorKey = GlobalKey();
      final viewportKey = GlobalKey();
      int? chosen;
      Widget content() => Builder(
        builder: (context) => Stack(
          children: [
            Positioned(
              left: 16,
              top: 80,
              width: 40,
              height: 40,
              child: Builder(
                key: anchorKey,
                builder: (buttonContext) => IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () async {
                    final box = buttonContext.findRenderObject() as RenderBox;
                    chosen = await showComposerAnchoredPanel<int>(
                      context: context,
                      globalAnchor: box.localToGlobal(Offset.zero) & box.size,
                      builder: (menu) => Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < 12; i++)
                            TextButton(
                              onPressed: () => Navigator.of(menu).pop(i),
                              child: Text('Action $i'),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: scenario == 'large-text',
              textScaler: TextScaler.linear(scenario == 'large-text' ? 2 : 1),
              viewInsets: EdgeInsets.only(bottom: landscape ? 120 : 0),
            ),
            child: child!,
          ),
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: scenario == 'nested'
                ? Center(
                    child: SizedBox(
                      key: viewportKey,
                      width: 350,
                      height: 300,
                      child: Navigator(
                        onGenerateRoute: (_) =>
                            MaterialPageRoute<void>(builder: (_) => content()),
                      ),
                    ),
                  )
                : SizedBox.expand(key: viewportKey, child: content()),
          ),
        ),
      );
      await tester.tap(find.byKey(anchorKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      final panel = find.byKey(const ValueKey('composer-anchored-panel'));
      final bounds = tester.getRect(panel);
      final viewport = tester.getRect(find.byKey(viewportKey));
      expect(bounds.left, greaterThanOrEqualTo(viewport.left + 8));
      expect(bounds.right, lessThanOrEqualTo(viewport.right - 8));
      expect(bounds.top, greaterThanOrEqualTo(viewport.top + 8));
      expect(
        bounds.bottom,
        lessThanOrEqualTo(viewport.bottom - (landscape ? 128 : 8)),
      );
      await tester.drag(panel, const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(find.text('Action 11').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Action 11'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(chosen, 11);
      expect(panel, findsNothing);
      await tester.tap(find.byKey(anchorKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(panel, findsNothing);
    });
  }
}
