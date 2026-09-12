/// 富文本编辑器工具注册表。
///
/// **为什么要单独一份**：源码模式的 `editorTools` 全部作用于
/// `MarkdownToolbarState`（往 controller.text 里塞 markdown 字面量），
/// 富文本必须调 [EditorState] 命令（改文档模型）。两者动作签名不兼容，
/// 但**机制**要一致 —— 都靠一张注册表驱动「工具栏外显 + 更多面板网格 +
/// pin 自定义」，这样两种模式的用户心智才是同一套。
///
/// 与源码注册表的对应关系：id 尽量沿用（bold/italic/link…），使得
/// [composerShortcutHint] 的快捷键标注、以及未来两边共享 pin 偏好成为
/// 可能。富文本独有的（行内剧透）用新 id。
library;

export '../../../constants/composer_tool_defaults.dart'
    show kDefaultRichVisibleTools;

import 'package:flutter/material.dart';
import 'package:fluxdo_render/editor.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

/// 富文本工具的执行上下文：命令目标 + 需要宿主配合的动作。
class RichToolContext {
  const RichToolContext({
    required this.state,
    required this.onInsertLink,
    required this.onPickImage,
    required this.onToggleInlineSpoiler,
    required this.onSetHeading,
  });

  final EditorState state;

  /// 插入链接（要弹对话框，宿主实现）
  final VoidCallback onInsertLink;

  /// 上传图片（要走文件选择 + 上传链路，宿主实现）
  final VoidCallback onPickImage;

  /// 行内剧透（无选区时要插占位并整选，逻辑在宿主）
  final VoidCallback onToggleInlineSpoiler;

  /// 设置标题级别（0 = 正文）
  final ValueChanged<int> onSetHeading;
}

/// 一个富文本工具。
class RichEditorTool {
  const RichEditorTool({
    required this.id,
    required this.icon,
    required this.label,
    required this.run,
    this.isActive,
  });

  /// 稳定 id，用于 pin 偏好存储与快捷键查表。
  final String id;

  final FaIconData icon;
  final String label;

  /// 执行动作。
  final void Function(RichToolContext ctx) run;

  /// 当前是否处于激活态（如光标处已是粗体）。null = 无激活概念。
  final bool Function(RichToolSnapshot snap)? isActive;
}

/// 光标处的状态快照，驱动工具激活态显示。
///
/// 用不可变快照而不是直接读 [EditorState]，是为了让工具栏能做「签名相等
/// 则跳过重建」的优化（纯打字时签名不变，零重建）。
class RichToolSnapshot {
  const RichToolSnapshot({
    required this.marks,
    required this.headingLevel,
    required this.isListItem,
    required this.ordered,
    required this.inQuote,
  });

  final Set<MarkKind> marks;
  final int headingLevel;
  final bool isListItem;
  final bool ordered;
  final bool inQuote;

  bool has(MarkKind k) => marks.contains(k);
}

/// 全部富文本工具（顺序 = 工具栏外显与面板网格的展示顺序）。
final List<RichEditorTool> richEditorTools = [
  RichEditorTool(
    id: 'bold',
    icon: FontAwesomeIcons.bold,
    label: '粗体',
    run: (c) => c.state.toggleMark(MarkKind.strong),
    isActive: (s) => s.has(MarkKind.strong),
  ),
  RichEditorTool(
    id: 'italic',
    icon: FontAwesomeIcons.italic,
    label: '斜体',
    run: (c) => c.state.toggleMark(MarkKind.em),
    isActive: (s) => s.has(MarkKind.em),
  ),
  RichEditorTool(
    id: 'strikethrough',
    icon: FontAwesomeIcons.strikethrough,
    label: '删除线',
    run: (c) => c.state.toggleMark(MarkKind.lineThrough),
    isActive: (s) => s.has(MarkKind.lineThrough),
  ),
  RichEditorTool(
    id: 'inlineCode',
    icon: FontAwesomeIcons.code,
    label: '行内代码',
    run: (c) => c.state.toggleMark(MarkKind.inlineCode),
    isActive: (s) => s.has(MarkKind.inlineCode),
  ),
  RichEditorTool(
    id: 'spoilerInline',
    icon: FontAwesomeIcons.eyeSlash,
    label: '行内剧透',
    run: (c) => c.onToggleInlineSpoiler(),
    isActive: (s) => s.has(MarkKind.spoilerInline),
  ),
  RichEditorTool(
    id: 'heading1',
    icon: FontAwesomeIcons.heading,
    label: '标题 1',
    run: (c) => c.onSetHeading(1),
    isActive: (s) => s.headingLevel == 1,
  ),
  RichEditorTool(
    id: 'heading2',
    icon: FontAwesomeIcons.heading,
    label: '标题 2',
    run: (c) => c.onSetHeading(2),
    isActive: (s) => s.headingLevel == 2,
  ),
  RichEditorTool(
    id: 'heading3',
    icon: FontAwesomeIcons.heading,
    label: '标题 3',
    run: (c) => c.onSetHeading(3),
    isActive: (s) => s.headingLevel == 3,
  ),
  RichEditorTool(
    id: 'bulletList',
    icon: FontAwesomeIcons.listUl,
    label: '无序列表',
    run: (c) => c.state.toggleList(ordered: false),
    isActive: (s) => s.isListItem && !s.ordered,
  ),
  RichEditorTool(
    id: 'numberedList',
    icon: FontAwesomeIcons.listOl,
    label: '有序列表',
    run: (c) => c.state.toggleList(ordered: true),
    isActive: (s) => s.isListItem && s.ordered,
  ),
  RichEditorTool(
    id: 'quote',
    icon: FontAwesomeIcons.quoteRight,
    label: '引用',
    run: (c) => c.state.toggleQuote(),
    isActive: (s) => s.inQuote,
  ),
  RichEditorTool(
    id: 'link',
    icon: FontAwesomeIcons.link,
    label: '插入链接',
    run: (c) => c.onInsertLink(),
  ),
  RichEditorTool(
    id: 'image',
    icon: FontAwesomeIcons.image,
    label: '上传图片',
    run: (c) => c.onPickImage(),
  ),
];

/// 按用户保存的顺序解析固定工具，忽略未知或已移除的 id。
List<RichEditorTool> resolveVisibleRichTools(List<String> ids) {
  final byId = {for (final tool in richEditorTools) tool.id: tool};
  return [
    for (final id in ids.toSet())
      if (byId[id] != null) byId[id]!,
  ];
}
