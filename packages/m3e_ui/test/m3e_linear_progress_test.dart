import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('不定态多周期绘制不抛错', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: M3eLinearProgress())),
      ),
    );
    // 覆盖 1750ms 双线周期多轮(含回绕)。
    for (var i = 0; i < 45; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('确定态进度推进与振幅开合不抛错', (tester) async {
    for (final v in [0.0, 0.05, 0.3, 0.7, 0.96, 1.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: M3eLinearProgress(value: v))),
        ),
      );
      // 覆盖振幅 500ms 过渡与波形滚动。
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('M3E 关闭时回退 LinearProgressIndicator', (tester) async {
    final theme = ThemeData(
      extensions: const [M3eFlags(enabled: false)],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(body: M3eLinearProgress(value: 0.5)),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
