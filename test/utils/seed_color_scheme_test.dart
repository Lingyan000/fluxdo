import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/utils/seed_color_scheme.dart';

void main() {
  setUp(SeedColorScheme.resetCache);

  test('相同入参复用同一个 ColorScheme 实例', () {
    final first = SeedColorScheme.from(seedColor: Colors.blue);
    final second = SeedColorScheme.from(seedColor: Colors.blue);

    expect(identical(first, second), isTrue);
    expect(SeedColorScheme.cachedCount, 1);
  });

  test('亮暗与配色风格分别成键', () {
    SeedColorScheme.from(seedColor: Colors.blue);
    SeedColorScheme.from(seedColor: Colors.blue, brightness: Brightness.dark);
    SeedColorScheme.from(
      seedColor: Colors.blue,
      variant: DynamicSchemeVariant.vibrant,
    );

    expect(SeedColorScheme.cachedCount, 3);
  });

  test('结果与 ColorScheme.fromSeed 一致', () {
    const seed = Color(0xFF116682);
    const variant = DynamicSchemeVariant.expressive;

    final cached = SeedColorScheme.from(
      seedColor: seed,
      brightness: Brightness.dark,
      variant: variant,
    );
    final expected = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      dynamicSchemeVariant: variant,
    );

    expect(cached, expected);
  });

  test('超过上限后清空，不会无限增长', () {
    for (var i = 0; i <= SeedColorScheme.maxEntries; i++) {
      SeedColorScheme.from(seedColor: Color(0xFF000000 + i));
    }

    expect(SeedColorScheme.cachedCount, lessThanOrEqualTo(
      SeedColorScheme.maxEntries,
    ));
  });
}
