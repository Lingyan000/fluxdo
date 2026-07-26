import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'dart:io';

import 'package:fluxdo_render/editor.dart'
    show observeModifierKeyEvent, primaryModifierHeld;

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

/// 提交快捷键(Cmd/Ctrl+Enter,含小键盘 Enter;帮助浮层展示用)
List<SingleActivator> composerSubmitActivators() => [
      _primary(LogicalKeyboardKey.enter),
      _primary(LogicalKeyboardKey.numpadEnter),
    ];

/// Cmd/Ctrl+Enter 提交的拦截层(替代 CallbackShortcuts + SingleActivator)。
///
/// SingleActivator 直接读 `HardwareKeyboard` 的逻辑修饰键状态,而该状态在
/// Windows 上会随使用时间失同步(IME/平台注入把 Ctrl 弄成假的「已抬起」)。
/// 失同步后的表现:编辑器内核用自己的权威判定认出 primaryEnter 主动让路,
/// 外层 SingleActivator 却因逻辑状态不匹配不触发 —— 回车穿透给 IME,
/// Ctrl+Enter 变成插换行(实测两行)且发不出去。
///
/// 修法是全链路只认一个权威:内核的 [primaryModifierHeld](含 Ctrl 按下的
/// 补偿窗口)。同时把每个按键事件喂给 [observeModifierKeyEvent],让补偿
/// 窗口在焦点落在标题输入框等纯 TextField 上时同样有效。
bool _physicalPrimaryHeld(HardwareKeyboard pressed) {
  final keys = pressed.physicalKeysPressed;
  return _isMac
      ? keys.contains(PhysicalKeyboardKey.metaLeft) ||
          keys.contains(PhysicalKeyboardKey.metaRight)
      : keys.contains(PhysicalKeyboardKey.controlLeft) ||
          keys.contains(PhysicalKeyboardKey.controlRight);
}

class ComposerSubmitShortcut extends StatelessWidget {
  const ComposerSubmitShortcut({
    super.key,
    required this.onSubmit,
    required this.child,
  });

  final VoidCallback onSubmit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        observeModifierKeyEvent(event);
        // 只认第一次按下,KeyRepeat 会连发提交
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k != LogicalKeyboardKey.enter &&
            k != LogicalKeyboardKey.numpadEnter) {
          return KeyEventResult.ignored;
        }
        // 提交是**不可逆动作**(发帖),判据比编辑器内部更严:逻辑状态
        // 直接认;补偿窗口(兜逻辑状态失同步)必须再与「物理 Ctrl/Cmd
        // 确实按着」取合取 —— 真按着时物理集合一定包含它,窗口单独成立
        // 而物理键不在,说明是残留窗口,宁可漏认也不误发。
        final pressed = HardwareKeyboard.instance;
        final logicalHeld =
            _isMac ? pressed.isMetaPressed : pressed.isControlPressed;
        if (!logicalHeld &&
            !(primaryModifierHeld(event) && _physicalPrimaryHeld(pressed))) {
          return KeyEventResult.ignored;
        }
        onSubmit();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}

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
