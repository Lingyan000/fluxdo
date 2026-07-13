import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../../../l10n/s.dart';
import 'markdown_toolbar.dart';

/// 编辑器工具定义
///
/// 工具栏外显区和「更多」工具面板共用同一份注册表（[editorTools]）。
/// 普通工具提供 [action]；需要二级选择的工具（标题、Callout）提供
/// [menuItems] + [onMenuSelected]。
class EditorTool {
  /// 稳定 id，用于偏好存储（外显工具列表）
  final String id;

  /// 图标（FaIcon / Icon，尺寸颜色由使用方通过 IconTheme 控制）
  final Widget icon;

  /// 标签文案
  final String Function(AppLocalizations s) label;

  /// 普通工具动作
  final void Function(MarkdownToolbarState toolbar)? action;

  /// 二级弹出菜单项（与 [onMenuSelected] 成对出现）
  final List<PopupMenuEntry<String>> Function(AppLocalizations s)? menuItems;

  /// 二级弹出菜单选中回调
  final void Function(MarkdownToolbarState toolbar, String value)?
      onMenuSelected;

  const EditorTool({
    required this.id,
    required this.icon,
    required this.label,
    this.action,
    this.menuItems,
    this.onMenuSelected,
  }) : assert(
          (action != null) != (menuItems != null && onMenuSelected != null),
          '普通工具提供 action，菜单工具提供 menuItems + onMenuSelected',
        );

  bool get hasMenu => menuItems != null;
}

/// 图片上传工具的 id（工具栏对其特殊渲染上传进度）
const String kEditorToolImage = 'image';

/// 全部编辑器工具（顺序即面板网格与工具栏外显顺序）
final List<EditorTool> editorTools = [
  EditorTool(
    id: kEditorToolImage,
    icon: const FaIcon(FontAwesomeIcons.image),
    label: (s) => s.toolPanel_image,
    action: (t) => t.pickAndUploadImages(),
  ),
  EditorTool(
    id: 'attachment',
    icon: const FaIcon(FontAwesomeIcons.paperclip),
    label: (s) => s.toolPanel_attachment,
    action: (t) => t.pickAndUploadFile(),
  ),
  // 音视频改名上传(.xz 绕站点扩展名白名单,4MB 上限;插 <audio>/<video>
  // 标签,网页端原生播放)
  EditorTool(
    id: 'media',
    icon: const FaIcon(FontAwesomeIcons.film),
    label: (s) => '音视频',
    menuItems: (s) => const [
      PopupMenuItem(value: 'audio', child: Text('上传音频')),
      PopupMenuItem(value: 'video', child: Text('上传视频')),
      PopupMenuItem(value: 'voice', child: Text('语音消息')),
    ],
    onMenuSelected: (t, value) => value == 'voice'
        ? t.recordAndInsertVoice()
        : t.pickAndUploadMedia(isAudio: value == 'audio'),
  ),
  EditorTool(
    id: 'heading',
    icon: const FaIcon(FontAwesomeIcons.heading),
    label: (s) => s.toolPanel_heading,
    menuItems: (s) => [
      PopupMenuItem(value: '1', child: Text(s.toolbar_h1)),
      PopupMenuItem(value: '2', child: Text(s.toolbar_h2)),
      PopupMenuItem(value: '3', child: Text(s.toolbar_h3)),
      PopupMenuItem(value: '4', child: Text(s.toolbar_h4)),
      PopupMenuItem(value: '5', child: Text(s.toolbar_h5)),
    ],
    onMenuSelected: (t, value) =>
        t.applyLinePrefix('${'#' * int.parse(value)} '),
  ),
  EditorTool(
    id: 'bold',
    icon: const FaIcon(FontAwesomeIcons.bold),
    label: (s) => s.toolPanel_bold,
    action: (t) => t.wrapSelection('**', '**',
        placeholder: S.current.toolbar_boldPlaceholder),
  ),
  EditorTool(
    id: 'italic',
    icon: const FaIcon(FontAwesomeIcons.italic),
    label: (s) => s.toolPanel_italic,
    action: (t) =>
        t.wrapSelection('*', '*', placeholder: S.current.toolbar_italicPlaceholder),
  ),
  EditorTool(
    id: 'strikethrough',
    icon: const FaIcon(FontAwesomeIcons.strikethrough),
    label: (s) => s.toolPanel_strikethrough,
    action: (t) => t.insertStrikethrough(),
  ),
  EditorTool(
    id: 'bulletList',
    icon: const FaIcon(FontAwesomeIcons.listUl),
    label: (s) => s.toolPanel_bulletList,
    action: (t) => t.applyLinePrefix('- '),
  ),
  EditorTool(
    id: 'numberedList',
    icon: const FaIcon(FontAwesomeIcons.listOl),
    label: (s) => s.toolPanel_numberedList,
    action: (t) => t.applyLinePrefix('1. '),
  ),
  EditorTool(
    id: 'link',
    icon: const FaIcon(FontAwesomeIcons.link),
    label: (s) => s.toolPanel_link,
    // 使用工具栏自身的 context：面板收起后该 context 仍然有效
    action: (t) => t.insertLink(t.context),
  ),
  EditorTool(
    id: 'quote',
    icon: const FaIcon(FontAwesomeIcons.quoteRight),
    label: (s) => s.toolPanel_quote,
    action: (t) => t.insertQuote(),
  ),
  EditorTool(
    id: 'callout',
    icon: const FaIcon(FontAwesomeIcons.noteSticky),
    label: (s) => s.toolPanel_callout,
    menuItems: (s) => const [
      PopupMenuItem(value: 'note', child: Text('Note')),
      PopupMenuItem(value: 'tip', child: Text('Tip')),
      PopupMenuItem(value: 'info', child: Text('Info')),
      PopupMenuItem(value: 'warning', child: Text('Warning')),
      PopupMenuItem(value: 'danger', child: Text('Danger')),
      PopupMenuItem(value: 'bug', child: Text('Bug')),
      PopupMenuItem(value: 'example', child: Text('Example')),
      PopupMenuItem(value: 'quote', child: Text('Quote')),
      PopupMenuItem(value: 'abstract', child: Text('Abstract')),
      PopupMenuItem(value: 'todo', child: Text('Todo')),
      PopupMenuItem(value: 'success', child: Text('Success')),
      PopupMenuItem(value: 'question', child: Text('Question')),
      PopupMenuItem(value: 'failure', child: Text('Failure')),
    ],
    onMenuSelected: (t, value) => t.insertCallout(value),
  ),
  EditorTool(
    id: 'template',
    icon: const FaIcon(FontAwesomeIcons.clipboard),
    label: (s) => s.toolPanel_template,
    action: (t) => t.insertTemplate(t.context),
  ),
  EditorTool(
    id: 'inlineCode',
    icon: const FaIcon(FontAwesomeIcons.code),
    label: (s) => s.toolPanel_inlineCode,
    action: (t) => t.insertInlineCode(),
  ),
  EditorTool(
    id: 'codeBlock',
    icon: const FaIcon(FontAwesomeIcons.fileCode),
    label: (s) => s.toolPanel_codeBlock,
    action: (t) => t.insertCodeBlock(),
  ),
  // 块级模板插入(与富 composer「+」插入菜单同款模板文本)
  EditorTool(
    id: 'insertBlock',
    icon: const FaIcon(FontAwesomeIcons.squarePlus),
    label: (s) => '插入块',
    menuItems: (s) => const [
      PopupMenuItem(value: 'table', child: Text('表格')),
      PopupMenuItem(value: 'math', child: Text('公式块')),
      PopupMenuItem(value: 'hr', child: Text('分隔线')),
      PopupMenuItem(value: 'details', child: Text('折叠详情')),
    ],
    onMenuSelected: (t, value) => t.insertBlockSnippet(switch (value) {
      'table' => '| 列 1 | 列 2 |\n|---|---|\n| 内容 | 内容 |',
      'math' => '\$\$\nE=mc^2\n\$\$',
      'hr' => '---',
      _ => '[details="点开看"]\n折叠内容\n[/details]',
    }),
  ),
  EditorTool(
    id: 'spoiler',
    icon: const FaIcon(FontAwesomeIcons.eyeSlash),
    label: (s) => s.toolPanel_spoiler,
    action: (t) => t.insertSpoiler(),
  ),
  EditorTool(
    id: 'imageGrid',
    icon: const FaIcon(FontAwesomeIcons.tableColumns),
    label: (s) => s.toolPanel_imageGrid,
    action: (t) => t.wrapImagesInGrid(),
  ),
];

/// 按注册表顺序过滤出外显工具
List<EditorTool> resolveVisibleTools(List<String> ids) {
  return editorTools.where((tool) => ids.contains(tool.id)).toList();
}
