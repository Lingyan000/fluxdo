import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_anchored_panel.dart';

void main() {
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
