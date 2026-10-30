import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/nested/nested_reading_scope.dart';

void main() {
  testWidgets('已构建的屏外后代和折叠帖不计入已读，锚点按屏幕位置而非楼层号', (tester) async {
    final viewport = NestedViewportController();
    final scroll = ScrollController();
    Set<int> visible = {};
    int? anchor;
    viewport.onSample = (posts, position) {
      visible = posts;
      anchor = position?.postNumber;
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: SingleChildScrollView(
              key: viewport.viewportKey,
              controller: scroll,
              child: Column(
                children: [
                  NestedPostAnchor(
                    controller: viewport,
                    postNumber: 100,
                    rootPostNumber: 100,
                    child: const SizedBox(height: 200, width: 300),
                  ),
                  NestedPostAnchor(
                    controller: viewport,
                    postNumber: 20,
                    rootPostNumber: 100,
                    child: const SizedBox(height: 200, width: 300),
                  ),
                  NestedPostAnchor(
                    controller: viewport,
                    postNumber: 21,
                    rootPostNumber: 100,
                    trackRead: false,
                    child: const SizedBox(height: 200, width: 300),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    viewport.sample();
    expect(visible, {100});
    expect(anchor, 100);
    scroll.jumpTo(200);
    await tester.pump();
    viewport.sample();
    expect(visible, {20});
    expect(anchor, 20);
    scroll.jumpTo(400);
    await tester.pump();
    viewport.sample();
    expect(visible, isEmpty);
    expect(anchor, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    viewport.dispose();
  });

  testWidgets('长帖中段保存负偏移，布局变化后仍测量真实位置', (tester) async {
    final viewport = NestedViewportController();
    final scroll = ScrollController();
    double? offset;
    viewport.onSample = (_, position) => offset = position?.offset;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: SingleChildScrollView(
              key: viewport.viewportKey,
              controller: scroll,
              child: NestedPostAnchor(
                controller: viewport,
                postNumber: 3,
                rootPostNumber: 2,
                child: const SizedBox(height: 1000, width: 300),
              ),
            ),
          ),
        ),
      ),
    );
    scroll.jumpTo(350);
    await tester.pump();
    viewport.sample();
    expect(offset, closeTo(-350, 0.1));
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    viewport.dispose();
  });
}
