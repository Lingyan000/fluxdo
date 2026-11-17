/// Benchmark: 子包 FluxdoRender 渲染性能基线
///
/// fwfh legacy 引擎下线后,这里只保留新引擎自身的性能基线(回归监控用)。
///
/// 跑法:
///   flutter test test/perf/render_benchmark_test.dart
///
/// 输出 stdout:
///   - cold build(首次 pumpWidget,含 parse + flatten + paint)
///   - warm rebuild(setState 触发,模拟用户交互后重 build)
///   - 3 种 cooked 形态:short / medium / long
///
/// **注意**:这是 widget test 环境(无真 GPU)的相对数值,不是生产环境绝对值,
/// 用于跨版本对比"新引擎有没有变慢"。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo_render/fluxdo_render.dart';

void main() {
  // 30 段普通文本 + 5 个 lightbox 图 + 1 个代码块 + 1 个引用卡的典型长帖
  final longCooked = _generateLongPost();
  final mediumCooked = _generateMediumPost();
  final shortCooked = _generateShortPost();

  group('render benchmark — FluxdoRender 渲染性能基线', () {
    testWidgets('cold build x 50 — long', (tester) async {
      final cold = await _measureColdBuild(
        tester,
        runs: 50,
        builder: () => FluxdoRender(cookedHtml: longCooked),
      );
      // ignore: avoid_print
      print('--- FLUXDO long cold mean=${cold.toStringAsFixed(2)}ms');
    });

    testWidgets('warm rebuild x 100 — medium', (tester) async {
      await _measureWarmRebuild(
        tester,
        runs: 100,
        builder: () => FluxdoRender(cookedHtml: mediumCooked),
        label: 'FLUXDO',
      );
    });

    testWidgets('short post cold x 200', (tester) async {
      final t = await _measureColdBuild(
        tester,
        runs: 200,
        builder: () => FluxdoRender(cookedHtml: shortCooked),
      );
      // ignore: avoid_print
      print('--- FLUXDO short cold mean=${t.toStringAsFixed(3)}ms');
    });
  });
}

/// 测 N 次 pumpWidget 的平均耗时(冷构建)
Future<double> _measureColdBuild(
  WidgetTester tester, {
  required int runs,
  required Widget Function() builder,
}) async {
  // warmup
  for (int i = 0; i < 3; i++) {
    await tester.pumpWidget(_wrap(builder()));
  }
  final sw = Stopwatch();
  for (int i = 0; i < runs; i++) {
    sw.start();
    await tester.pumpWidget(
      Container(key: ValueKey('rebuild_$i'), child: _wrap(builder())),
    );
    sw.stop();
  }
  return sw.elapsedMicroseconds / runs / 1000;
}

/// 测 N 次 setState 触发的 rebuild 耗时(同 widget tree,只 state 变化)
Future<void> _measureWarmRebuild(
  WidgetTester tester, {
  required int runs,
  required Widget Function() builder,
  required String label,
}) async {
  int counter = 0;
  late StateSetter setOuter;
  await tester.pumpWidget(MaterialApp(
    home: StatefulBuilder(
      builder: (ctx, setState) {
        setOuter = setState;
        return Scaffold(
          body: Column(
            children: [
              Text('$counter'),
              builder(),
            ],
          ),
        );
      },
    ),
  ));
  final sw = Stopwatch();
  for (int i = 0; i < runs; i++) {
    setOuter(() => counter++);
    sw.start();
    await tester.pump();
    sw.stop();
  }
  final mean = sw.elapsedMicroseconds / runs / 1000;
  // ignore: avoid_print
  print('--- $label warm rebuild mean=${mean.toStringAsFixed(3)}ms');
}

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    ),
  );
}

String _generateShortPost() {
  return '<p>短帖一段。包含 <strong>粗体</strong> 和 <a href="/x">链接</a>。</p>';
}

String _generateMediumPost() {
  final b = StringBuffer();
  for (int i = 0; i < 8; i++) {
    b.write('<p>段落 $i:这是测试用的文本,包含 <strong>粗体</strong> '
        '和 <a href="https://example.com/$i">链接 $i</a>,'
        '以及 <code>inline code $i</code> 和 <em>斜体</em>。</p>');
  }
  b.write('<ul>');
  for (int i = 0; i < 5; i++) {
    b.write('<li>列表项 $i</li>');
  }
  b.write('</ul>');
  b.write('<blockquote><p>这是一段引用内容,'
      '含 <strong>多种</strong> <em>样式</em>。</p></blockquote>');
  return b.toString();
}

String _generateLongPost() {
  final b = StringBuffer();
  for (int i = 0; i < 30; i++) {
    b.write('<p>段落 $i:测试文本含 <strong>粗体</strong>、<em>斜体</em>、'
        '<code>code</code>、<a href="https://example.com/$i">链接 $i</a>,'
        '以及一些 <span>普通文字</span> 用于构造长帖性能场景。</p>');
  }
  // 5 张 lightbox 图
  for (int i = 0; i < 5; i++) {
    b.write('<div class="lightbox-wrapper">'
        '<a class="lightbox" href="https://cdn.example.com/full_$i.png">'
        '<img src="https://cdn.example.com/thumb_$i.png" '
        'alt="img$i" width="690" height="200">'
        '<div class="meta"><span class="filename">img$i</span>'
        '<span class="informations">690×200 ${i + 1}0 KB</span></div>'
        '</a></div>');
  }
  b.write('<pre><code class="lang-dart">'
      'void main() {\n'
      '  for (int i = 0; i &lt; 10; i++) {\n'
      '    print(\'item \$i\');\n'
      '  }\n'
      '}\n'
      '</code></pre>');
  b.write('<aside class="quote" data-username="alice" data-post="3" data-topic="999">'
      '<div class="title">'
      '<img class="avatar" src="https://example.com/avatar.png">'
      'alice:</div>'
      '<blockquote><p>这是被引用的内容。</p></blockquote>'
      '</aside>');
  return b.toString();
}
