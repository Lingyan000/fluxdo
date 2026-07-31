// Spike:验证 ui.ParagraphBuilder 能否在后台 isolate 构建 + 排版,
// 以及 ui.Paragraph 能否跨 isolate 传回主 isolate。
//
// 背景:正文布局缓存/预热方案(正文版 TopicCardLayout)的预热层
// 有两条候选路径:
//   a) UI 线程 idle 分片预排(chunk warm-up 同款,百分百可行);
//   b) 后台 isolate 真·后台排版(Telegram 同款,上限更高)。
// 路径 b 有两个未验证前提,本 spike 逐一实测:
//   1. dart:ui 的 ParagraphBuilder/Paragraph.layout 在非 root isolate
//      是否可用(历史上 dart:ui 大量 API 绑 root isolate,新引擎逐步
//      解绑,版本差异大,必须实测);
//   2. 排版产物 ui.Paragraph(native peer)能否经 SendPort 传回 ——
//      预期不能;若不能,后台排版只能回传行度量(高度/行数),
//      不能回传可绘制对象,路径 b 的价值大打折扣。
//
// 注意:flutter test 跑在 flutter_tester 引擎上,结论对真机是
// 必要非充分(test 里不行则真机大概率不行;test 里行还需真机复验)。
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('spike1: ParagraphBuilder 在后台 isolate 构建+排版', () async {
    Object? failure;
    Map<String, Object?>? metrics;
    try {
      metrics = await Isolate.run(() {
        final builder = ui.ParagraphBuilder(
          ui.ParagraphStyle(fontSize: 16, maxLines: null),
        );
        builder.pushStyle(ui.TextStyle(fontSize: 16));
        builder.addText('后台排版可行性验证 background isolate layout. ' * 40);
        final paragraph = builder.build();
        paragraph.layout(const ui.ParagraphConstraints(width: 400));
        final lines = paragraph.computeLineMetrics().length;
        final height = paragraph.height;
        paragraph.dispose();
        return <String, Object?>{'height': height, 'lines': lines};
      });
    } catch (e) {
      failure = e;
    }
    // 无论成败都打印结论,spike 的产出是"事实",不是绿灯
    // ignore: avoid_print
    print('[SPIKE1] 后台 isolate 排版: '
        '${failure == null ? "可行 metrics=$metrics" : "不可行 error=$failure"}');
    expect(true, isTrue); // spike 不设断言门槛,看打印
  });

  test('spike2: ui.Paragraph 跨 isolate 传回', () async {
    Object? failure;
    ui.Paragraph? returned;
    try {
      returned = await Isolate.run(() {
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 16));
        builder.addText('cross-isolate transfer probe');
        final paragraph = builder.build();
        paragraph.layout(const ui.ParagraphConstraints(width: 200));
        return paragraph; // 预期在 send 时抛错
      });
    } catch (e) {
      failure = e;
    }
    // ignore: avoid_print
    print('[SPIKE2] Paragraph 跨 isolate: '
        '${failure == null ? "可传回 height=${returned?.height}(意外!)" : "不可传 error=${failure.runtimeType}: $failure"}');
    expect(true, isTrue);
  });

  test('spike3: 对照组 — root isolate 排版(基线,理应可行)', () async {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 16));
    builder.addText('root isolate baseline. ' * 40);
    final paragraph = builder.build();
    paragraph.layout(const ui.ParagraphConstraints(width: 400));
    // ignore: avoid_print
    print('[SPIKE3] root isolate 基线: height=${paragraph.height} '
        'lines=${paragraph.computeLineMetrics().length}');
    paragraph.dispose();
    expect(true, isTrue);
  });
}
