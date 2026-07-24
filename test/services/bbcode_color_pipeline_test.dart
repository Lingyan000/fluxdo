/// `[color]` 从 cooked HTML 到编辑文档的整条链路实测。
///
/// 绕开 JS 引擎:直接喂 cook 会吐出的 HTML(`[color=…]` 原样当文字),
/// 走 applyBbcodeColor → ParagraphParser → blockNodesToDoc,看最终落到
/// 编辑器里的是什么块。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse_cook_service.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ParagraphParser;

List<EditorBlock> pipeline(String cookedRaw) {
  final html = DiscourseCookService.applyBbcodeColor(cookedRaw);
  final nodes = ParagraphParser().parse(html);
  var n = 0;
  return blockNodesToDoc(nodes, () => 'e_${n++}');
}

void main() {
  test('探针:[color] 最终落成什么块', () {
    // cook 对 [color=#FF0000] 的**真实**输出(实测):#FF0000 被 hashtag
    // 特性包成了 span
    final blocks = pipeline(
      '<p>[color=<span class="hashtag-raw">#FF0000</span>]a[/color]</p>',
    );
    // ignore: avoid_print
    print('blocks = ${blocks.map((b) => '${b.runtimeType}:$b').toList()}');
    expect(blocks, isNotEmpty, reason: '空文档会让调用方退回 pastePlainText');
  });

  test('探针:序列化回程', () {
    final blocks = pipeline(
      '<p>[color=<span class="hashtag-raw">#FF0000</span>]a[/color]</p>',
    );
    // ignore: avoid_print
    print('docToMarkdown = ${docToMarkdown(blocks)}');
  });
}
