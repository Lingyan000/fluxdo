import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:fluxdo/widgets/festival/festival_motif.dart';
import 'package:fluxdo/widgets/festival/festival_pattern.dart';

import '../helpers/preview_fonts.dart';

/// 节日图案与底纹效果图：FESTIVAL_PREVIEW_DIR=<目录> 时导出，只用于视觉评审。
void main() {
  const dir = String.fromEnvironment('FESTIVAL_PREVIEW_DIR');

  testWidgets('节日图案效果图', (tester) async {
    if (dir.isEmpty) return;
    ThemeRegistry.setFixed([
      for (final f in Directory('assets/themes').listSync().whereType<File>())
        ThemeSpec.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>),
    ]);
    final rows = <(String, ThemeData, ThemeData, FestivalPatternKind)>[];
    for (final id in FestivalMotif.ids) {
      final spec = ThemeRegistry.byId('festival-$id');
      final resolved = ThemeResolver.resolve(
        spec: spec,
        mode: ThemeMode.system,
        black: false,
        seed: Colors.blue,
        variant: DynamicSchemeVariant.tonalSpot,
      );
      final kind = FestivalPatternKind.forFestival(id);
      rows.add((
        id,
        ThemeData(colorScheme: resolved.light),
        ThemeData(colorScheme: resolved.dark),
        kind,
      ));
      for (final s in [resolved.light, resolved.dark]) {
        await tester.runAsync(
          () => FestivalPattern.obtain(kind, _ink(s)),
        );
      }
    }

    tester.view.physicalSize = const Size(1360, 8 * 150 + 20);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: const ValueKey('sheet'),
          child: ColoredBox(
            color: const Color(0xFF808080),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                children: [
                  for (final (id, light, dark, kind) in rows)
                    Row(
                      children: [
                        _Cell(theme: light, id: id, kind: kind),
                        const SizedBox(width: 10),
                        _Cell(theme: dark, id: id, kind: kind),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('sheet')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/festival_motifs.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    ThemeRegistry.setFixed(const []);
  });

  testWidgets('节日图案动画帧', (tester) async {
    if (dir.isEmpty) return;
    ThemeRegistry.setFixed([
      for (final f in Directory('assets/themes').listSync().whereType<File>())
        ThemeSpec.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>),
    ]);
    const frames = 8;
    final rows = <Widget>[];
    for (final id in FestivalMotif.ids) {
      final resolved = ThemeResolver.resolve(
        spec: ThemeRegistry.byId('festival-$id'),
        mode: ThemeMode.system,
        black: false,
        seed: Colors.blue,
        variant: DynamicSchemeVariant.tonalSpot,
      );
      rows.add(
        Theme(
          data: ThemeData(colorScheme: resolved.light),
          child: Container(
            color: resolved.light.surface,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Row(
              children: [
                for (var i = 0; i < frames; i++) ...[
                  FestivalMotif(
                    festivalId: id,
                    size: 72,
                    phase: i / frames,
                    intensity: 1,
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
      );
    }
    tester.view.physicalSize = const Size(frames * 80 + 50, 8 * 84 + 30);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: const ValueKey('frames'),
          child: ColoredBox(
            color: const Color(0xFF808080),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(children: rows),
            ),
          ),
        ),
      ),
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('frames')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/festival_frames.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    ThemeRegistry.setFixed(const []);
  });

  testWidgets('节日装饰场景图', (tester) async {
    if (dir.isEmpty) return;
    await tester.runAsync(() async {
      await loadPreviewCjkFont();
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      for (final entry in manifest) {
        final family = entry['family'] as String;
        if (!family.contains('Material')) continue;
        final loader = FontLoader(family);
        for (final font in entry['fonts'] as List) {
          loader.addFont(rootBundle.load(font['asset'] as String));
        }
        await loader.load();
      }
    });
    ThemeRegistry.setFixed([
      for (final f in Directory('assets/themes').listSync().whereType<File>())
        ThemeSpec.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>),
    ]);
    final cases = [
      ('spring', Brightness.light),
      ('midautumn', Brightness.dark),
      ('dragonboat', Brightness.light),
      ('winter', Brightness.dark),
    ];
    final phones = <Widget>[];
    for (final (id, brightness) in cases) {
      final resolved = ThemeResolver.resolve(
        spec: ThemeRegistry.byId('festival-$id'),
        mode: ThemeMode.system,
        black: false,
        seed: Colors.blue,
        variant: DynamicSchemeVariant.tonalSpot,
      );
      final scheme =
          brightness == Brightness.light ? resolved.light : resolved.dark;
      final kind = FestivalPatternKind.forFestival(id);
      await tester.runAsync(() => FestivalPattern.obtain(kind, _ink(scheme)));
      phones.add(
        Theme(
          data: ThemeData(colorScheme: scheme, fontFamily: 'MiSans'),
          child: _ScenePhone(id: id, kind: kind),
        ),
      );
    }
    tester.view.physicalSize = const Size(4 * 300 + 50, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: const ValueKey('scene'),
          child: ColoredBox(
            color: const Color(0xFF808080),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  for (final phone in phones) ...[
                    phone,
                    const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('scene')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/festival_scene.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
    ThemeRegistry.setFixed(const []);
  });
}

/// 场景：标题栏挂件 + 下拉刷新圆片 + 空状态角标，铺在节日底纹上
class _ScenePhone extends StatelessWidget {
  const _ScenePhone({required this.id, required this.kind});

  final String id;
  final FestivalPatternKind kind;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return SizedBox(
      width: 290,
      height: 620,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            Positioned.fill(
              child: FestivalPatternBackground(
                kind: kind,
                color: s.surface,
                ink: _ink(s),
              ),
            ),
            Column(
              children: [
                const SizedBox(height: 24),
                SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.menu_rounded),
                        color: s.primary,
                        onPressed: () {},
                      ),
                      Text('最新', style: Theme.of(context).textTheme.titleLarge),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: FestivalMotif(festivalId: id, size: 22),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.search_rounded),
                        color: s.primary,
                        onPressed: () {},
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // 下拉刷新圆片
                Material(
                  elevation: 3,
                  shape: const CircleBorder(),
                  color: s.surfaceContainerHigh,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Center(
                      child: FestivalMotif(festivalId: id, size: 30),
                    ),
                  ),
                ),
                Expanded(
                  child: UiDecor(
                    cornerBadge: (_) => FestivalMotif(festivalId: id, size: 26),
                    child: const AppEmptyState(
                      icon: Icon(Icons.notifications_none_rounded),
                      title: '暂无通知',
                      message: '有新的回复和提及时会出现在这里',
                      animate: false,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Color _ink(ColorScheme s) => festivalPatternInk(s);

class _Cell extends StatelessWidget {
  const _Cell({required this.theme, required this.id, required this.kind});

  final ThemeData theme;
  final String id;
  final FestivalPatternKind kind;

  @override
  Widget build(BuildContext context) {
    final s = theme.colorScheme;
    return Theme(
      data: theme,
      child: SizedBox(
        width: 665,
        height: 140,
        child: Row(
          children: [
            Container(
              width: 380,
              color: s.surface,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  FestivalMotif(festivalId: id, size: 24),
                  FestivalMotif(festivalId: id, size: 48),
                  FestivalMotif(festivalId: id, size: 96),
                  // 一次性动效的中间帧
                  FestivalMotif(
                    festivalId: id,
                    size: 48,
                    phase: 0.3,
                    intensity: 1,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 285,
              child: FestivalPatternBackground(
                kind: kind,
                color: s.surface,
                ink: _ink(s),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
