import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  testWidgets('确定态进度推进与振幅开合不抛错', (tester) async {
    for (final v in [0.0, 0.05, 0.5, 0.96, 1.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: M3eCircularProgress(value: v))),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('不定态弧追逐多周期不抛错', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: M3eCircularProgress())),
      ),
    );
    // 覆盖多个 1333ms 弧节拍与 2222ms 旋转节拍。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('不定态→确定态切换连续(toast 场景)', (tester) async {
    double? value;
    late StateSetter setter;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setter = setState;
              return Center(child: M3eCircularProgress(value: value));
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    setter(() => value = 0.3);
    await tester.pump(const Duration(milliseconds: 300));
    setter(() => value = 0.97);
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭态回退 CPI(含不定态)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [M3eFlags(enabled: false)]),
        home: const Scaffold(body: M3eCircularProgress()),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
