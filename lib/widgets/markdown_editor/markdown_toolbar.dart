import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'package:dio/dio.dart';
import '../../services/app_error_handler.dart';
import '../../services/discourse/discourse_service.dart';
import '../../services/toast_service.dart';
import '../common/fading_edge_scroll_view.dart';
import 'image_upload_dialog.dart';
import 'link_insert_dialog.dart';
import 'template_insert_dialog.dart';
import '../common/dismissible_popup_menu.dart';
import '../../../../../l10n/s.dart';

/// Markdown 工具栏组件
/// 提供格式化按钮、预览切换和图片上传功能（纯按钮行，不含面板和间距）
class MarkdownToolbar extends StatefulWidget {
  /// 内容控制器（必需，用于文本操作）
  final TextEditingController controller;

  /// 内容焦点节点（可选，用于恢复焦点）
  final FocusNode? focusNode;

  /// 是否显示预览按钮
  final bool showPreviewButton;

  /// 预览状态
  final bool isPreview;

  /// 预览切换回调
  final VoidCallback? onTogglePreview;

  /// 混排优化按钮回调
  final VoidCallback? onApplyPangu;

  /// 是否显示混排优化按钮
  final bool showPanguButton;

  /// 表情按钮点击回调
  final VoidCallback? onToggleEmoji;

  /// 表情面板是否可见（控制表情/键盘按钮图标切换）
  final bool isEmojiPanelVisible;

  const MarkdownToolbar({
    super.key,
    required this.controller,
    this.focusNode,
    this.showPreviewButton = true,
    this.isPreview = false,
    this.onTogglePreview,
    this.onApplyPangu,
    this.showPanguButton = false,
    this.onToggleEmoji,
    this.isEmojiPanelVisible = false,
  });

  @override
  State<MarkdownToolbar> createState() => MarkdownToolbarState();
}

class MarkdownToolbarState extends State<MarkdownToolbar> {
  final _picker = ImagePicker();
  int _uploadingCount = 0;
  String? _uploadProgress; // 批量上传进度，如 "3/22"
  bool get _isUploading => _uploadingCount > 0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleRawKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleRawKeyEvent);
    super.dispose();
  }

  /// 全局键盘事件处理，检测 Cmd+V / Ctrl+V 粘贴图片
  bool _handleRawKeyEvent(KeyEvent event) {
    if (widget.focusNode == null || !widget.focusNode!.hasFocus) return false;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed)) {
      _handlePasteImage();
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
  static Future<(Uint8List, String)?> readImageFromReader(DataReader reader) async {
    for (final format in _imageFormats) {
      if (reader.canProvide(format)) {
        final completer = Completer<Uint8List?>();
        reader.getFile(format, (file) async {
          final stream = file.getStream();
          final chunks = <int>[];
          await for (final chunk in stream) {
            chunks.addAll(chunk);
          }
          completer.complete(Uint8List.fromList(chunks));
        }, onError: (error) {
          completer.complete(null);
        });
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
  Future<void> _handlePasteImage() async {
    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) return;
      final reader = await clipboard.read();
      final result = await readImageFromReader(reader);
      if (result != null) {
        final (bytes, ext) = result;
        final tempDir = await getTemporaryDirectory();
        final fileName = 'paste_${DateTime.now().millisecondsSinceEpoch}.$ext';
        final tempFile = File(p.join(tempDir.path, fileName));
        await tempFile.writeAsBytes(bytes);

        if (!mounted) return;
        await uploadImageFromPath(imagePath: tempFile.path, imageName: fileName);
      }
    } catch (_) {
      // 读取图片失败，忽略，文本粘贴由 TextField 自行处理
    }
  }

  /// 从字节数据上传图片（供 markdown_editor.dart 调用）
  Future<void> uploadImageFromBytes({required Uint8List bytes, required String fileName}) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(bytes);

      if (!mounted) return;
      await uploadImageFromPath(imagePath: tempFile.path, imageName: fileName);
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
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
      final newText = text.replaceRange(lineStart, lineStart + prefix.length, '');
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
      final placeholderStart = newText.length - codeBlock.length + 4; // 4 = '```\n'.length

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

    final linkText = result['text']!;
    final url = result['url']!;
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
          extentOffset: selection.start + '[spoiler]'.length + selectedText.length,
        ),
      );
    }

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
      final newText = text.replaceRange(
        selection.start,
        selection.end,
        code,
      );

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
        final newText = text.replaceRange(selection.start, selection.end, wrappedText);

        widget.controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: selection.start + wrappedText.length),
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
      if (cursorPos >= allImages[consecutiveStart].start && cursorPos <= match.end + 10) {
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
    if (beforeGroup.trimRight().endsWith('[grid]') && afterGroup.trimLeft().startsWith('[/grid]')) {
      _showToast(S.current.toolbar_imagesAlreadyInGrid);
      return;
    }

    // 包裹图片
    final wrappedText = '[grid]\n$groupText\n[/grid]';
    final newText = text.replaceRange(groupStart, groupEnd, wrappedText);

    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: groupStart + wrappedText.length),
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
      final placeholderStart = insertPos + (needNewline ? 1 : 0) + '> [!$type]\n> '.length;
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
      final placeholderStart = insertPos + (needNewline ? 1 : 0) + 2; // '> '.length
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
  Future<void> uploadImageFromPath({required String imagePath, required String imageName}) async {
    try {
      // 显示确认弹框
      if (!mounted) return;
      final result = await showImageUploadDialog(
        context,
        imagePath: imagePath,
        imageName: imageName,
      );
      if (result == null) return; // 用户取消

      setState(() => _uploadingCount++);

      try {
        final service = DiscourseService();
        final uploadResult = await service.uploadImage(result.path);

        if (!mounted) return;
        // 使用 Discourse 格式：![alt|widthxheight](url)
        // 图片独占一行：光标前不是换行符或文本开头时，先补一个换行
        final selection = widget.controller.selection;
        final text = widget.controller.text;
        final needsLeadingNewline = selection.isValid &&
            selection.start > 0 &&
            text[selection.start - 1] != '\n';
        final prefix = needsLeadingNewline ? '\n' : '';
        insertText('$prefix${uploadResult.toMarkdown(alt: result.originalName)}\n');
      } finally {
        if (mounted) {
          setState(() => _uploadingCount--);
        }
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  Future<void> _pickAndUploadImages() async {
    try {
      final List<XFile> images = await _picker.pickMultiImage();
      if (images.isEmpty) return;

      // 只选了一张，走单图流程
      if (images.length == 1) {
        await uploadImageFromPath(
          imagePath: images.first.path,
          imageName: images.first.name,
        );
        return;
      }

      // 多张图片，走多图确认弹框
      if (!mounted) return;
      final results = await showMultiImageUploadDialog(
        context,
        imagePaths: images.map((e) => e.path).toList(),
        imageNames: images.map((e) => e.name).toList(),
      );
      if (results == null || results.isEmpty) return;

      final count = results.length;
      setState(() => _uploadingCount += count);

      try {
        final service = DiscourseService();

        // 串行上传，避免触发服务端速率限制
        final markdowns = <String>[];
        for (int i = 0; i < results.length; i++) {
          final result = results[i];
          if (mounted) {
            setState(() => _uploadProgress = '${i + 1}/${results.length}');
          }
          final uploadResult = await service.uploadImage(result.path);
          markdowns.add(uploadResult.toMarkdown(alt: result.originalName));
        }

        if (!mounted) return;

        // 插入 markdown
        final selection = widget.controller.selection;
        final text = widget.controller.text;
        final needsLeadingNewline = selection.isValid &&
            selection.start > 0 &&
            text[selection.start - 1] != '\n';
        final prefix = needsLeadingNewline ? '\n' : '';

        if (markdowns.length >= 3) {
          // ≥3 张自动包裹 [grid]
          insertText('$prefix[grid]\n${markdowns.join('\n')}\n[/grid]\n');
        } else {
          insertText('$prefix${markdowns.join('\n')}\n');
        }
      } finally {
        if (mounted) {
          setState(() {
            _uploadingCount -= count;
            _uploadProgress = null;
          });
        }
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  /// 选择并上传附件（支持任意文件类型）
  Future<void> _pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.path == null) return;

      setState(() => _uploadingCount++);

      try {
        final service = DiscourseService();
        final uploadResult = await service.uploadFile(file.path!);

        if (!mounted) return;

        final selection = widget.controller.selection;
        final text = widget.controller.text;
        final needsLeadingNewline = selection.isValid &&
            selection.start > 0 &&
            text[selection.start - 1] != '\n';
        final prefix = needsLeadingNewline ? '\n' : '';
        insertText('$prefix${uploadResult.toAutoMarkdown()}\n');
      } finally {
        if (mounted) {
          setState(() => _uploadingCount--);
        }
      }
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha:0.5),
            width: 0.5,
          ),
        ),
      ),
      child: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              // 表情按钮
              IconButton(
                icon: FaIcon(
                  widget.isEmojiPanelVisible
                      ? FontAwesomeIcons.keyboard
                      : FontAwesomeIcons.faceSmile,
                  size: 20,
                  color: widget.isEmojiPanelVisible
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: widget.onToggleEmoji,
              ),
              Container(
                height: 20,
                width: 1,
                color: theme.colorScheme.outlineVariant,
                margin: const EdgeInsets.symmetric(horizontal: 4),
              ),
              // Markdown 工具按钮 (可滚动)
              Expanded(
                child: FadingEdgeScrollView(
                  fadeLeft: true,
                  fadeRight: true,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _ToolbarButton(
                          icon: FontAwesomeIcons.image,
                          onPressed: _isUploading ? null : _pickAndUploadImages,
                          isLoading: _isUploading,
                          label: _uploadProgress,
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.paperclip,
                          onPressed: _isUploading ? null : _pickAndUploadFile,
                          tooltip: S.current.toolbar_attachFileTooltip,
                        ),
                        // 标题按钮（带弹出菜单）
                        SwipeDismissiblePopupMenuButton<int>(
                          icon: FaIcon(
                            FontAwesomeIcons.heading,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          itemBuilder: (context) => [
                            PopupMenuItem(value: 1, child: Text(S.current.toolbar_h1)),
                            PopupMenuItem(value: 2, child: Text(S.current.toolbar_h2)),
                            PopupMenuItem(value: 3, child: Text(S.current.toolbar_h3)),
                            PopupMenuItem(value: 4, child: Text(S.current.toolbar_h4)),
                            PopupMenuItem(value: 5, child: Text(S.current.toolbar_h5)),
                          ],
                          onSelected: (level) {
                            applyLinePrefix('${'#' * level} ');
                          },
                          padding: EdgeInsets.zero,
                          iconSize: 20,
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.bold,
                          onPressed: () => wrapSelection('**', '**', placeholder: S.current.toolbar_boldPlaceholder),
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.italic,
                          onPressed: () => wrapSelection('*', '*', placeholder: S.current.toolbar_italicPlaceholder),
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.strikethrough,
                          onPressed: insertStrikethrough,
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.eyeSlash,
                          onPressed: insertSpoiler,
                          tooltip: S.current.toolbar_spoilerTooltip,
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.listUl,
                          onPressed: () => applyLinePrefix('- '),
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.listOl,
                          onPressed: () => applyLinePrefix('1. '),
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.link,
                          onPressed: () => insertLink(context),
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.quoteRight,
                          onPressed: insertQuote,
                        ),
                        // Callout 按钮（带弹出菜单）
                        SwipeDismissiblePopupMenuButton<String>(
                          icon: FaIcon(
                            FontAwesomeIcons.noteSticky,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          tooltip: S.current.toolbar_calloutTooltip,
                          itemBuilder: (context) => [
                            const PopupMenuItem(value: 'note', child: Text('Note')),
                            const PopupMenuItem(value: 'tip', child: Text('Tip')),
                            const PopupMenuItem(value: 'info', child: Text('Info')),
                            const PopupMenuItem(value: 'warning', child: Text('Warning')),
                            const PopupMenuItem(value: 'danger', child: Text('Danger')),
                            const PopupMenuItem(value: 'bug', child: Text('Bug')),
                            const PopupMenuItem(value: 'example', child: Text('Example')),
                            const PopupMenuItem(value: 'quote', child: Text('Quote')),
                            const PopupMenuItem(value: 'abstract', child: Text('Abstract')),
                            const PopupMenuItem(value: 'todo', child: Text('Todo')),
                            const PopupMenuItem(value: 'success', child: Text('Success')),
                            const PopupMenuItem(value: 'question', child: Text('Question')),
                            const PopupMenuItem(value: 'failure', child: Text('Failure')),
                          ],
                          onSelected: insertCallout,
                          padding: EdgeInsets.zero,
                          iconSize: 20,
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.clipboard,
                          onPressed: () => insertTemplate(context),
                          tooltip: S.current.template_tooltip,
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.code,
                          onPressed: insertInlineCode,
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.fileCode,
                          onPressed: insertCodeBlock,
                        ),
                        _ToolbarButton(
                          icon: FontAwesomeIcons.tableColumns,
                          onPressed: wrapImagesInGrid,
                          tooltip: S.current.toolbar_imageGridTooltip,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                height: 20,
                width: 1,
                color: theme.colorScheme.outlineVariant,
                margin: const EdgeInsets.symmetric(horizontal: 4),
              ),
              if (widget.showPanguButton)
                IconButton(
                  icon: Icon(
                    Icons.auto_fix_high_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: widget.onApplyPangu,
                  tooltip: S.current.toolbar_mixOptimize,
                ),
              // 预览按钮（放到最后）
              if (widget.showPreviewButton)
                IconButton(
                  icon: Icon(
                    widget.isPreview ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 20,
                    color: widget.isPreview ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                  ),
                  onPressed: widget.onTogglePreview,
                  tooltip: widget.isPreview ? S.current.common_edit : S.current.common_preview,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final FaIconData icon;
  final VoidCallback? onPressed;
  final bool isLoading;
  final String? tooltip;
  final String? label;

  const _ToolbarButton({
    required this.icon,
    this.onPressed,
    this.isLoading = false,
    this.tooltip,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget child;
    if (isLoading && label != null) {
      // 批量上传进度：显示 "3/22" 文本
      child = Text(
        label!,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.primary,
        ),
      );
    } else if (isLoading) {
      child = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      child = FaIcon(icon, size: 16);
    }

    return IconButton(
      icon: child,
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
