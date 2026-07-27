/// composer 文档编解码:raw markdown ↔ 编辑文档。
///
/// - 导入(markdown → doc):走完整 cook 链路 —— `DiscourseCookService.cook`
///   (Discourse 官方 JS bundle,与服务端 1:1)→ `ParagraphParser.parse` →
///   `blockNodesToDoc`。cook 不可用(web/引擎降级)返回 null,调用方留在
///   纯文本模式。
/// - 导出(doc → markdown):直调子包序列化器。
/// - 门禁导入(编辑已有帖子):导入后立即序列化回 raw、二次 cook,与原
///   raw 的 cook 逐结构对比 —— 不等价说明序列化器覆盖不了这帖(poll/
///   chat/policy 岛、或语法缺口),返回 null 降级源码模式,**防止提交毁帖**。
///
/// 已知 raw 表示塌陷(语义无损,门禁放行,官方 ProseMirror composer
/// 同病):外链图 `![a|600x400, 50%](https://…)` cook 后是普通
/// `<img width=300 height=200>`(image-controls 只注入 upload 图,无
/// data-scale)→ 再导入 scale=null → 序列化塌为 `![a|300x200](…)`。
/// cook 产物等价(floor 乘法先行,二次 cook 不再乘),仅 raw 写法变。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:fluxdo_render/editor.dart';
import 'package:fluxdo_render/fluxdo_render.dart' show ParagraphParser;

import '../../../services/discourse_cook_service.dart';

/// raw markdown → 编辑文档。cook 不可用/失败返回 null。
///
/// [timeout]:cook 引擎初始化依赖站点数据(网络),挂起/慢时不能拖死
/// 调用方(插入块点了没反应连降级都走不到)—— 超时按 cook 不可用处理。
Future<List<EditorBlock>?> markdownToDoc(
  String raw, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (raw.trim().isEmpty) {
    var n = 0;
    return blockNodesToDoc(const [], () => 'e_${n++}');
  }
  String? cooked;
  try {
    cooked = await DiscourseCookService().cook(raw).timeout(timeout);
  } on TimeoutException {
    debugPrint('[RichComposer] cook 超时(${timeout.inSeconds}s),降级');
    return null;
  }
  if (cooked == null) return null;
  final nodes = ParagraphParser().parse(cooked);
  var n = 0;
  return blockNodesToDoc(nodes, () => 'e_${n++}');
}

/// 编辑文档 → raw markdown。
String docToRaw(List<EditorBlock> doc) => docToMarkdown(doc);

/// 带往返等价门禁的导入(编辑已有帖子专用)。
///
/// 等价判据:`cook(原 raw)` 与 `cook(docToRaw(导入结果))` 归一化后相同。
/// 同一个引擎、同一份站点配置,语义相同的 raw 必产相同 cooked —— 不同
/// 即意味着往返有损(内容丢失或语法漂移),此时返回 null,调用方留在
/// 纯文本编辑器(raw 原文完好)。
Future<List<EditorBlock>?> markdownToDocGuarded(String raw) async {
  if (raw.trim().isEmpty) return markdownToDoc(raw);
  final cookService = DiscourseCookService();
  String? cookedOrig;
  try {
    // 初次导入允许更长等待(冷启动站点数据+bundle eval),但同样有界
    cookedOrig =
        await cookService.cook(raw).timeout(const Duration(seconds: 10));
  } on TimeoutException {
    debugPrint('[RichComposer] 导入 cook 超时,降级源码模式');
    return null;
  }
  if (cookedOrig == null) return null;

  final nodes = ParagraphParser().parse(cookedOrig);
  var n = 0;
  final doc = blockNodesToDoc(nodes, () => 'e_${n++}');

  final back = docToRaw(doc);
  final cookedBack = await cookService.cook(back);
  if (cookedBack == null) return null;

  if (_normalizeCooked(cookedOrig) != _normalizeCooked(cookedBack)) {
    debugPrint('[RichComposer] 往返门禁不通过,降级源码模式 '
        '(raw ${raw.length} chars → back ${back.length} chars)');
    if (kDebugMode) {
      _dumpFirstDiff(_normalizeCooked(cookedOrig), _normalizeCooked(cookedBack));
    }
    return null;
  }
  return doc;
}

/// cooked 归一化:每行 trim、去空行(块间空行数 / 行内缩进是渲染无关
/// 噪声;两边同口径归一,不影响"结构不同必不等"的判别力)。
String _normalizeCooked(String cooked) => cooked
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .join('\n');

/// debug:打印首个差异行上下文(定位序列化缺口用)。
void _dumpFirstDiff(String a, String b) {
  final la = a.split('\n');
  final lb = b.split('\n');
  for (var i = 0; i < la.length || i < lb.length; i++) {
    final x = i < la.length ? la[i] : '<EOF>';
    final y = i < lb.length ? lb[i] : '<EOF>';
    if (x != y) {
      debugPrint('[RichComposer] 门禁 diff @line $i\n  原: $x\n  回: $y');
      return;
    }
  }
}
