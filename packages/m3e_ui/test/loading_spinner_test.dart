import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('LoadingSpinner 完整 morph 周期内正常绘制', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: LoadingSpinner())),
      ),
    );

    // 覆盖多个 650ms morph 周期(含形状指针步进与闭环回绕),
    // 验证 7 段 Morph 的构造与路径生成都不抛错。
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);

    // 自定义尺寸与颜色。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: LoadingSpinner(size: 16, color: Colors.white)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
