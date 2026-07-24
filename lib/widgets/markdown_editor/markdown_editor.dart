import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:chat_bottom_container/chat_bottom_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../../providers/preferences_provider.dart';
import '../../services/discourse_cook_service.dart';
import '../../services/emoji_handler.dart';
import '../../utils/emoji_shortcodes.dart';
import '../../utils/platform_utils.dart';
import '../mention/mention_autocomplete.dart';
import 'composer_shortcuts.dart';
import 'emoji_popover.dart';
import 'emoji_sticker_panel.dart';
import 'markdown_renderer.dart';
import 'markdown_tool_panel.dart';
import 'markdown_toolbar.dart';
import 'package:pangutext/pangutext.dart';
import '../../../../../l10n/s.dart';

/// 编辑器面板类型
enum EditorPanelType { none, keyboard, emoji, tools }

/// 通用 Markdown 编辑器组件
/// 包含编辑/预览模式切换、工具栏和表情面板
class MarkdownEditor extends ConsumerStatefulWidget {
  /// 内容控制器（必需）
  final TextEditingController controller;

  /// 焦点节点（可选，不传则内部创建）
  final FocusNode? focusNode;

  /// 提示文本
  final String hintText;

  /// 最小行数（仅当 expands 为 false 时生效）
  final int minLines;

  /// 是否扩展填满可用空间
  final bool expands;

  /// 表情面板高度
  final double emojiPanelHeight;

  /// 自定义面板（表情/工具）开关状态变化回调
  final ValueChanged<bool>? onEmojiPanelChanged;

  /// 用户提及数据源（可选，不传则不启用 @用户 功能）
  final MentionDataSource? mentionDataSource;

  /// 是否显示预览按钮
  final bool showPreviewButton;

  /// 外部预览切换回调（可选）
  /// 提供时，预览按钮将调用此回调而非内部预览切换，
  /// 同时应配合 [isPreview] 传入当前预览状态
  final VoidCallback? onTogglePreview;

  /// 外部预览状态（可选，配合 [onTogglePreview] 使用）
  final bool? isPreview;

  /// 用户点"富文本模式"按钮(源码 → 富文本切换;宿主重挂
  /// RichComposerEditor,内容经 controller 无缝衔接 + 导入门禁)。
  /// null = 不显示切换按钮(富文本开关未开/已降级不可逆场景)。
  final VoidCallback? onSwitchToRich;

  /// 滚动头部(标题/标签等元数据区):放进编辑区滚动容器顶部,与正文
  /// 一起滚 —— 手机上写正文时头部自然滚出屏,编辑区满格(零跳变:
  /// 头部高度恒定,离场回场全由滚动驱动)。null 时无头部。
  final Widget? header;

  /// 底部属性条(编辑区与工具栏之间,如 ComposerMetaBar):
  /// 分类/标签/字数等元数据常驻可见可改,不随滚动离场。null 时无。
  final Widget? metaBar;

  const MarkdownEditor({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = '',
    this.minLines = 5,
    this.expands = false,
    this.emojiPanelHeight = 280.0,
    this.onEmojiPanelChanged,
    this.mentionDataSource,
    this.showPreviewButton = true,
    this.onTogglePreview,
    this.isPreview,
    this.onSwitchToRich,
    this.header,
    this.metaBar,
  });

  @override
  ConsumerState<MarkdownEditor> createState() => MarkdownEditorState();
}

class MarkdownEditorState extends ConsumerState<MarkdownEditor> {
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;

  final _toolbarKey = GlobalKey<MarkdownToolbarState>();
  final _scrollController = ScrollController();
  final _pangu = Pangu();
  bool _isApplyingPangu = false;
  Timer? _panguTimer;

  bool _showPreview = false;
  String _previousText = '';

  // 面板控制器
  final _panelController = ChatBottomPanelContainerController<EditorPanelType>();
  EditorPanelType _currentPanelType = EditorPanelType.none;
  bool _readOnly = false;
  // 面板意图状态：用户希望打开的自定义面板（表情/工具），
  // 用于防止焦点变化导致的面板状态竞争
  EditorPanelType _intendedPanel = EditorPanelType.none;

  /// EmojiStickerPanel 实例缓存。
  ///
  /// ChatBottomPanelContainer 每次 build 都会回调 otherPanelWidget 重新生成
  /// 面板 widget;如果每次都 new 一个 EmojiStickerPanel,编辑器任何 setState
  /// (键盘动画、草稿状态、预览切换…)都会级联重建整个 emoji grid ——
  /// viewport + cacheExtent 内几百个 cell 一帧内全部 rebuild,面板必卡。
  /// 缓存同一实例后,Element.updateChild 看到 identical widget 直接跳过
  /// 整棵子树。回调闭包只捕获 state 成员(_focusNode/_toolbarKey),
  /// 生命周期内稳定,缓存安全。
  Widget? _emojiPanelChild;

  /// 桌面端表情悬浮弹层控制器(移动端为 null,走 docked 面板)
  EmojiPopoverController? _emojiPopover;

  @override
  void initState() {
    super.initState();
    if (widget.focusNode != null) {
      _focusNode = widget.focusNode!;
    } else {
      _focusNode = FocusNode();
      _ownsFocusNode = true;
    }
    if (_isDesktop) {
      _emojiPopover = EmojiPopoverController()
        ..addListener(_onEmojiPopoverChanged);
    }
    EmojiHandler().init();
    // 预热 1:1 cook 引擎(eval bundle + 注入站点数据),
    // 让首次切预览时 JS cook 已就绪
    DiscourseCookService().warmUp();
    _previousText = widget.controller.text;
    widget.controller.addListener(_handleTextChange);
  }

  /// 弹层开合同步工具栏表情按钮高亮
  void _onEmojiPopoverChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _emojiPopover?.dispose();
    _panguTimer?.cancel();
    widget.controller.removeListener(_handleTextChange);
    _scrollController.dispose();
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  /// 处理文本变化，实现智能列表续行
  void _handleTextChange() {
    final currentText = widget.controller.text;
    final selection = widget.controller.selection;

    // 外滚结构下 TextField 不自滚,EditableText 的 showCaretOnScreen
    // 管不到外层 CustomScrollView —— 打字/换行/删除后手动跟随光标
    // (视口内 no-op,越界才 animateTo)。
    if (_focusNode.hasFocus) {
      _scrollToCursor();
    }

    // 只在文本增加时处理
    if (currentText.length <= _previousText.length) {
      _panguTimer?.cancel();
      _previousText = currentText;
      return;
    }

    if (selection.isValid &&
        selection.start > 0 &&
        currentText[selection.start - 1] == '\n') {
      // 找到上一行的开始位置
      int prevLineStart = selection.start - 2;
      if (prevLineStart < 0) {
        _previousText = currentText;
        return;
      }

      // 向前查找上一行的开始
      while (prevLineStart > 0 && currentText[prevLineStart - 1] != '\n') {
        prevLineStart--;
      }

      // 提取上一行的内容
      final prevLine = currentText.substring(prevLineStart, selection.start - 1);

      // 检测无序列表：- item 或 * item 或 + item
      final unorderedMatch =
          RegExp(r'^(\s*)([-*+])\s+(.*)$').firstMatch(prevLine);
      if (unorderedMatch != null) {
        final indent = unorderedMatch.group(1)!;
        final marker = unorderedMatch.group(2)!;
        final content = unorderedMatch.group(3)!;

        if (content.isEmpty) {
          // 空列表项，移除列表标记（含前面的换行符，避免多余空行）
          final removeStart = prevLineStart > 0 ? prevLineStart - 1 : prevLineStart;
          final newText = currentText.replaceRange(
            removeStart,
            selection.start,
            '\n',
          );
          _previousText = newText;
          widget.controller.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: removeStart + 1),
          );
        } else {
          // 非空列表项，添加新的列表标记
          final prefix = '$indent$marker ';
          final newText = currentText.replaceRange(
            selection.start,
            selection.start,
            prefix,
          );
          _previousText = newText;
          widget.controller.value = TextEditingValue(
            text: newText,
            selection:
                TextSelection.collapsed(offset: selection.start + prefix.length),
          );
        }
        return;
      }

      // 检测有序列表：1. item
      final orderedMatch =
          RegExp(r'^(\s*)(\d+)\.\s+(.*)$').firstMatch(prevLine);
      if (orderedMatch != null) {
        final indent = orderedMatch.group(1)!;
        final number = int.parse(orderedMatch.group(2)!);
        final content = orderedMatch.group(3)!;

        if (content.isEmpty) {
          // 空列表项，移除列表标记（含前面的换行符，避免多余空行）
          final removeStart = prevLineStart > 0 ? prevLineStart - 1 : prevLineStart;
          final newText = currentText.replaceRange(
            removeStart,
            selection.start,
            '\n',
          );
          _previousText = newText;
          widget.controller.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: removeStart + 1),
          );
        } else {
          // 非空列表项，添加新的列表标记（数字递增）
          final prefix = '$indent${number + 1}. ';
          final newText = currentText.replaceRange(
            selection.start,
            selection.start,
            prefix,
          );
          _previousText = newText;
          widget.controller.value = TextEditingValue(
            text: newText,
            selection:
                TextSelection.collapsed(offset: selection.start + prefix.length),
          );
        }
        return;
      }
    }

    // 防抖执行 pangu 混排，避免在 IME 自动补全括号等多步操作中途修改 controller
    // 导致平台文本输入状态与 IME 内部状态不同步
    if (ref.read(preferencesProvider).autoPanguSpacing && !_isApplyingPangu) {
      _panguTimer?.cancel();
      _panguTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) _applyPanguSpacing();
      });
    }

    _previousText = currentText;
  }

  /// 当前是否处于预览模式（优先使用外部状态）
  bool get _isPreview => widget.isPreview ?? _showPreview;

  void _togglePreview() {
    if (widget.onTogglePreview != null) {
      // 外部控制预览
      widget.onTogglePreview!();
    } else {
      // 内部控制预览
      setState(() {
        _showPreview = !_showPreview;
        if (_showPreview) {
          FocusScope.of(context).unfocus();
          closeEmojiPanel();
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focusNode.requestFocus();
          });
        }
      });
    }
  }

  /// 关闭表情/工具面板（供外部调用，如返回键拦截）
  void closeEmojiPanel() {
    if (_isDesktop) {
      _emojiPopover?.hide();
      return;
    }
    if (_intendedPanel != EditorPanelType.none ||
        _currentPanelType == EditorPanelType.emoji ||
        _currentPanelType == EditorPanelType.tools) {
      _intendedPanel = EditorPanelType.none;
      if (!_isDesktop) _updateReadOnly(false);
      _panelController.updatePanelType(
        ChatBottomPanelType.none,
        forceHandleFocus: ChatBottomHandleFocus.none,
      );
    }
  }

  /// 桌面端没有软键盘
  static final bool _isDesktop = PlatformUtils.isDesktop;

  /// 切换自定义面板（表情/工具）
  void _togglePanel(EditorPanelType type) {
    // 桌面端表情走悬浮弹层,不进 docked 容器
    if (_isDesktop && type == EditorPanelType.emoji) {
      _emojiPopover!.toggle(context, panel: _ensureEmojiPanelChild());
      return;
    }
    if (_intendedPanel == type) {
      // 关闭面板
      _intendedPanel = EditorPanelType.none;
      if (_isDesktop) {
        _panelController.updatePanelType(
          ChatBottomPanelType.none,
          forceHandleFocus: ChatBottomHandleFocus.none,
        );
        _focusNode.requestFocus();
      } else {
        _updateReadOnly(false);
        _panelController.updatePanelType(ChatBottomPanelType.keyboard);
      }
    } else {
      // 打开（或从另一个面板切换到）目标面板
      _intendedPanel = type;
      if (!_isDesktop) {
        _updateReadOnly(true);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _panelController.updatePanelType(
          ChatBottomPanelType.other,
          data: type,
          forceHandleFocus: ChatBottomHandleFocus.requestFocus,
        );
      });
    }
  }

  /// 工具面板执行操作后收起面板、切回键盘
  void _onToolPanelAction() {
    if (_intendedPanel == EditorPanelType.tools) {
      _togglePanel(EditorPanelType.tools);
    }
  }

  /// 更新 readOnly 状态
  void _updateReadOnly(bool value) {
    if (_readOnly != value) {
      setState(() => _readOnly = value);
    }
  }

  /// 编辑列下方空白区点击:等价"点在正文末尾"(聚焦 + 光标置末)。
  /// 外滚结构下 TextField 只占内容高,旧 expands 的整区可点由此兜底;
  /// readOnly(表情面板开)时与 TextField 的 Listener 同款切回键盘。
  void _onBlankAreaTap() {
    if (_readOnly) {
      _intendedPanel = EditorPanelType.none;
      _updateReadOnly(false);
      _panelController.updatePanelType(ChatBottomPanelType.keyboard);
    }
    _focusNode.requestFocus();
    widget.controller.selection = TextSelection.collapsed(
      offset: widget.controller.text.length,
    );
    _scrollToCursor();
  }

  /// 滚动到光标位置(视口内 no-op,越界才滚)。
  /// [animated] 默认 false:文本变化的同一帧里 EditableText 自身的
  /// showCaretOnScreen 会开启滚动活动,animateTo 的动画会被它同帧
  /// 取代而失效 —— 打字跟随必须 jumpTo(每次只差一行高,无感);
  /// 表情面板展开路径(延迟 200ms 后调用,无同帧竞争)传 true 平滑滚。
  void _scrollToCursor({bool animated = false}) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;

      final selection = widget.controller.selection;
      if (!selection.isValid) return;

      final renderObject = context.findRenderObject();
      if (renderObject == null) return;

      RenderEditable? editable;
      void find(RenderObject obj) {
        if (editable != null) return;
        if (obj is RenderEditable) {
          editable = obj;
        } else {
          obj.visitChildren(find);
        }
      }
      renderObject.visitChildren(find);

      if (editable == null) return;

      final caretLocal = editable!.getLocalRectForCaret(
        TextPosition(offset: selection.baseOffset),
      );

      final position = _scrollController.position;
      // 外滚结构:caret 是 RenderEditable 局部坐标,TextField 上方还有
      // header sliver —— 经全局坐标换算到滚动 viewport 局部
      // (0=视口顶部,viewportDimension=视口底部)再判越界。
      final viewportBox =
          position.context.storageContext.findRenderObject();
      if (viewportBox is! RenderBox || !viewportBox.attached) return;
      final topLeftGlobal = editable!.localToGlobal(caretLocal.topLeft);
      final caretTop = viewportBox.globalToLocal(topLeftGlobal).dy;
      final caretBottom = caretTop + caretLocal.height;

      double? target;
      if (caretBottom > position.viewportDimension) {
        // 光标在视口下方，需要向下滚
        target = position.pixels + caretBottom - position.viewportDimension + 8.0;
      } else if (caretTop < 0) {
        // 光标在视口上方，需要向上滚
        target = position.pixels + caretTop - 8.0;
      }

      if (target != null) {
        final clamped = target.clamp(0.0, position.maxScrollExtent);
        if (animated) {
          _scrollController.animateTo(
            clamped,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        } else {
          _scrollController.jumpTo(clamped);
        }
      }
    });
  }

  /// 请求焦点
  void requestFocus() {
    _focusNode.requestFocus();
  }

  /// 编辑区滚回顶部(header 含标题输入,校验失败等场景需拉回可见)
  void scrollToTop() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  /// 当前是否显示表情面板
  bool get showEmojiPanel => _isDesktop
      ? (_emojiPopover?.isOpen ?? false)
      : _intendedPanel == EditorPanelType.emoji;

  void _applyPanguSpacing() {
    if (_isApplyingPangu) return;
    final currentText = widget.controller.text;
    final selection = widget.controller.selection;
    if (currentText.isEmpty || !selection.isValid) return;
    // 有范围选中时不处理，避免破坏工具栏插入占位符后的选中状态
    if (!selection.isCollapsed) return;
    if (widget.controller.value.composing.isValid &&
        !widget.controller.value.composing.isCollapsed) {
      return;
    }

    final spacedText = _pangu.spacingText(currentText);
    if (spacedText == currentText) return;

    _isApplyingPangu = true;
    final cursor = selection.start.clamp(0, currentText.length);
    final prefix = currentText.substring(0, cursor);
    final newCursor = _pangu.spacingText(prefix).length;
    final clampedCursor = newCursor.clamp(0, spacedText.length);
    widget.controller.value = TextEditingValue(
      text: spacedText,
      selection: TextSelection.collapsed(offset: clampedCursor),
    );
    _previousText = spacedText;
    _isApplyingPangu = false;
  }

  /// 自定义粘贴回调：优先粘贴图片，无图片时回退文本粘贴
  void _handleCustomPaste(EditableTextState editableTextState) async {
    editableTextState.hideToolbar();

    final hasImage = await MarkdownToolbarState.clipboardHasImage();
    if (hasImage) {
      final clipboard = SystemClipboard.instance;
      if (clipboard != null) {
        final reader = await clipboard.read();
        final result = await MarkdownToolbarState.readImageFromReader(reader);
        if (result != null) {
          final (bytes, ext) = result;
          final fileName = 'paste_${DateTime.now().millisecondsSinceEpoch}.$ext';
          _toolbarKey.currentState?.uploadImageFromBytes(
            bytes: bytes,
            fileName: fileName,
          );
          return;
        }
      }
    }
    // 无图片，回退到默认文本粘贴
    editableTextState.pasteText(SelectionChangedCause.toolbar);
  }

  /// 自定义上下文菜单：替换粘贴按钮以支持图片粘贴
  Widget _buildContextMenu(BuildContext context, EditableTextState editableTextState) {
    final items = editableTextState.contextMenuButtonItems.toList();

    // 找到粘贴按钮并替换
    final pasteIndex = items.indexWhere(
      (item) => item.type == ContextMenuButtonType.paste,
    );
    if (pasteIndex != -1) {
      final originalPaste = items[pasteIndex];
      items[pasteIndex] = ContextMenuButtonItem(
        label: originalPaste.label,
        type: ContextMenuButtonType.paste,
        onPressed: () => _handleCustomPaste(editableTextState),
      );
    }

    // 默认列表无粘贴按钮（剪贴板只有图片时），异步检查并补充
    if (pasteIndex == -1) {
      return FutureBuilder<bool>(
        future: MarkdownToolbarState.clipboardHasImage(),
        builder: (context, snapshot) {
          final hasImage = snapshot.data ?? false;
          final finalItems = hasImage
              ? [
                  ...items,
                  ContextMenuButtonItem(
                    label: S.current.common_paste,
                    type: ContextMenuButtonType.paste,
                    onPressed: () => _handleCustomPaste(editableTextState),
                  ),
                ]
              : items;
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: editableTextState.contextMenuAnchors,
            buttonItems: finalItems,
          );
        },
      );
    }

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  /// 处理 Android 输入法直接粘贴的图片内容
  Future<void> _handleContentInserted(KeyboardInsertedContent content) async {
    if (!content.hasData) return;
    final data = content.data;
    if (data == null || data.isEmpty) return;

    final ext = content.mimeType.split('/').last;
    final fileName = 'ime_paste_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final tempDir = await getTemporaryDirectory();
    final tempFile = File(p.join(tempDir.path, fileName));
    await tempFile.writeAsBytes(data);

    if (!mounted) return;
    _toolbarKey.currentState?.uploadImageFromPath(
      imagePath: tempFile.path,
      imageName: fileName,
    );
  }

  /// 构建文本编辑器（可选包含 @提及自动补全）
  Widget _buildTextEditor() {
    final textField = TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      readOnly: _readOnly,
      showCursor: true,
      // 外滚结构:TextField 自身不滚(maxLines:null 全内容展开),
      // 滚动由外层 CustomScrollView 承担 —— header(标题/元数据)
      // 才能与正文同滚。光标跟随由 _scrollToCursor 补(外滚后
      // EditableText 的 showCaretOnScreen 只作用于内部零高滚动区)。
      // expands 语义改由外层 Expanded 空白点击区提供(见 build)。
      maxLines: null,
      minLines: widget.expands ? null : widget.minLines,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      contextMenuBuilder: _buildContextMenu,
      contentInsertionConfiguration: ContentInsertionConfiguration(
        allowedMimeTypes: const [
          'image/png',
          'image/jpeg',
          'image/gif',
          'image/webp',
        ],
        onContentInserted: _handleContentInserted,
      ),
      decoration: InputDecoration(
        hintText: widget.hintText.isEmpty ? S.current.editor_hintText : widget.hintText,
        border: InputBorder.none,
      ),
    );

    // 用 Listener 捕获点击：readOnly 模式下点击切回键盘
    final wrappedField = Listener(
      onPointerUp: (_) {
        if (_readOnly) {
          _intendedPanel = EditorPanelType.none;
          _updateReadOnly(false);
          _panelController.updatePanelType(ChatBottomPanelType.keyboard);
        }
      },
      // 桌面端格式化快捷键(Cmd/Ctrl+B/I/E/K 等,对齐 Discourse
      // composer;事实源 composer_shortcuts.dart):焦点在 TextField
      // 内时沿焦点链先命中本层,复用工具栏既有格式化 API。
      // 这些组合键均不在 DefaultTextEditingShortcuts 内,无冲突。
      child: _isDesktop
          ? CallbackShortcuts(
              bindings: {
                for (final spec in buildComposerShortcutSpecs())
                  spec.activator: () {
                    final toolbar = _toolbarKey.currentState;
                    if (toolbar != null) spec.sourceAction(toolbar);
                  },
              },
              child: textField,
            )
          : textField,
    );

    // 如果提供了 mentionDataSource，则包裹 MentionAutocomplete
    if (widget.mentionDataSource != null) {
      return MentionAutocomplete(
        controller: widget.controller,
        focusNode: _focusNode,
        dataSource: widget.mentionDataSource!,
        child: wrappedField,
      );
    }

    return wrappedField;
  }

  /// 自定义面板高度：键盘高度已知时直接使用（与 _KeyboardPlaceholder 等高），
  /// 否则用 emojiPanelHeight 兜底
  double get _panelHeight {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    final keyboardHeight = _panelController.keyboardHeight;
    return keyboardHeight > 0
        ? max(keyboardHeight, safeBottom)
        : max(widget.emojiPanelHeight, safeBottom);
  }

  /// 构建(或复用)EmojiStickerPanel 缓存实例,docked 与桌面悬浮弹层共用
  Widget _ensureEmojiPanelChild() {
    // EmojiStickerPanel 只创建一次(见 _emojiPanelChild 注释);
    // 高度变化只影响外层 SizedBox,不触达 grid 子树。
    _emojiPanelChild ??= EmojiStickerPanel(
      // 桌面悬浮弹层:搜索走内联视图,布局按小窗收紧;
      // 面板内开 Navigator 层 sheet(表情包市场)前先收弹层
      inlineSearch: _isDesktop,
      compact: _isDesktop,
      onDismissRequested: _isDesktop ? () => _emojiPopover?.hide() : null,
      onEmojiSelected: (emoji) {
        // 确保编辑器有焦点（搜索弹窗关闭后焦点可能丢失）
        if (!_focusNode.hasFocus) {
          _focusNode.requestFocus();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _toolbarKey.currentState?.insertText(':${emoji.name}:');
          });
        } else {
          _toolbarKey.currentState?.insertText(':${emoji.name}:');
        }
      },
      onStickerSelected: (markdown) {
        if (!_focusNode.hasFocus) {
          _focusNode.requestFocus();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _toolbarKey.currentState?.insertText(markdown);
          });
        } else {
          _toolbarKey.currentState?.insertText(markdown);
        }
      },
      onBackspace: () =>
          deleteBackwardWithEmojiShortcodes(widget.controller),
    );
    return _emojiPanelChild!;
  }

  /// 构建表情面板，高度与键盘一致
  Widget _buildEmojiPanel() {
    // TextFieldTapRegion 防止点击表情面板时 TextField 失焦
    return TextFieldTapRegion(
      child: SizedBox(
        height: _panelHeight,
        child: _ensureEmojiPanelChild(),
      ),
    );
  }

  /// 构建网格工具面板，高度与键盘一致
  Widget _buildToolPanel() {
    // TextFieldTapRegion 防止点击工具面板时 TextField 失焦
    return TextFieldTapRegion(
      child: SizedBox(
        height: _panelHeight,
        child: MarkdownToolPanel(
          toolbarKey: _toolbarKey,
          onAction: _onToolPanelAction,
          // 已开启自动混排时不显示该工具
          onApplyPangu: ref.read(preferencesProvider).autoPanguSpacing
              ? null
              : _applyPanguSpacing,
        ),
      ),
    );
  }

  /// 构建当前意图面板对应的组件（用于焦点竞争时维持面板显示）
  Widget _buildIntendedPanel() {
    return _intendedPanel == EditorPanelType.tools
        ? _buildToolPanel()
        : _buildEmojiPanel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        // 编辑/预览区域
        Expanded(
          child: _isPreview && widget.onTogglePreview == null
              ? SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.header != null) widget.header!,
                      Padding(
                        padding:
                            const EdgeInsets.fromLTRB(20, 16, 20, 16),
                        child: widget.controller.text.isEmpty
                            ? Text(
                                S.current.editor_noContent,
                                style: TextStyle(
                                    color: theme.colorScheme.onSurfaceVariant),
                              )
                            : MarkdownBody(
                                data: widget.controller.text,
                                // 预览里可缩放图(上传图)的 100/75/50 胶囊:
                                // 官方同款正则改 raw 的 `, N%` 后缀,预览随
                                // controller 变更自动重 cook。
                                onImageScaleChanged: (image, scale) {
                                  final next = applyImageScaleToRaw(
                                      widget.controller.text, image, scale);
                                  if (next != null) {
                                    widget.controller.text = next;
                                    setState(() {});
                                  }
                                },
                              ),
                      ),
                    ],
                  ),
                )
              // 外滚结构:header(标题/元数据)与 TextField 同在一个
              // CustomScrollView,写正文时头部随内容滚出屏。
              // SliverFillRemaining(hasScrollBody:false):内容短时编辑列
              // 仍撑满剩余视口,下方空白由 filler 接管点击(聚焦+光标置
              // 末,对齐旧 expands 整区可点行为)。TextField 支持内在
              // 高度计算,SliverFillRemaining 的 intrinsic 测量安全。
              : CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                    if (widget.header != null)
                      SliverToBoxAdapter(child: widget.header),
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            // 水平 20 = 与 header 标题对齐(富文本同值)
                            padding:
                                const EdgeInsets.symmetric(horizontal: 20),
                            child: _buildTextEditor(),
                          ),
                          // 空白填充区:点击等价"点在正文末尾"。包
                          // TextFieldTapRegion 防 TextField 的 onTapOutside
                          // 先收键盘再由我们重新聚焦(闪一下)。
                          Expanded(
                            child: TextFieldTapRegion(
                              child: MouseRegion(
                                cursor: SystemMouseCursors.text,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _onBlankAreaTap,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),

        // 底部属性条(分类/标签/字数常驻,不随滚动离场)
        if (widget.metaBar != null) widget.metaBar!,

        // 工具栏（纯按钮行，TextFieldTapRegion 防止点击时 TextField 失焦）
        TextFieldTapRegion(
          child: MarkdownToolbar(
          key: _toolbarKey,
          controller: widget.controller,
          focusNode: _focusNode,
          showPreviewButton: widget.showPreviewButton,
          isPreview: _isPreview,
          onTogglePreview: _togglePreview,
          onSwitchToRich: widget.onSwitchToRich,
          onApplyPangu: _applyPanguSpacing,
          showPanguButton: !ref.watch(preferencesProvider).autoPanguSpacing,
          onToggleEmoji: () => _togglePanel(EditorPanelType.emoji),
          isEmojiPanelVisible: showEmojiPanel,
          // 桌面端表情按钮由弹层锚点包裹(跟随定位 + toggle 无闪烁)
          emojiPopover: _emojiPopover,
          // 桌面端空间充足，显示全部工具，不启用网格面板
          onToggleTools:
              _isDesktop ? null : () => _togglePanel(EditorPanelType.tools),
          isToolsPanelVisible: _intendedPanel == EditorPanelType.tools,
          // 移动端中部只显示用户自定义的外显工具（默认空）
          visibleToolIds: _isDesktop
              ? null
              : ref.watch(preferencesProvider).editorToolbarTools,
        ),
        ),

        // 键盘/面板容器（管理键盘占位、表情面板、安全区域）
        ChatBottomPanelContainer<EditorPanelType>(
          controller: _panelController,
          inputFocusNode: _focusNode,
          otherPanelWidget: (type) {
            switch (type) {
              case EditorPanelType.emoji:
                return _buildEmojiPanel();
              case EditorPanelType.tools:
                return _buildToolPanel();
              default:
                return const SizedBox.shrink();
            }
          },
          onPanelTypeChange: (panelType, data) {
            EditorPanelType newType;
            switch (panelType) {
              case ChatBottomPanelType.none:
                newType = EditorPanelType.none;
              case ChatBottomPanelType.keyboard:
                newType = EditorPanelType.keyboard;
              case ChatBottomPanelType.other:
                newType = data ?? EditorPanelType.none;
            }

            // 自定义面板应保持打开时（如搜索弹窗导致的焦点变化），忽略其他状态请求
            if (_intendedPanel != EditorPanelType.none &&
                newType != _intendedPanel) {
              return;
            }

            bool isCustomPanel(EditorPanelType type) =>
                type == EditorPanelType.emoji || type == EditorPanelType.tools;

            final wasCustom = isCustomPanel(_currentPanelType);
            final wasNone = _currentPanelType == EditorPanelType.none;
            final isCustom = isCustomPanel(newType);

            setState(() {
              _currentPanelType = newType;
            });

            if (wasCustom != isCustom) {
              widget.onEmojiPanelChanged?.call(isCustom);
              // 面板展开后，等 AnimatedSize 动画（200ms）结束再滚动到光标位置
              if (isCustom && wasNone) {
                Future.delayed(const Duration(milliseconds: 200), () {
                  _scrollToCursor(animated: true);
                });
              }
            }
          },
          // 自定义面板容器：键盘和自定义面板等高，切换时工具栏位置不变
          customPanelContainer: (panelType, data) {
            // 自定义面板应保持打开时，无论 panelType 如何变化都继续显示该面板
            if (_intendedPanel != EditorPanelType.none &&
                panelType != ChatBottomPanelType.other) {
              return ColoredBox(
                color: theme.colorScheme.surface,
                child: _buildIntendedPanel(),
              );
            }
            switch (panelType) {
              case ChatBottomPanelType.keyboard:
                return _KeyboardPlaceholder(
                  color: theme.colorScheme.surface,
                  nativeKeyboardHeight: _panelController.keyboardHeight,
                );
              case ChatBottomPanelType.other:
                if (data == EditorPanelType.emoji) {
                  return ColoredBox(
                    color: theme.colorScheme.surface,
                    child: _buildEmojiPanel(),
                  );
                }
                if (data == EditorPanelType.tools) {
                  return ColoredBox(
                    color: theme.colorScheme.surface,
                    child: _buildToolPanel(),
                  );
                }
                return const SizedBox.shrink();
              case ChatBottomPanelType.none:
                return _SafeAreaPlaceholder(
                  color: theme.colorScheme.surface,
                );
            }
          },
        ),
      ],
    );
  }
}

/// 键盘占位组件：使用原生键盘高度，不使用 AnimatedSize，
/// 与表情面板共用同一高度源（nativeKeyboardHeight），确保切换时等高
class _KeyboardPlaceholder extends StatelessWidget {
  final Color color;
  final double nativeKeyboardHeight;

  const _KeyboardPlaceholder({
    required this.color,
    required this.nativeKeyboardHeight,
  });

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    final height = max(nativeKeyboardHeight, safeBottom);
    return ColoredBox(
      color: color,
      child: SizedBox(width: double.infinity, height: height),
    );
  }
}

/// 安全区域占位组件：无键盘时显示底部安全区域高度
class _SafeAreaPlaceholder extends StatelessWidget {
  final Color color;

  const _SafeAreaPlaceholder({required this.color});

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    return ColoredBox(
      color: color,
      child: SizedBox(width: double.infinity, height: safeBottom),
    );
  }
}
