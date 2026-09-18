import 'dart:async';
import 'dart:io';

import 'package:fluxdo_render/editor.dart'
    show
        observeModifierKeyEvent,
        primaryModifierHeldForReversibleAction,
        shiftModifierHeld;
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';

import '../../widgets/crypto/crypto_encrypt_sheet.dart';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:dio/dio.dart';

import '../../services/app_error_handler.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/toast_service.dart';
import '../../utils/platform_utils.dart';
import '../common/fading_edge_scroll_view.dart';
import '../content/discourse_html_content/image_utils.dart';
import 'composer_workbench.dart';
import 'composer_tool_style.dart';
import 'composer_desktop_layout.dart';
import 'composer_desktop_workbench.dart';
import 'composer_tools_anchor.dart';
import 'composer_view_mode_switcher.dart';
import 'cursor_swipe_control.dart';
import 'composer_shortcuts.dart';
import 'editor_tools.dart';
import 'emoji_popover.dart';
import 'media_upload_helper.dart';
import 'uploads/task_controller.dart';
import 'uploads/upload_task_panel.dart';
import 'uploads/markdown_insertion_anchor.dart';
import 'voice_recorder_sheet.dart';
import 'image_upload_dialog.dart';
import 'content_actions_button.dart';
import 'content_actions_providers.dart';
import 'link_insert_dialog.dart';
import 'poll_builder_dialog.dart';
import 'template_insert_dialog.dart';

import 'package:common_ui/common_ui.dart';

import '../../../../../l10n/s.dart';

/// Markdown 工具栏组件
/// 提供格式化按钮、预览切换和图片上传功能（纯按钮行，不含面板和间距）
class MarkdownToolbar extends StatefulWidget {
  /// 内容控制器（必需，用于文本操作）
  final TextEditingController controller;

  /// 内容焦点节点（可选，用于恢复焦点）
  final FocusNode? focusNode;

  /// 正文撤销历史（宿主与正文 TextField 共用同一实例；null = 不显示
  /// 撤销/恢复按钮，用于不带正文输入框的场景）
  final UndoHistoryController? undoController;

  /// 是否显示预览按钮
  final bool showPreviewButton;

  /// 预览状态
  final bool isPreview;

  /// 预览切换回调
  final VoidCallback? onTogglePreview;

  /// 源码 → 富文本切换(null = 不显示按钮)。
  final VoidCallback? onSwitchToRich;

  /// 混排优化按钮回调
  final VoidCallback? onApplyPangu;

  /// 是否显示混排优化按钮
  final bool showPanguButton;

  /// 表情按钮点击回调
  final VoidCallback? onToggleEmoji;

  /// 表情面板是否可见（控制表情/键盘按钮图标切换）
  final bool isEmojiPanelVisible;

  /// 展开/收起工具岛，两端共用。
  final VoidCallback? onToggleTools;

  /// 工具岛是否展开（控制入口高亮）。
  final bool isToolsPanelVisible;

  /// 外显工具 id 列表（见 editor_tools.dart）
  /// null = 显示全部工具；实际两端沿用用户固定列表，空列表不显示固定工具。
  final List<String>? visibleToolIds;

  /// 桌面端表情悬浮弹层控制器(非 null 时表情按钮被锚点包裹,
  /// 弹层跟随按钮定位且点按钮不触发弹层的 onTapOutside)
  final EmojiPopoverController? emojiPopover;
  final ComposerToolsAnchor? toolsAnchor;

  final Widget? metaBar;
  final VoidCallback? onResumeEditing;
  final void Function(int direction, {required bool extend})?
  onMoveCursorVertical;

  const MarkdownToolbar({
    super.key,
    required this.controller,
    this.focusNode,
    this.undoController,
    this.showPreviewButton = true,
    this.isPreview = false,
    this.onTogglePreview,
    this.onSwitchToRich,
    this.onApplyPangu,
    this.showPanguButton = false,
    this.onToggleEmoji,
    this.isEmojiPanelVisible = false,
    this.onToggleTools,
    this.isToolsPanelVisible = false,
    this.visibleToolIds,
    this.emojiPopover,
    this.toolsAnchor,
    this.metaBar,
    this.onResumeEditing,
    this.onMoveCursorVertical,
  });

  @override
  State<MarkdownToolbar> createState() => MarkdownToolbarState();
}

class MarkdownToolbarState extends State<MarkdownToolbar> {
  final _picker = ImagePicker();

  /// 宿主未传 focusNode 时的兑底（只建一次，不能在 build 里 new）
  FocusNode? _fallbackFocusNode;
  int _uploadingCount = 0;
  late MarkdownInsertionAnchors _uploadAnchors;
  final _uploads = UploadTaskController();

  /// 失败待处理的任务也阻止发布；媒体旧流程仍计入保护。
  bool get hasPendingUploads => _uploads.hasPending || _uploadingCount > 0;

  bool get isInsertingUpload => _uploadAnchors.isInserting;

  @override
  void initState() {
    super.initState();
    _uploadAnchors = MarkdownInsertionAnchors(widget.controller);
    HardwareKeyboard.instance.addHandler(_handleRawKeyEvent);
  }

  @override
  void didUpdateWidget(covariant MarkdownToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      for (final task in _uploads.tasks) {
        _uploads.remove(task.id);
      }
      _uploadAnchors.dispose();
      _uploadAnchors = MarkdownInsertionAnchors(widget.controller);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleRawKeyEvent);
    _uploads.dispose();
    _uploadAnchors.dispose();
    _fallbackFocusNode?.dispose();
    super.dispose();
  }

  /// 全局键盘事件处理，检测 Cmd+V / Ctrl+V 粘贴图片
  bool _handleRawKeyEvent(KeyEvent event) {
    // 先喂内核的修饰键跟踪:焦点在源码编辑器(普通 TextField)时内核的
    // handleEditorKeyEvent 收不到按键,本地 Shift 跟踪会冻结 ——
    // shiftModifierHeld 是合取语义(HardwareKeyboard 且 本地跟踪),不喂
    // 就恒 false,Ctrl+Shift+V 会被误判成 Ctrl+V 触发贴图。
    observeModifierKeyEvent(event);
    if (widget.focusNode == null || !widget.focusNode!.hasFocus) return false;
    // 贴图是**可逆**动作 → 用宽松版判定(真实状态 或 2s 补偿窗口):
    // Win+V 注入的 V 不带 Ctrl 修饰位,只认真实状态整条贴图路径失效。
    // Shift 用内核合取判定防 Windows 中文输入法切换导致的假按住,
    // Alt 无失真先例保持直读。
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        !shiftModifierHeld() &&
        !HardwareKeyboard.instance.isAltPressed &&
        primaryModifierHeldForReversibleAction(event)) {
      pasteImageFromClipboard();
      // 不返回 true：让 TextField 自行处理文本粘贴，
      // 仅在检测到图片时通过上传流程处理
      return false;
    }
    return false;
  }

  /// 支持的图片格式
  static const _imageFormats = [
    Formats.png,
    Formats.jpeg,
    Formats.gif,
    Formats.webp,
  ];

  /// 从 DataReader 读取图片字节（支持 PNG/JPEG/GIF/WebP）
  static Future<(Uint8List, String)?> readImageFromReader(
    DataReader reader,
  ) async {
    for (final format in _imageFormats) {
      if (reader.canProvide(format)) {
        final completer = Completer<Uint8List?>();
        reader.getFile(
          format,
          (file) async {
            final stream = file.getStream();
            final chunks = <int>[];
            await for (final chunk in stream) {
              chunks.addAll(chunk);
            }
            completer.complete(Uint8List.fromList(chunks));
          },
          onError: (error) {
            completer.complete(null);
          },
        );
        final bytes = await completer.future;
        if (bytes != null && bytes.isNotEmpty) {
          final ext = format == Formats.png
              ? 'png'
              : format == Formats.jpeg
              ? 'jpg'
              : format == Formats.gif
              ? 'gif'
              : 'webp';
          return (bytes, ext);
        }
      }
    }
    return null;
  }

  /// 快速检查剪贴板是否有图片
  static Future<bool> clipboardHasImage() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;
    final reader = await clipboard.read();
    for (final format in _imageFormats) {
      if (reader.canProvide(format)) return true;
    }
    return false;
  }

  /// 处理粘贴事件：仅检测剪贴板图片，文本粘贴由 TextField 自行处理
  Future<bool> pasteImageFromClipboard() async {
    final anchor = _uploadAnchors.capture();
    _uploadingCount++;
    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) return false;
      final reader = await clipboard.read();
      final result = await readImageFromReader(reader);
      if (result != null) {
        final (bytes, ext) = result;
        final tempDir = await getTemporaryDirectory();
        final fileName = 'paste_${DateTime.now().millisecondsSinceEpoch}.$ext';
        final tempFile = File(p.join(tempDir.path, fileName));
        await tempFile.writeAsBytes(bytes);

        if (!mounted) return false;
        await uploadImageFromPath(
          imagePath: tempFile.path,
          imageName: fileName,
          insertionAnchor: _uploadAnchors.fork(anchor),
        );
        return true;
      }
    } catch (_) {
      // 读取图片失败，忽略，文本粘贴由 TextField 自行处理
    } finally {
      _uploadingCount--;
      _uploadAnchors.release(anchor);
    }
    return false;
  }

  /// 从字节数据上传图片（供 markdown_editor.dart 调用）
  Future<void> uploadImageFromBytes({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final anchor = _uploadAnchors.capture();
    _uploadingCount++;
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(bytes);

      if (!mounted) return;
      await uploadImageFromPath(
        imagePath: tempFile.path,
        imageName: fileName,
        insertionAnchor: _uploadAnchors.fork(anchor),
      );
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      _uploadingCount--;
      _uploadAnchors.release(anchor);
    }
  }

  /// 插入文本到光标位置
  void insertText(String text) {
    final selection = widget.controller.selection;

    if (selection.isValid) {
      final newText = widget.controller.text.replaceRange(
        selection.start,
        selection.end,
        text,
      );
      final newSelectionIndex = selection.start + text.length;

      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newSelectionIndex),
      );
    } else {
      final currentText = widget.controller.text;
      final newText = '$currentText$text';
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
  }

  /// 用指定前后缀包裹选中文本（无选中时插入占位符并选中）
  void wrapSelection(String start, String end, {String? placeholder}) {
    final selection = widget.controller.selection;
    if (!selection.isValid) return;

    final text = widget.controller.text;

    if (selection.start == selection.end && placeholder != null) {
      // 没有选中文本，插入带占位符的内容
      final wrapped = '$start$placeholder$end';
      final insertPos = selection.start;
      final newText = text.replaceRange(insertPos, insertPos, wrapped);

      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: insertPos + start.length,
          extentOffset: insertPos + start.length + placeholder.length,
        ),
      );
      widget.focusNode?.requestFocus();
      return;
    }

    final selectedText = selection.textInside(text);
    final newText = text.replaceRange(
      selection.start,
      selection.end,
      '$start$selectedText$end',
    );

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: selection.start + start.length,
        extentOffset: selection.start + start.length + selectedText.length,
      ),
    );
  }

  /// 在行首添加前缀（用于标题、列表等）
  void applyLinePrefix(String prefix) {
    final selection = widget.controller.selection;
    final text = widget.controller.text;

    if (!selection.isValid) {
      // 没有选中，在文本末尾添加
      final newText = text.isEmpty ? prefix : '$text\n$prefix';
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
      return;
    }

    // 找到选中区域所在行的开始位置
    int lineStart = selection.start;
    while (lineStart > 0 && text[lineStart - 1] != '\n') {
      lineStart--;
    }

    // 检查行首是否已有相同前缀
    final lineEnd = text.indexOf('\n', lineStart);
    final currentLine = lineEnd == -1
        ? text.substring(lineStart)
        : text.substring(lineStart, lineEnd);

    if (currentLine.startsWith(prefix)) {
      // 已有前缀，移除它
      final newText = text.replaceRange(
        lineStart,
        lineStart + prefix.length,
        '',
      );
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start - prefix.length,
        ),
      );
    } else {
      // 添加前缀
      final newText = text.replaceRange(lineStart, lineStart, prefix);
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start + prefix.length,
        ),
      );
    }
  }

  /// 插入代码块（带占位符并自动选中）
  void insertCodeBlock() {
    final selection = widget.controller.selection;
    final text = widget.controller.text;

    if (!selection.isValid) {
      // 没有选中，在文本末尾插入
      final placeholder = S.current.toolbar_codePlaceholder;
      final codeBlock = '```\n$placeholder\n```';
      final newText = text.isEmpty ? codeBlock : '$text\n$codeBlock';
      final placeholderStart =
          newText.length - codeBlock.length + 4; // 4 = '```\n'.length

      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: placeholderStart,
          extentOffset: placeholderStart + placeholder.length,
        ),
      );
    } else {
      // 有选中文本，用代码块包裹
      final selectedText = selection.textInside(text);
      final codeBlock = '```\n$selectedText\n```';
      final newText = text.replaceRange(
        selection.start,
        selection.end,
        codeBlock,
      );

      // 选中代码块内的文本
      final contentStart = selection.start + 4; // 4 = '```\n'.length
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: contentStart,
          extentOffset: contentStart + selectedText.length,
        ),
      );
    }

    // 请求焦点以便用户可以立即开始输入
    widget.focusNode?.requestFocus();
  }

  /// 插入链接（显示对话框）
  Future<void> insertLink(BuildContext context) async {
    final selection = widget.controller.selection;
    final text = widget.controller.text;

    // 获取选中的文本作为初始链接文本
    String? initialText;
    if (selection.isValid && selection.start != selection.end) {
      initialText = selection.textInside(text);
    }

    // 显示对话框
    final result = await showLinkInsertDialog(
      context,
      initialText: initialText,
    );

    if (result == null) {
      // 用户取消
      widget.focusNode?.requestFocus();
      return;
    }

    final url = result['url']!;
    final rawText = result['text']!.trim();
    final linkText = rawText.isEmpty ? url : rawText;
    final link = '[$linkText]($url)';

    // 插入链接
    final insertPos = selection.isValid ? selection.start : text.length;
    final endPos = selection.isValid && selection.start != selection.end
        ? selection.end
        : insertPos;

    final newText = text.replaceRange(insertPos, endPos, link);

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: insertPos + link.length),
    );

    widget.focusNode?.requestFocus();
  }

  /// 插入删除线（带占位符并自动选中）
  void insertStrikethrough() {
    final selection = widget.controller.selection;
    final text = widget.controller.text;

    if (!selection.isValid || selection.start == selection.end) {
      // 没有选中文本，插入带占位符的删除线
      final placeholder = S.current.toolbar_strikethroughPlaceholder;
      final strikethrough = '~~$placeholder~~';
      final insertPos = selection.isValid ? selection.start : text.length;
      final newText = text.replaceRange(insertPos, insertPos, strikethrough);

      // 选中占位符
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: insertPos + 2, // 2 = '~~'.length
          extentOffset: insertPos + 2 + placeholder.length,
        ),
      );
    } else {
      // 有选中文本，用删除线包裹
      final selectedText = selection.textInside(text);
      final strikethrough = '~~$selectedText~~';
      final newText = text.replaceRange(
        selection.start,
        selection.end,
        strikethrough,
      );

      // 选中删除线内容
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: selection.start + 2,
          extentOffset: selection.start + 2 + selectedText.length,
        ),
      );
    }

    widget.focusNode?.requestFocus();
  }

  /// 插入剧透标记（带占位符并自动选中）
  void insertSpoiler() {
    final selection = widget.controller.selection;
    final text = widget.controller.text;

    if (!selection.isValid || selection.start == selection.end) {
      // 没有选中文本，插入带占位符的剧透
      final placeholder = S.current.toolbar_spoilerPlaceholder;
      final spoiler = '[spoiler]$placeholder[/spoiler]';
      final insertPos = selection.isValid ? selection.start : text.length;
      final newText = text.replaceRange(insertPos, insertPos, spoiler);

      // 选中占位符
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: insertPos + '[spoiler]'.length,
          extentOffset: insertPos + '[spoiler]'.length + placeholder.length,
        ),
      );
    } else {
      // 有选中文本，用剧透标记包裹
      final selectedText = selection.textInside(text);
      final spoiler = '[spoiler]$selectedText[/spoiler]';
      final newText = text.replaceRange(
        selection.start,
        selection.end,
        spoiler,
      );

      // 选中剧透内容
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: selection.start + '[spoiler]'.length,
          extentOffset:
              selection.start + '[spoiler]'.length + selectedText.length,
        ),
      );
    }

    widget.focusNode?.requestFocus();
  }

  /// 打开加解密工具箱加密面板，把选中内容加密为 ```enc 代码块。
  ///
  /// 有选中文本时预填明文并在返回后**替换选区**；无选中则插入光标处。
  Future<void> insertEncryptedBlock() async {
    final selection = widget.controller.selection;
    final text = widget.controller.text;

    String? initialText;
    if (selection.isValid && selection.start != selection.end) {
      initialText = selection.textInside(text);
    }

    final ciphertext = await showCryptoEncryptSheet(
      context: context,
      initialPlaintext: initialText,
    );

    if (ciphertext == null) {
      widget.focusNode?.requestFocus();
      return;
    }

    final block = '```enc\n$ciphertext\n```';
    final insertPos = selection.isValid ? selection.start : text.length;
    final endPos = selection.isValid && selection.start != selection.end
        ? selection.end
        : insertPos;

    final newText = text.replaceRange(insertPos, endPos, block);
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: insertPos + block.length),
    );

    widget.focusNode?.requestFocus();
  }

  /// 插入行内代码（带占位符并自动选中）
  void insertInlineCode() {
    final selection = widget.controller.selection;
    final text = widget.controller.text;

    if (!selection.isValid || selection.start == selection.end) {
      // 没有选中文本，插入带占位符的代码
      final placeholder = S.current.codeBlock_code;
      final code = '`$placeholder`';
      final insertPos = selection.isValid ? selection.start : text.length;
      final newText = text.replaceRange(insertPos, insertPos, code);

      // 选中占位符
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: insertPos + 1, // 1 = '`'.length
          extentOffset: insertPos + 1 + placeholder.length,
        ),
      );
    } else {
      // 有选中文本，用代码包裹
      final selectedText = selection.textInside(text);
      final code = '`$selectedText`';
      final newText = text.replaceRange(selection.start, selection.end, code);

      // 选中代码内容
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: selection.start + 1,
          extentOffset: selection.start + 1 + selectedText.length,
        ),
      );
    }

    widget.focusNode?.requestFocus();
  }

  /// 将选中的图片包裹为网格
  /// 如果没有选中，则查找光标附近的连续图片
  void wrapImagesInGrid() {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    if (!selection.isValid) return;

    // 图片 markdown 正则：![alt](url) 或 ![alt](url "title")
    final imageRegex = RegExp(r'!\[[^\]]*\]\([^)]+\)');

    // 如果有选中文本，检查是否包含图片
    if (selection.start != selection.end) {
      final selectedText = text.substring(selection.start, selection.end);
      final images = imageRegex.allMatches(selectedText).toList();

      if (images.length >= 2) {
        // 选中区域包含多张图片，直接包裹
        final wrappedText = '[grid]\n$selectedText\n[/grid]';
        final newText = text.replaceRange(
          selection.start,
          selection.end,
          wrappedText,
        );

        widget.controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(
            offset: selection.start + wrappedText.length,
          ),
        );
        widget.focusNode?.requestFocus();
        return;
      }
    }

    // 没有选中或选中区域图片不足，查找所有连续图片块
    final allImages = imageRegex.allMatches(text).toList();
    if (allImages.length < 2) {
      // 图片数量不足
      _showToast(S.current.toolbar_gridMinImages);
      return;
    }

    // 查找光标所在位置附近的连续图片块
    final cursorPos = selection.start;

    // 找到包含光标位置的连续图片组
    int? groupStart;
    int? groupEnd;
    int consecutiveStart = 0;

    for (int i = 0; i < allImages.length; i++) {
      final match = allImages[i];

      // 检查是否与前一个图片连续（之间只有空白）
      if (i == 0) {
        consecutiveStart = i;
      } else {
        final prevMatch = allImages[i - 1];
        final between = text.substring(prevMatch.end, match.start);
        if (between.trim().isNotEmpty) {
          // 不连续，开始新组
          consecutiveStart = i;
        }
      }

      // 检查光标是否在这个图片附近
      if (cursorPos >= allImages[consecutiveStart].start &&
          cursorPos <= match.end + 10) {
        groupStart = allImages[consecutiveStart].start;
        groupEnd = match.end;

        // 继续查找后续连续的图片
        for (int j = i + 1; j < allImages.length; j++) {
          final nextMatch = allImages[j];
          final between = text.substring(allImages[j - 1].end, nextMatch.start);
          if (between.trim().isEmpty) {
            groupEnd = nextMatch.end;
          } else {
            break;
          }
        }
        break;
      }
    }

    if (groupStart == null || groupEnd == null) {
      // 找不到光标附近的图片组，使用所有图片
      groupStart = allImages.first.start;
      groupEnd = allImages.last.end;
    }

    // 检查选中的图片数量
    final groupText = text.substring(groupStart, groupEnd);
    final groupImages = imageRegex.allMatches(groupText).toList();

    if (groupImages.length < 2) {
      _showToast(S.current.toolbar_gridNeedConsecutive);
      return;
    }

    // 检查是否已经在 grid 内
    final beforeGroup = text.substring(0, groupStart);
    final afterGroup = text.substring(groupEnd);
    if (beforeGroup.trimRight().endsWith('[grid]') &&
        afterGroup.trimLeft().startsWith('[/grid]')) {
      _showToast(S.current.toolbar_imagesAlreadyInGrid);
      return;
    }

    // 包裹图片
    final wrappedText = '[grid]\n$groupText\n[/grid]';
    final newText = text.replaceRange(groupStart, groupEnd, wrappedText);

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        offset: groupStart + wrappedText.length,
      ),
    );
    widget.focusNode?.requestFocus();
  }

  void _showToast(String message) {
    ToastService.showInfo(message);
  }

  /// 插入模板（显示模板选择弹窗）
  Future<void> insertTemplate(BuildContext context) async {
    final template = await showTemplateInsertDialog(context);
    if (template == null) {
      widget.focusNode?.requestFocus();
      return;
    }
    insertText(template.content);
    widget.focusNode?.requestFocus();
  }

  /// 插入 Obsidian Callout（带占位符并自动选中）
  void insertCallout(String type) {
    final selection = widget.controller.selection;
    final text = widget.controller.text;
    final placeholder = S.current.toolbar_calloutPlaceholder;

    if (!selection.isValid || selection.start == selection.end) {
      // 没有选中文本，插入带占位符的 callout
      final callout = '> [!$type]\n> $placeholder';
      final insertPos = selection.isValid ? selection.start : text.length;

      final needNewline = insertPos > 0 && text[insertPos - 1] != '\n';
      final newText = text.replaceRange(
        insertPos,
        insertPos,
        needNewline ? '\n$callout' : callout,
      );

      // 选中占位符
      final placeholderStart =
          insertPos + (needNewline ? 1 : 0) + '> [!$type]\n> '.length;
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: placeholderStart,
          extentOffset: placeholderStart + placeholder.length,
        ),
      );
    } else {
      // 有选中文本，将每行添加 > 前缀并加上 callout 头
      final selectedText = selection.textInside(text);
      final lines = selectedText.split('\n');
      final quotedLines = lines.map((line) => '> $line').join('\n');
      final callout = '> [!$type]\n$quotedLines';

      final newText = text.replaceRange(
        selection.start,
        selection.end,
        callout,
      );

      final contentStart = selection.start + '> [!$type]\n'.length;
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: contentStart,
          extentOffset: contentStart + quotedLines.length,
        ),
      );
    }

    widget.focusNode?.requestFocus();
  }

  /// 插入引用（带占位符并自动选中）
  void insertQuote() {
    final selection = widget.controller.selection;
    final text = widget.controller.text;

    if (!selection.isValid || selection.start == selection.end) {
      // 没有选中文本，插入带占位符的引用
      final placeholder = S.current.toolbar_quotePlaceholder;
      final quote = '> $placeholder';
      final insertPos = selection.isValid ? selection.start : text.length;

      // 如果不在行首，先添加换行
      final needNewline = insertPos > 0 && text[insertPos - 1] != '\n';
      final newText = text.replaceRange(
        insertPos,
        insertPos,
        needNewline ? '\n$quote' : quote,
      );

      // 选中占位符
      final placeholderStart =
          insertPos + (needNewline ? 1 : 0) + 2; // '> '.length
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: placeholderStart,
          extentOffset: placeholderStart + placeholder.length,
        ),
      );
    } else {
      // 有选中文本，在行首添加 >
      applyLinePrefix('> ');
      return;
    }

    widget.focusNode?.requestFocus();
  }

  /// 从文件路径上传图片（公开方法，供外部调用）
  /// 上传成功后把 short_url → 完整 url 预置进解析缓存，
  /// 编辑器预览里的 upload:// 新图不用再发 lookup-urls 请求
  void _seedUploadCache(UploadResult uploadResult) {
    final url = uploadResult.url;
    if (url != null) {
      DiscourseImageUtils.seedUploadUrl(uploadResult.shortUrl, url);
    }
  }

  void _enqueueUpload({
    required String path,
    required String name,
    required MarkdownInsertionAnchor anchor,
    required bool image,
  }) {
    _uploads.add(
      UploadTaskRequest(
        path: path,
        name: name,
        isImage: image,
        execute: (token, progress) => image
            ? DiscourseService().uploadImage(
                path,
                cancelToken: token,
                onProgress: progress,
              )
            : DiscourseService().uploadFile(
                path,
                cancelToken: token,
                onProgress: progress,
              ),
        onCompleted: (task, result) {
          if (!mounted) return;
          _seedUploadCache(result);
          _uploadAnchors.insertBlock(
            anchor,
            image ? result.toMarkdown(alt: name) : result.toAutoMarkdown(),
          );
        },
      ),
    );
  }

  Future<void> uploadImageFromPath({
    required String imagePath,
    required String imageName,
    MarkdownInsertionAnchor? insertionAnchor,
  }) async {
    final anchor = insertionAnchor ?? _uploadAnchors.capture();
    var registered = false;
    _uploadingCount++;
    try {
      if (!mounted) return;
      final result = await showImageUploadDialog(
        context,
        imagePath: imagePath,
        imageName: imageName,
      );
      if (result == null || !mounted) return;
      _enqueueUpload(
        path: result.path,
        name: result.originalName,
        anchor: anchor,
        image: true,
      );
      registered = true;
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      _uploadingCount--;
      if (!registered) _uploadAnchors.release(anchor);
    }
  }

  /// 在选择器打开前捕获位置，不以网络完成时的光标为准。
  Future<void> pickAndUploadImages() async {
    final anchor = _uploadAnchors.capture();
    _uploadingCount++;
    try {
      final images = await _picker.pickMultiImage();
      if (!mounted || images.isEmpty) return;
      if (images.length == 1) {
        await uploadImageFromPath(
          imagePath: images.first.path,
          imageName: images.first.name,
          insertionAnchor: _uploadAnchors.fork(anchor),
        );
        return;
      }
      final results = await showMultiImageUploadDialog(
        context,
        imagePaths: images.map((e) => e.path).toList(),
        imageNames: images.map((e) => e.name).toList(),
      );
      if (!mounted || results == null || results.isEmpty) return;
      // 先创建全部锚点，完成顺序不影响正文中的原始选择顺序。
      final anchors = [for (final _ in results) _uploadAnchors.fork(anchor)];
      for (var i = 0; i < results.length; i++) {
        _enqueueUpload(
          path: results[i].path,
          name: results[i].originalName,
          anchor: anchors[i],
          image: true,
        );
      }
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      _uploadingCount--;
      _uploadAnchors.release(anchor);
    }
  }

  Future<void> pickAndUploadFile() async {
    final anchor = _uploadAnchors.capture();
    var registered = false;
    _uploadingCount++;
    try {
      final result = await FilePicker.platform.pickFiles();
      if (!mounted || result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.path == null) return;
      _enqueueUpload(
        path: file.path!,
        name: file.name,
        anchor: anchor,
        image: false,
      );
      registered = true;
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      _uploadingCount--;
      if (!registered) _uploadAnchors.release(anchor);
    }
  }

  /// 音/视频改名上传(.xz 绕扩展名白名单,4MB 上限)→ 插 HTML 标签。
  Future<bool> _prepareMediaTask({
    required String path,
    required String name,
    required bool isAudio,
    required MarkdownInsertionAnchor anchor,
    bool voice = false,
  }) async {
    final prepared = await prepareMediaUpload(
      context,
      path: path,
      name: name,
      isAudio: isAudio,
      voice: voice,
    );
    if (prepared == null || !mounted) return false;
    _uploads.add(
      UploadTaskRequest(
        path: prepared.path,
        name: prepared.name,
        execute: prepared.execute,
        onCompleted: (task, result) {
          if (!mounted) return;
          _uploadAnchors.insertBlock(anchor, prepared.markdown(result));
        },
      ),
    );
    return true;
  }

  Future<void> pickAndUploadMedia({required bool isAudio}) async {
    final anchor = _uploadAnchors.capture();
    var registered = false;
    _uploadingCount++;
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: isAudio ? FileType.audio : FileType.video,
      );
      if (!mounted || picked == null || picked.files.isEmpty) return;
      final file = picked.files.first;
      if (file.path == null) return;
      registered = await _prepareMediaTask(
        path: file.path!,
        name: file.name,
        isAudio: isAudio,
        anchor: anchor,
      );
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      _uploadingCount--;
      if (!registered) _uploadAnchors.release(anchor);
    }
  }

  /// 插入块级模板(表格/公式/分隔线/details):独占行语义,光标前
  /// 非行首先补换行(与媒体标签插入同款;模板文本与富 composer 的
  /// 「+」插入菜单一致)。
  void insertBlockSnippet(String snippet) {
    final selection = widget.controller.selection;
    final text = widget.controller.text;
    final needsLeadingNewline =
        selection.isValid &&
        selection.start > 0 &&
        text[selection.start - 1] != '\n';
    final prefix = needsLeadingNewline ? '\n' : '';
    insertText('$prefix$snippet\n');
  }

  /// 插入投票:构建对话框 → [poll] BBCode 块级插入。同帖多投票时
  /// name 必须唯一,按现有文本统计 poll 数决定 name=pollN。
  Future<void> insertPoll(BuildContext context) async {
    final existing = RegExp(r'\[poll[\s\]]')
        .allMatches(widget.controller.text)
        .length;
    final spec = await showPollBuilderDialog(
      context,
      existingPollCount: existing,
    );
    if (spec == null || !mounted) return;
    insertBlockSnippet(spec.toBBCode(existingPollCount: existing));
  }

  /// 语音消息:录音面板 → 上传([wrap=voice] 语音条标签)→ 插入。
  Future<void> recordAndInsertVoice() async {
    final anchor = _uploadAnchors.capture();
    var registered = false;
    _uploadingCount++;
    try {
      final path = await showVoiceRecorderSheet(context);
      if (path == null || !mounted) return;
      registered = await _prepareMediaTask(
        path: path,
        name: p.basename(path),
        isAudio: true,
        voice: true,
        anchor: anchor,
      );
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    } finally {
      _uploadingCount--;
      if (!registered) _uploadAnchors.release(anchor);
    }
  }

  /// 构建中部滚动区域的工具按钮
  ///
  /// 两端按用户保存的顺序显示固定工具；null 仅作为独立使用时的兼容默认值。
  List<Widget> _buildToolButtons({bool anchored = true}) {
    final ids = widget.visibleToolIds;
    final tools = ids == null ? editorTools : resolveVisibleTools(ids);

    return [
      for (final tool in tools)
        if (anchored)
          widget.toolsAnchor?.compactControl(_buildToolButton(tool)) ??
              _buildToolButton(tool)
        else
          _buildToolButton(tool, anchored: false),
    ];
  }

  Widget _buildToolButton(EditorTool tool, {bool anchored = true}) {
    final icon = anchored
        ? widget.toolsAnchor?.icon(tool.id, tool.icon) ?? tool.icon
        : tool.icon;
    final s = S.current;
    // 桌面端 tooltip 标注快捷键(如「粗体 (⌘B)」;移动端无物理键盘不标)
    final hint = PlatformUtils.isDesktop ? composerShortcutHint(tool.id) : null;
    final tooltip = '${tool.label(s)}${hint ?? ''}';

    if (tool.hasMenu) {
      final theme = Theme.of(context);
      return SwipeDismissiblePopupMenuButton<String>(
        icon: IconTheme.merge(
          data: IconThemeData(
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          child: icon,
        ),
        tooltip: tooltip,
        itemBuilder: (context) => tool.menuItems!(s),
        onSelected: (value) => anchored
            ? tool.onMenuSelected!(this, value)
            : _desktopAction(() => tool.onMenuSelected!(this, value)),
        padding: EdgeInsets.zero,
        iconSize: 20,
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      );
    }

    return _ToolbarButton(
      icon: icon,
      onPressed: () => anchored
          ? tool.action!(this)
          : _desktopAction(() => tool.action!(this)),
      tooltip: tooltip,
    );
  }

  Widget _buildEmojiButton(ThemeData theme) {
    final button = IconButton(
      icon: Icon(
        widget.isEmojiPanelVisible && widget.emojiPopover == null
            ? Symbols.keyboard_rounded
            : Symbols.sentiment_satisfied_rounded,
      ),
      tooltip: S.current.emoji_tab,
      onPressed: widget.onToggleEmoji,
      isSelected: widget.isEmojiPanelVisible,
      style: composerToolButtonStyle(
        context,
        active: widget.isEmojiPanelVisible,
      ),
    );
    final popover = widget.emojiPopover;
    return popover == null
        ? button
        : EmojiPopoverAnchor(
            controller: popover,
            preferSide:
                ComposerDesktopViewport.maybeOf(context)?.useRail ?? false,
            child: button,
          );
  }

  void _moveCursor(int direction, {required bool extend}) {
    final next = moveTextSelectionByGrapheme(
      widget.controller.value,
      direction,
      extend: extend,
    );
    if (next != null) widget.controller.selection = next;
  }

  Widget _contentActions() {
    final undo = widget.undoController!;
    return ContentActionsButton(
      provider: SourceContentActions(
        controller: widget.controller,
        undoController: undo,
        focusNode: widget.focusNode ?? (_fallbackFocusNode ??= FocusNode()),
      ),
      listenable: Listenable.merge([undo, widget.controller]),
    );
  }

  Widget _buildToolsButton(ThemeData theme) => ComposerToolsToggle(
    anchor: widget.toolsAnchor,
    active: widget.isToolsPanelVisible,
    compact: false,
    onPressed: widget.onToggleTools,
  );

  void _desktopAction(VoidCallback action) {
    widget.toolsAnchor?.dismiss();
    widget.onResumeEditing?.call();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = ComposerDesktopViewport.maybeOf(context);
    if (PlatformUtils.isDesktop && viewport != null) {
      // 桌面工作区是铺满编辑区域的定位 Stack，不能作为 Column 的
      // 非 flex 子节点，否则失去高度约束，所有 TapRegion 都无法布局。
      return Stack(
        children: [
          Positioned.fill(child: _buildWorkbench(context)),
          Positioned(
            top: viewport.topInset + 8,
            left: viewport.useRail
                ? ComposerDesktopViewport.documentSideInset
                : 16,
            right: viewport.useRail
                ? ComposerDesktopViewport.documentSideInset
                : 16,
            child: SourceUploadPanel(controller: _uploads),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SourceUploadPanel(controller: _uploads),
        _buildWorkbench(context),
      ],
    );
  }

  Widget _buildWorkbench(BuildContext context) {
    final theme = Theme.of(context);
    if (PlatformUtils.isDesktop &&
        ComposerDesktopViewport.maybeOf(context) != null) {
      final undo = widget.undoController;
      return ComposerDesktopWorkbench(
        anchor: widget.toolsAnchor,
        onExpandTools: widget.onToggleTools,
        emoji: _buildEmojiButton(theme),
        tools: _buildToolButtons(anchored: false),
        contentActions: undo == null ? null : _contentActions(),
        history: [
          if (undo != null)
            for (final redo in [false, true])
              ValueListenableBuilder(
                valueListenable: undo,
                builder: (context, value, _) => IconButton(
                  tooltip:
                      '${redo ? S.current.toolbar_redo : S.current.toolbar_undo}${composerShortcutHint(redo ? 'redo' : 'undo') ?? ''}',
                  icon: Icon(redo ? AppIcons.redo : AppIcons.undo, size: 20),
                  onPressed: (redo ? value.canRedo : value.canUndo)
                      ? () => _desktopAction(redo ? undo.redo : undo.undo)
                      : null,
                ),
              ),
        ],
        controls: [
          if (widget.onSwitchToRich != null)
            ComposerModeButton(rich: false, onPressed: widget.onSwitchToRich),
          if (widget.showPreviewButton)
            ComposerPreviewButton(
              previewing: widget.isPreview,
              onPressed: widget.onTogglePreview,
            ),
        ],
      );
    }
    return ComposerWorkbench(
      toolsAnchor: widget.toolsAnchor,
      onExpandTools: widget.onToggleTools,
      metadata: widget.metaBar,
      controls: [
        if (!PlatformUtils.isDesktop)
          ComposerEditingControls(
            children: [
              if (widget.undoController != null) _contentActions(),
              CursorSwipeControl(
                onMove: _moveCursor,
                onMoveVertical: widget.onMoveCursorVertical,
              ),
            ],
          ),
        if (widget.onSwitchToRich != null)
          ComposerModeButton(rich: false, onPressed: widget.onSwitchToRich),
        if (widget.showPreviewButton)
          ComposerPreviewButton(
            previewing: widget.isPreview,
            onPressed: widget.onTogglePreview,
          ),
      ],
      tools: Row(
        children: [
          _buildEmojiButton(theme),
          const SizedBox(width: 3),
          Expanded(
            child: ComposerCompactTools(
              anchor: widget.toolsAnchor,
              child: FadingEdgeScrollView(
                fadeLeft: true,
                fadeRight: true,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: _buildToolButtons()),
                ),
              ),
            ),
          ),
          if (widget.onToggleTools != null) _buildToolsButton(theme),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  const _ToolbarButton({required this.icon, this.onPressed, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final child = IconTheme.merge(
      data: const IconThemeData(size: 16),
      child: icon,
    );

    return IconButton(
      visualDensity: VisualDensity.standard,
      icon: child,
      onPressed: onPressed,
      tooltip: tooltip,
      style: composerToolButtonStyle(context),
    );
  }
}
