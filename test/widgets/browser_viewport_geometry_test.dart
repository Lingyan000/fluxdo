import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/browser_safe_area.dart';
import 'package:fluxdo/widgets/browser/browser_web_viewport.dart';

void main() {
  testWidgets('父布局隐藏或部分收起工具栏时自动重算，普通网页只避让一次', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    var top = 110.0;
    var bottom = 80.0;
    var cover = true;
    var padding = const EdgeInsets.only(top: 44, bottom: 24);
    var unsafe = EdgeInsets.zero;
    final reports = <BrowserViewportGeometry>[];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Stack(
              children: [
                Positioned.fill(
                  top: top,
                  bottom: bottom,
                  child: BrowserWebViewport(
                    window: const Rect.fromLTWH(0, 0, 390, 844),
                    systemPadding: padding,
                    observeGeometry: true,
                    unsafe: unsafe,
                    edgeToEdge: cover,
                    top: Colors.white,
                    bottom: Colors.white,
                    onGeometryChanged: (geometry) {
                      reports.add(geometry);
                      if (unsafe != geometry.unsafe) {
                        setState(() => unsafe = geometry.unsafe);
                      }
                    },
                    child: const SizedBox.expand(key: ValueKey('web-content')),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(unsafe, EdgeInsets.zero);

    update(() => top = 20);
    await tester.pumpAndSettle();
    expect(unsafe, const EdgeInsets.only(top: 24));
    update(() => top = 0);
    await tester.pumpAndSettle();
    expect(unsafe, const EdgeInsets.only(top: 44));
    update(() {
      top = 110;
      bottom = 0;
    });
    await tester.pumpAndSettle();
    expect(unsafe, const EdgeInsets.only(bottom: 24));
    update(() => top = 0);
    await tester.pumpAndSettle();
    expect(unsafe, padding);

    // 无 cover 的网页由应用留边；观察的是外框，内部留边不引起反复重算。
    update(() => cover = false);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('web-content'))),
      const Rect.fromLTRB(0, 44, 390, 820),
    );
    final count = reports.length;
    await tester.pump(const Duration(seconds: 1));
    expect(reports.length, count);

    update(() => padding = const EdgeInsets.only(top: 28));
    await tester.pumpAndSettle();
    expect(unsafe, const EdgeInsets.only(top: 28));
    expect(tester.getRect(find.byKey(const ValueKey('web-content'))).top, 28);
  });
}
