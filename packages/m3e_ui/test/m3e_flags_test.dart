import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  test('lerp 容忍 null 与半程翻转', () {
    const on = M3eFlags();
    const off = M3eFlags(enabled: false);
    expect(on.lerp(null, 0.7), same(on));
    expect(on.lerp(off, 0.4), on);
    expect(on.lerp(off, 0.6), off);
    expect(const M3eFlags(), const M3eFlags()); // == 相等性
  });

  testWidgets('of() 未注册时兜底全开', (tester) async {
    late M3eFlags flags;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            flags = M3eFlags.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(flags.enabled, isTrue);
  });

  testWidgets('LoadingSpinner 关闭态回退 CircularProgressIndicator',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [M3eFlags(enabled: false)]),
        home: const Scaffold(body: LoadingSpinner(size: 24)),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 开启态是自绘,无 CPI。
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [M3eFlags()]),
        home: const Scaffold(body: LoadingSpinner(size: 24)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('M3eRefreshIndicator 关闭态回退原生 RefreshIndicator',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [M3eFlags(enabled: false)]),
        home: Scaffold(
          body: M3eRefreshIndicator(
            onRefresh: () async {},
            child: ListView(children: const [SizedBox(height: 1000)]),
          ),
        ),
      ),
    );
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });
}
