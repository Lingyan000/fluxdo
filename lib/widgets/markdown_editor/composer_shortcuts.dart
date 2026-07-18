import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'dart:io';

import '../../l10n/s.dart';
import '../../models/shortcut_binding.dart';
import 'markdown_toolbar.dart';

/// 撰写(composer)快捷键事实源 —— 键位对齐 Discourse composer toolbar
/// (Cmd/Ctrl+B/I/E/K、Cmd/Ctrl+Shift+7/8/9、Cmd/Ctrl+Alt+1..4)。
///
/// 消费方:
/// - 源码编辑器(markdown_editor.dart)的 CallbackShortcuts 绑定;
/// - 两个工具栏按钮 tooltip 的快捷键后缀([composerShortcutHint]);
/// - 快捷键帮助浮层(shortcut_help_overlay.dart)的「撰写」分区。
///
/// 富文本模式的按键**行为**在内核 switch 里
/// (packages/fluxdo_render .../input/editor_key_handler.dart),
/// 不由本表驱动 —— 增删键位需两处同步。
class ComposerShortcutSpec {
  /// 对应 editor_tools.dart 的工具 id(tooltip 后缀查表用;标题系列
  /// 走二级菜单,用合成 id `heading1..4` 供菜单项标注查表)
  final String toolId;

  /// 行 label(帮助浮层用,复用现有 toolPanel_* / toolbar_h*)
  final String Function(AppLocalizations s) label;

  /// 激活键(构造时已按平台选好 meta/control)
  final SingleActivator activator;

  /// 源码模式动作(操作 MarkdownToolbarState 的既有格式化 API)
  final void Function(MarkdownToolbarState t) sourceAction;

  const ComposerShortcutSpec({
    required this.toolId,
    required this.label,
    required this.activator,
    required this.sourceAction,
  });
}

bool get _isMac => !kIsWeb && Platform.isMacOS;

/// 平台主修饰键(mac=Cmd,其余=Ctrl;对齐 Discourse PLATFORM_KEY_MODIFIER)
SingleActivator _primary(
  LogicalKeyboardKey key, {
  bool shift = false,
  bool alt = false,
}) {
  return _isMac
      ? SingleActivator(key, meta: true, shift: shift, alt: alt)
      : SingleActivator(key, control: true, shift: shift, alt: alt);
}

/// 提交快捷键(Cmd/Ctrl+Enter,含小键盘 Enter;宿主页绑定用)
List<SingleActivator> composerSubmitActivators() => [
      _primary(LogicalKeyboardKey.enter),
      _primary(LogicalKeyboardKey.numpadEnter),
    ];

/// 全部撰写格式化快捷键(顺序即帮助浮层「撰写」分区展示顺序)
List<ComposerShortcutSpec> buildComposerShortcutSpecs() {
  return [
    ComposerShortcutSpec(
      toolId: 'bold',
      label: (s) => s.toolPanel_bold,
      activator: _primary(LogicalKeyboardKey.keyB),
      sourceAction: (t) => t.wrapSelection('**', '**',
          placeholder: S.current.toolbar_boldPlaceholder),
    ),
    ComposerShortcutSpec(
      toolId: 'italic',
      label: (s) => s.toolPanel_italic,
      activator: _primary(LogicalKeyboardKey.keyI),
      sourceAction: (t) => t.wrapSelection('*', '*',
          placeholder: S.current.toolbar_italicPlaceholder),
    ),
    ComposerShortcutSpec(
      toolId: 'inlineCode',
      label: (s) => s.toolPanel_inlineCode,
      activator: _primary(LogicalKeyboardKey.keyE),
      sourceAction: (t) => t.insertInlineCode(),
    ),
    ComposerShortcutSpec(
      toolId: 'strikethrough',
      label: (s) => s.toolPanel_strikethrough,
      activator: _primary(LogicalKeyboardKey.keyX, shift: true),
      sourceAction: (t) => t.insertStrikethrough(),
    ),
    ComposerShortcutSpec(
      toolId: 'link',
      label: (s) => s.toolPanel_link,
      activator: _primary(LogicalKeyboardKey.keyK),
      sourceAction: (t) => t.insertLink(t.context),
    ),
    ComposerShortcutSpec(
      toolId: 'numberedList',
      label: (s) => s.toolPanel_numberedList,
      activator: _primary(LogicalKeyboardKey.digit7, shift: true),
      sourceAction: (t) => t.applyLinePrefix('1. '),
    ),
    ComposerShortcutSpec(
      toolId: 'bulletList',
      label: (s) => s.toolPanel_bulletList,
      activator: _primary(LogicalKeyboardKey.digit8, shift: true),
      sourceAction: (t) => t.applyLinePrefix('- '),
    ),
    ComposerShortcutSpec(
      toolId: 'quote',
      label: (s) => s.toolPanel_quote,
      activator: _primary(LogicalKeyboardKey.digit9, shift: true),
      sourceAction: (t) => t.insertQuote(),
    ),
    for (final (level, key) in const [
      (1, LogicalKeyboardKey.digit1),
      (2, LogicalKeyboardKey.digit2),
      (3, LogicalKeyboardKey.digit3),
      (4, LogicalKeyboardKey.digit4),
    ])
      ComposerShortcutSpec(
        toolId: 'heading$level',
        label: (s) => switch (level) {
          1 => s.toolbar_h1,
          2 => s.toolbar_h2,
          3 => s.toolbar_h3,
          _ => s.toolbar_h4,
        },
        activator: _primary(key, alt: true),
        sourceAction: (t) => t.applyLinePrefix('${'#' * level} '),
      ),
  ];
}

/// 工具 tooltip 的快捷键后缀,如「 (⌘B)」/「 (Ctrl+B)」;无对应键位返回 null
String? composerShortcutHint(String toolId) {
  for (final spec in buildComposerShortcutSpecs()) {
    if (spec.toolId == toolId) {
      return ' (${ShortcutBinding.formatActivator(spec.activator)})';
    }
  }
  return null;
}
