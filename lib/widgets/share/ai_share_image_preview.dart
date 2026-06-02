import 'dart:io';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../../providers/preferences_provider.dart';
import '../../services/discourse/discourse_service.dart';
import '../../l10n/s.dart';
import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/screenshot_utils.dart';
import 'ai_share_image_widget.dart';
import 'share_image_preview.dart';

/// AI 分享图片预览页
/// 以 BottomSheet 形式展示，支持复制、保存、分享和回复话题
class AiShareImagePreview extends ConsumerStatefulWidget {
  /// AI 消息列表（按时间正序）
  final List<AiChatMessage> messages;

  /// 话题标题
  final String topicTitle;

  /// 话题 ID
  final int topicId;

  /// 话题 slug
  final String? topicSlug;

  /// 回复话题回调（传入上传后的图片 markdown）
  final void Function(String imageMarkdown)? onReplyToTopic;

  const AiShareImagePreview({
    super.key,
    required this.messages,
    required this.topicTitle,
    required this.topicId,
    this.topicSlug,
    this.onReplyToTopic,
  });

  /// 显示预览 Sheet（单条消息）
  static Future<void> show(
    BuildContext context, {
    required AiChatMessage message,
    required String topicTitle,
    required int topicId,
    String? topicSlug,
    void Function(String imageMarkdown)? onReplyToTopic,
  }) {
    return showMessages(
      context,
      messages: [message],
      topicTitle: topicTitle,
      topicId: topicId,
      topicSlug: topicSlug,
      onReplyToTopic: onReplyToTopic,
    );
  }

  /// 显示预览 Sheet（多条消息）
  static Future<void> showMessages(
    BuildContext context, {
    required List<AiChatMessage> messages,
    required String topicTitle,
    required int topicId,
    String? topicSlug,
    void Function(String imageMarkdown)? onReplyToTopic,
  }) {
    return showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AiShareImagePreview(
        messages: messages,
        topicTitle: topicTitle,
        topicId: topicId,
        topicSlug: topicSlug,
        onReplyToTopic: onReplyToTopic,
      ),
    );
  }

  @override
  ConsumerState<AiShareImagePreview> createState() =>
      _AiShareImagePreviewState();
}

class _AiShareImagePreviewState extends ConsumerState<AiShareImagePreview> {
  final GlobalKey _repaintBoundaryKey = GlobalKey();
  bool _isSaving = false;
  bool _isSharing = false;
  bool _isCopying = false;
  bool _isReplying = false;
  late ShareImageTheme _selectedTheme;

  @override
  void initState() {
    super.initState();
    final savedIndex = ref.read(preferencesProvider).shareImageThemeIndex;
    _selectedTheme = ShareImageTheme.fromIndex(savedIndex);
  }

  void _selectTheme(ShareImageTheme theme) {
    setState(() => _selectedTheme = theme);
    ref.read(preferencesProvider.notifier).setShareImageThemeIndex(theme.index);
  }

  ThemeData _buildThemeData(ThemeData currentTheme) {
    final brightness =
        _selectedTheme.isDark ? Brightness.dark : Brightness.light;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: currentTheme.colorScheme.primary,
        brightness: brightness,
      ),
    );
  }

  Future<Uint8List?> _captureImage() async {
    await Future.delayed(const Duration(milliseconds: 50));
    return ScreenshotUtils.captureWidget(_repaintBoundaryKey);
  }

  Future<void> _copyImage() async {
    if (_isCopying) return;
    setState(() => _isCopying = true);

    try {
      final bytes = await _captureImage();
      if (bytes == null) throw Exception(S.current.share_screenshotFailed);

      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        ToastService.showError(S.current.common_clipboardUnavailable);
        return;
      }
      final item = DataWriterItem();
      item.add(Formats.png(bytes));
      await clipboard.write([item]);

      if (mounted) {
        ToastService.showSuccess(S.current.share_imageCopied);
      }
    } catch (e) {
      debugPrint('[AiShareImagePreview] copyImage error: $e');
      if (mounted) {
        ToastService.showError(S.current.share_copyFailed);
      }
    } finally {
      if (mounted) setState(() => _isCopying = false);
    }
  }

  Future<void> _saveImage() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final bytes = await _captureImage();
      if (bytes == null) throw Exception(S.current.share_screenshotFailed);

      final success = await ScreenshotUtils.saveToGallery(bytes);
      if (mounted) {
        if (success) {
          ToastService.showSuccess(S.current.share_imageSaved);
        } else {
          ToastService.showError(S.current.share_savePermissionDenied);
        }
      }
    } catch (e) {
      debugPrint('[AiShareImagePreview] saveImage error: $e');
      if (mounted) ToastService.showError(S.current.share_saveFailed);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _shareImage() async {
    if (_isSharing) return;
    setState(() => _isSharing = true);

    try {
      final bytes = await _captureImage();
      if (bytes == null) throw Exception(S.current.share_screenshotFailed);

      await ScreenshotUtils.shareImage(bytes);
    } catch (e) {
      debugPrint('[AiShareImagePreview] shareImage error: $e');
      if (mounted) ToastService.showError(S.current.common_shareFailed);
    } finally {
      if (mounted) setState(() => _isSharing = false);
    }
  }

  /// 回复话题：截图 → 上传 → 回调
  Future<void> _replyToTopic() async {
    if (_isReplying || widget.onReplyToTopic == null) return;
    setState(() => _isReplying = true);

    try {
      final bytes = await _captureImage();
      if (bytes == null) throw Exception(S.current.share_screenshotFailed);

      // 保存到临时文件
      final tempDir = await getTemporaryDirectory();
      final fileName = 'ai_reply_${DateTime.now().millisecondsSinceEpoch}.png';
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsBytes(bytes);

      // 上传到 Discourse
      final service = DiscourseService();
      final uploadResult = await service.uploadImage(tempFile.path);
      final imageMarkdown = uploadResult.toMarkdown(alt: S.current.share_aiReplyAlt);

      if (mounted) {
        // 关闭预览页
        Navigator.pop(context);
        // 通过回调传递图片 markdown
        widget.onReplyToTopic!(imageMarkdown);
      }
    } catch (e) {
      debugPrint('[AiShareImagePreview] replyToTopic error: $e');
      if (mounted) {
        ToastService.showError(S.current.share_uploadFailed);
      }
    } finally {
      if (mounted) setState(() => _isReplying = false);
    }
  }

  bool get _anyLoading => _isCopying || _isSaving || _isSharing || _isReplying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final hasReply = widget.onReplyToTopic != null;

    return Container(
      height: screenHeight * 0.85,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // 顶部拖动条
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color:
                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // 标题栏
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
                Expanded(
                  child: Text(
                    widget.messages.length > 1 ? context.l10n.share_exportChatImage : context.l10n.share_exportImage,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // 图片预览区域
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Theme(
                    data: _buildThemeData(theme),
                    child: AiShareImageWidget(
                      messages: widget.messages,
                      topicTitle: widget.topicTitle,
                      topicId: widget.topicId,
                      topicSlug: widget.topicSlug,
                      repaintBoundaryKey: _repaintBoundaryKey,
                      shareTheme: _selectedTheme,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 主题选择区域
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: ShareImageTheme.values.map((t) {
                final isSelected = t == _selectedTheme;
                return GestureDetector(
                  onTap: () => _selectTheme(t),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: t.bgColor,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSelected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline
                                    .withValues(alpha: 0.3),
                            width: isSelected ? 2.5 : 1,
                          ),
                          boxShadow: isSelected
                              ? [
                                  BoxShadow(
                                    color: theme.colorScheme.primary
                                        .withValues(alpha: 0.3),
                                    blurRadius: 8,
                                  ),
                                ]
                              : null,
                        ),
                        child: isSelected
                            ? Icon(
                                Icons.check,
                                size: 18,
                                color:
                                    t.isDark ? Colors.white : Colors.black87,
                              )
                            : null,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t.name,
                        style: TextStyle(
                          fontSize: 10,
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                          fontWeight:
                              isSelected ? FontWeight.w500 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),

          // 底部操作按钮
          Container(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: 12 + bottomPadding,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: theme.colorScheme.outlineVariant
                      .withValues(alpha: 0.3),
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 第一行：复制、保存、分享
                Row(
                  children: [
                    // 复制图片
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _anyLoading ? null : _copyImage,
                        icon: _isCopying
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.copy, size: 18),
                        label: Text(context.l10n.common_copy),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 保存到相册
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _anyLoading ? null : _saveImage,
                        icon: _isSaving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Icon(Icons.save_alt, size: 18),
                        label: Text(context.l10n.common_save),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 分享
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _anyLoading ? null : _shareImage,
                        icon: _isSharing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.share, size: 18),
                        label: Text(context.l10n.common_share),
                        style: FilledButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                // 第二行：回复话题
                if (hasReply) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _anyLoading ? null : _replyToTopic,
                      icon: _isReplying
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.reply, size: 18),
                      label: Text(_isReplying ? context.l10n.share_uploading : context.l10n.share_replyToTopic),
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
