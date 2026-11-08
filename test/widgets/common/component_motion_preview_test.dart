import 'dart:io';
import 'dart:ui' as ui;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:m3e_ui/m3e_ui.dart';

/// 用真实组件输出预览：flutter test --dart-define=COMPONENT_PREVIEW=true ...
void main() {
  testWidgets('公共组件动效预览', (tester) async {
    if (!const bool.fromEnvironment('COMPONENT_PREVIEW')) return;
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSansVF.ttf'))).load();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(440, 880);
    addTearDown(tester.view.reset);
    final boundary = GlobalKey();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    var enabled = true;
    var sequence = 0;
    final output = Directory('build/component-motion-preview')
      ..createSync(recursive: true);
    Future<void> capture(String name) async {
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${output.path}/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final brightness in [Brightness.light, Brightness.dark]) {
      enabled = true;
      sequence = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            key: ValueKey(brightness),
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff706330),
                brightness: brightness,
              ),
              fontFamily: 'MiSans',
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(20),
                child: StatefulBuilder(
                  builder: (context, update) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      Text(
                        '公共组件 · 交互预览',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text('开关形变 / 关联设置 / 空态 / 面板渐隐'),
                      const SizedBox(height: 20),
                      SegmentedCardGroup(
                        children: [
                          M3eSwitchListTile(
                            key: const ValueKey('switch'),
                            title: const Text('富文本编辑器'),
                            subtitle: const Text('拖动开关，松手后切换'),
                            secondary: const Icon(Icons.edit_outlined),
                            value: enabled,
                            onChanged: (value) => update(() => enabled = value),
                          ),
                          if (enabled)
                            const ListTile(
                              key: ValueKey('dependent'),
                              leading: Icon(Icons.auto_awesome_outlined),
                              title: Text('即时渲染'),
                              subtitle: Text('关联设置平滑展开与收起'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: AppEmptyState(
                          icon: const Icon(Icons.bookmark_border_rounded),
                          title: '还没有收藏',
                          message: '收藏感兴趣的内容，稍后在这里查看',
                          action: TextButton(
                            onPressed: () {},
                            child: const Text('去发现'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 250,
                        child: AppSheetScaffold(
                          title: '浏览选项',
                          expandToFill: true,
                          showCloseButton: false,
                          contentPadding: EdgeInsets.zero,
                          child: ListView.builder(
                            controller: scroll,
                            itemExtent: 48,
                            itemCount: 12,
                            itemBuilder: (_, index) => ListTile(
                              leading: const Icon(Icons.tune_rounded),
                              title: Text(
                                ['最新内容', '热门话题', '我的收藏', '最近浏览'][index % 4],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> frame() async {
        await tester.pump(const Duration(milliseconds: 40));
        await capture(
          '${brightness.name}-${(sequence++).toString().padLeft(3, '0')}',
        );
      }

      for (var i = 0; i < 12; i++) {
        await frame();
      }
      final drag = await tester.startGesture(
        tester.getCenter(find.byType(M3eSwitch)),
      );
      for (var i = 0; i < 5; i++) {
        await frame();
      }
      await drag.moveBy(const Offset(-22, 0));
      for (var i = 0; i < 5; i++) {
        await drag.moveBy(const Offset(-4, 0));
        await frame();
      }
      await drag.up();
      for (var i = 0; i < 10; i++) {
        await frame();
      }
      await tester.tap(find.text('富文本编辑器'));
      for (var i = 0; i < 10; i++) {
        await frame();
      }
      for (var i = 0; i < 8; i++) {
        scroll.jumpTo((i + 1) * 8);
        await frame();
      }
      await tester.pumpAndSettle();
      await capture('${brightness.name}-rest');
      expect(tester.takeException(), isNull);
    }
  });
}
