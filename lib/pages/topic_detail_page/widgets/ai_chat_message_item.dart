import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../../../l10n/s.dart';
import '../../../pages/image_viewer_page.dart';
import '../../../services/toast_service.dart';

import '../../../widgets/markdown_editor/markdown_renderer.dart';

/// AI 聊天消息气泡
class AiChatMessageItem extends StatelessWidget {
  final AiChatMessage message;
  final VoidCallback? onRetry;
  final VoidCallback? onShareAsImage;
  final VoidCallback? onCopyText;

  /// 把消息中的某张生成图片回复到话题（上传到 Discourse 后插入回复框）
  /// null = 不显示「回复」按钮
  final void Function(AiChatAttachment attachment)? onReplyImage;

  /// 多选模式相关
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onSelectionToggle;

  const AiChatMessageItem({
    super.key,
    required this.message,
    this.onRetry,
    this.onShareAsImage,
    this.onCopyText,
    this.onReplyImage,
    this.selectionMode = false,
    this.isSelected = false,
    this.onSelectionToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == ChatRole.user;

    if (selectionMode) {
      return _buildSelectableMessage(context, isUser);
    }

    return isUser ? _buildUserMessage(context) : _buildAssistantMessage(context);
  }

  /// 多选模式下的消息
  Widget _buildSelectableMessage(BuildContext context, bool isUser) {
    return InkWell(
      onTap: onSelectionToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Checkbox(
                value: isSelected,
                onChanged: (_) => onSelectionToggle?.call(),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            Expanded(
              child: Opacity(
                opacity: isSelected ? 1.0 : 0.6,
                child: isUser
                    ? _buildUserMessage(context, inSelectionMode: true)
                    : _buildAssistantMessage(context, inSelectionMode: true),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserMessage(BuildContext context, {bool inSelectionMode = false}) {
    final theme = Theme.of(context);
    final attachments = message.attachments ?? const [];

    return Align(
      alignment: inSelectionMode ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: inSelectionMode
              ? double.infinity
              : MediaQuery.of(context).size.width * 0.78,
        ),
        margin: inSelectionMode
            ? const EdgeInsets.only(top: 4, bottom: 4)
            : const EdgeInsets.only(left: 48, right: 16, top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (attachments.isNotEmpty) ...[
              _AttachmentThumbnails(attachments: attachments),
              if (message.content.isNotEmpty) const SizedBox(height: 6),
            ],
            if (message.content.isNotEmpty)
              SelectableText(
                message.content,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssistantMessage(BuildContext context, {bool inSelectionMode = false}) {
    final theme = Theme.of(context);
    final isStreaming = message.status == MessageStatus.streaming;
    final isError = message.status == MessageStatus.error;
    final isCompleted = message.status == MessageStatus.completed;
    final hasContent = message.content.isNotEmpty;
    final attachments = message.attachments ?? const [];
    final hasAttachments = attachments.isNotEmpty;
    final showActions =
        isCompleted && (hasContent || hasAttachments) && !inSelectionMode;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: inSelectionMode
              ? double.infinity
              : MediaQuery.of(context).size.width * 0.85,
        ),
        margin: inSelectionMode
            ? const EdgeInsets.only(top: 4, bottom: 4)
            : const EdgeInsets.only(left: 16, right: 48, top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isError && message.content.isEmpty) ...[
              _buildErrorWidget(context),
            ] else ...[
              // Anthropic Extended Thinking / OpenAI reasoning 块
              if (message.thinkingContent != null &&
                  message.thinkingContent!.isNotEmpty) ...[
                _ThinkingBlock(
                  text: message.thinkingContent!,
                  isStreaming: isStreaming && message.content.isEmpty,
                ),
                if (message.content.isNotEmpty || isStreaming)
                  const SizedBox(height: 8),
              ],
              if (message.content.isNotEmpty)
                MarkdownBody(data: '${message.content}${isStreaming ? ' ▊' : ''}'),
              // 纯文本流式开始时的小光标占位（图像生成走下面的 placeholder）
              if (message.content.isEmpty &&
                  isStreaming &&
                  (message.thinkingContent == null ||
                      message.thinkingContent!.isEmpty) &&
                  !hasAttachments &&
                  !message.isImageGeneration)
                _buildStreamingIndicator(context),
              // 模型生成的图片（gpt-image / DALL-E 等）
              // 图像生成模式即使 attachments 还为空，也要显示占位
              if (hasAttachments || (isStreaming && message.isImageGeneration)) ...[
                if (hasContent) const SizedBox(height: 8),
                _GeneratedImagesGrid(
                  attachments: attachments,
                  isStreaming: isStreaming,
                  loadingStage: message.loadingStage,
                  startedAt: message.createdAt,
                ),
              ],
              // 优化后的 image prompt（用户可展开验证 optimizer 真的工作了）
              if (message.optimizedPrompt != null &&
                  message.optimizedPrompt!.isNotEmpty) ...[
                const SizedBox(height: 8),
                _OptimizedPromptBlock(
                  prompt: message.optimizedPrompt!,
                  optimizerName: message.optimizerModelName,
                ),
              ],
              if (isError && message.content.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildErrorWidget(context),
              ],
            ],
            // Token 用量行
            if (isCompleted &&
                (message.promptTokens != null ||
                    message.responseTokens != null)) ...[
              const SizedBox(height: 6),
              _buildTokenUsage(context),
            ],
            // 操作按钮行
            if (showActions) ...[
              const SizedBox(height: 8),
              _buildActionBar(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStreamingIndicator(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      '▊',
      style: TextStyle(
        color: theme.colorScheme.primary,
        fontSize: 16,
      ),
    );
  }

  Widget _buildErrorWidget(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                message.errorMessage ?? context.l10n.ai_generateFailed,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (onRetry != null) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 28,
            child: TextButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh, size: 14, color: theme.colorScheme.primary),
              label: Text(
                context.l10n.ai_retryLabel,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Token 用量小字
  Widget _buildTokenUsage(BuildContext context) {
    final theme = Theme.of(context);
    var text = context.l10n.ai_tokenUsage(
      message.promptTokens ?? 0,
      message.responseTokens ?? 0,
    );
    final cached = message.cachedTokens;
    if (cached != null && cached > 0) {
      text += ' · cached $cached';
    }
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        fontSize: 11,
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
      ),
    );
  }

  /// 操作按钮行
  ///
  /// 纯图像消息（无文本，仅 attachments）→ 复制图片 / 保存到相册
  /// 其他（含文本）→ 导出图片 / 复制文本
  Widget _buildActionBar(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final hasContent = message.content.isNotEmpty;
    final attachments = message.attachments ?? const [];
    // 仅取已 finalize 的图片（partial 草图不允许操作）
    final finalAttachments =
        attachments.where((a) => !a.isPartial).toList(growable: false);
    final isImageOnly = !hasContent && finalAttachments.isNotEmpty;

    if (isImageOnly) {
      return Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          if (onReplyImage != null)
            _ActionButton(
              icon: Icons.reply_outlined,
              label: context.l10n.ai_replyToTopicLabel,
              color: color,
              onTap: () => onReplyImage!(finalAttachments.first),
            ),
          _ActionButton(
            icon: Icons.copy_outlined,
            label: context.l10n.ai_copyImageLabel,
            color: color,
            onTap: () => _copyImageAttachment(context, finalAttachments.first),
          ),
          _ActionButton(
            icon: Icons.save_alt_outlined,
            label: context.l10n.ai_saveImageLabel,
            color: color,
            onTap: () => _saveImageAttachment(context, finalAttachments.first),
          ),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionButton(
          icon: Icons.image_outlined,
          label: context.l10n.ai_exportImage,
          color: color,
          onTap: onShareAsImage,
        ),
        const SizedBox(width: 12),
        _ActionButton(
          icon: Icons.copy_outlined,
          label: context.l10n.ai_copyLabel,
          color: color,
          onTap: onCopyText,
        ),
      ],
    );
  }

  Future<Uint8List?> _readAttachmentBytes(AiChatAttachment att) async {
    final localPath = att.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      try {
        return await File(localPath).readAsBytes();
      } catch (_) {}
    }
    final base64Data = att.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      try {
        return base64Decode(base64Data);
      } catch (_) {}
    }
    return null;
  }

  Future<void> _copyImageAttachment(
    BuildContext context,
    AiChatAttachment att,
  ) async {
    final bytes = await _readAttachmentBytes(att);
    if (bytes == null || bytes.isEmpty) {
      if (context.mounted) {
        ToastService.showError(context.l10n.ai_imageCopyFailed);
      }
      return;
    }
    try {
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        if (context.mounted) {
          ToastService.showError(context.l10n.ai_imageCopyFailed);
        }
        return;
      }
      final item = DataWriterItem();
      item.add(Formats.png(bytes));
      await clipboard.write([item]);
      if (context.mounted) {
        ToastService.showSuccess(context.l10n.ai_imageCopied);
      }
    } catch (e) {
      debugPrint('[AiChatMessageItem] copyImage error: $e');
      if (context.mounted) {
        ToastService.showError(context.l10n.ai_imageCopyFailed);
      }
    }
  }

  Future<void> _saveImageAttachment(
    BuildContext context,
    AiChatAttachment att,
  ) async {
    final bytes = await _readAttachmentBytes(att);
    if (bytes == null || bytes.isEmpty) {
      if (context.mounted) {
        ToastService.showError(context.l10n.ai_imageSaveFailed);
      }
      return;
    }
    try {
      final hasAccess = await Gal.hasAccess() || await Gal.requestAccess();
      if (!hasAccess) {
        if (context.mounted) {
          ToastService.showInfo(context.l10n.ai_imageSavePermission);
        }
        return;
      }
      await Gal.putImageBytes(
        bytes,
        name: 'fluxdo_ai_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      if (context.mounted) {
        ToastService.showSuccess(context.l10n.ai_imageSaved);
      }
    } catch (e) {
      debugPrint('[AiChatMessageItem] saveImage error: $e');
      if (context.mounted) {
        ToastService.showError(context.l10n.ai_imageSaveFailed);
      }
    }
  }
}

/// 模型生成的图片网格（大图，可点击查看原图）
class _GeneratedImagesGrid extends StatelessWidget {
  final List<AiChatAttachment> attachments;
  final bool isStreaming;
  final String? loadingStage;
  final DateTime startedAt;

  const _GeneratedImagesGrid({
    required this.attachments,
    required this.isStreaming,
    required this.startedAt,
    this.loadingStage,
  });

  @override
  Widget build(BuildContext context) {
    // 流式中且还没有任何图片 → 整体显示占位
    if (attachments.isEmpty && isStreaming) {
      return _ImageGenerationPlaceholder(
        stage: loadingStage,
        startedAt: startedAt,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final att in attachments) ...[
          _TappableImage(attachment: att),
          if (att != attachments.last) const SizedBox(height: 8),
        ],
        // 已有部分图片但仍在生成（多张图场景）
        if (isStreaming && attachments.isNotEmpty) ...[
          const SizedBox(height: 8),
          _ImageGenerationPlaceholder(compact: true, startedAt: startedAt),
        ],
      ],
    );
  }
}

/// 点击全屏查看的图片（partial 帧带「草图」角标）
class _TappableImage extends StatelessWidget {
  final AiChatAttachment attachment;

  const _TappableImage({required this.attachment});

  Future<Uint8List?> _readBytes() async {
    final localPath = attachment.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      try {
        return await File(localPath).readAsBytes();
      } catch (_) {
        return null;
      }
    }
    final base64Data = attachment.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      try {
        return base64Decode(base64Data);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            InkWell(
              onTap: attachment.isPartial
                  ? null // partial 草图不允许点开（很快会被替换）
                  : () async {
                      final bytes = await _readBytes();
                      if (bytes == null || !context.mounted) return;
                      ImageViewerPage.openBytes(context, bytes);
                    },
              child: ColorFiltered(
                // partial 帧降低饱和度提示「草图」
                colorFilter: attachment.isPartial
                    ? const ColorFilter.matrix([
                        0.6, 0.3, 0.1, 0, 0,
                        0.3, 0.6, 0.1, 0, 0,
                        0.3, 0.3, 0.4, 0, 0,
                        0,   0,   0,   1, 0,
                      ])
                    : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                child: _imageWidget(attachment),
              ),
            ),
            if (attachment.isPartial)
              Positioned(
                top: 8,
                left: 8,
                child: _PartialBadge(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _imageWidget(AiChatAttachment att) {
    final localPath = att.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      return Image.file(
        File(localPath),
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _brokenPlaceholder(),
      );
    }
    final base64Data = att.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      try {
        return Image.memory(
          base64Decode(base64Data),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _brokenPlaceholder(),
        );
      } catch (_) {
        return _brokenPlaceholder();
      }
    }
    return _brokenPlaceholder();
  }

  Widget _brokenPlaceholder() => Container(
        height: 120,
        color: Colors.black12,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined),
      );
}

/// 折叠展示「优化后的 image prompt」
///
/// 当用户配置了 image prompt optimizer 模型，两步生成成功后会把 LLM 翻译过的
/// 精炼 prompt 持久化在 [AiChatMessage.optimizedPrompt]，UI 用这个块展示，
/// 让用户能验证「优化器真的工作了」+「实际发给 image 模型的是什么」+
/// 长按可复制学习 prompt 工程技巧。
class _OptimizedPromptBlock extends StatefulWidget {
  final String prompt;
  final String? optimizerName;

  const _OptimizedPromptBlock({required this.prompt, this.optimizerName});

  @override
  State<_OptimizedPromptBlock> createState() => _OptimizedPromptBlockState();
}

class _OptimizedPromptBlockState extends State<_OptimizedPromptBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_fix_high_outlined, size: 14, color: color),
                  const SizedBox(width: 6),
                  Text(
                    widget.optimizerName != null
                        ? '${context.l10n.ai_optimizedPromptLabel} · ${widget.optimizerName}'
                        : context.l10n.ai_optimizedPromptLabel,
                    style: theme.textTheme.labelSmall?.copyWith(color: color),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: color,
                  ),
                  if (_expanded) ...[
                    const Spacer(),
                    InkWell(
                      onTap: () async {
                        await Clipboard.setData(
                            ClipboardData(text: widget.prompt));
                        if (!context.mounted) return;
                        ToastService.showSuccess(
                            context.l10n.ai_copiedToClipboard);
                      },
                      borderRadius: BorderRadius.circular(4),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(Icons.copy_outlined,
                            size: 14, color: color),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SelectableText(
                widget.prompt,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontSize: 12,
                  height: 1.4,
                  fontFamilyFallback: const ['monospace'],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 渐进帧的「草图」角标
class _PartialBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            height: 8,
            width: 8,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            context.l10n.ai_imageDraft,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「正在生成图片」占位
///
/// gpt-image 系列单图通常 10-30s，给用户一个明确的进度感。
/// 两步生成时根据 [stage] 切换文案：
/// - `'optimizing_prompt'` → "正在分析话题..."
/// - `'generating_image'` 或 null → "正在生成图片..."
class _ImageGenerationPlaceholder extends StatefulWidget {
  /// compact = true 时小尺寸（用于多张图场景下补位），false = 主占位（首次生成）
  final bool compact;

  /// 加载阶段标识，决定显示文案
  final String? stage;

  /// 生成开始时间。用消息创建时间做基准，避免关闭弹框后重开计时归零。
  final DateTime startedAt;

  const _ImageGenerationPlaceholder({
    this.compact = false,
    this.stage,
    required this.startedAt,
  });

  @override
  State<_ImageGenerationPlaceholder> createState() =>
      _ImageGenerationPlaceholderState();
}

class _ImageGenerationPlaceholderState
    extends State<_ImageGenerationPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _ticker;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _syncElapsedSeconds();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(_syncElapsedSeconds);
    });
  }

  void _syncElapsedSeconds() {
    final elapsed = DateTime.now().difference(widget.startedAt).inSeconds;
    _seconds = elapsed < 0 ? 0 : elapsed;
  }

  @override
  void dispose() {
    _controller.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 主占位 280×280（接近常见的 1024×1024 缩略尺寸），compact 80×80
    final size = widget.compact ? 80.0 : 280.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: size,
        width: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // shimmer 渐变扫光
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return ShaderMask(
                  shaderCallback: (rect) {
                    final t = _controller.value;
                    return LinearGradient(
                      begin: Alignment(-1 + 2 * t, 0),
                      end: Alignment(0 + 2 * t, 0),
                      colors: [
                        theme.colorScheme.surfaceContainerHigh,
                        theme.colorScheme.surfaceContainerHighest,
                        theme.colorScheme.surfaceContainerHigh,
                      ],
                    ).createShader(rect);
                  },
                  child: Container(color: Colors.white),
                );
              },
            ),
            if (!widget.compact)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.stage == 'optimizing_prompt'
                        ? Icons.psychology_alt_outlined
                        : Icons.auto_awesome_outlined,
                    size: 32,
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.7),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.stage == 'optimizing_prompt'
                        ? context.l10n.ai_optimizingPrompt
                        : context.l10n.ai_imageGenerating,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_seconds}s',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.6),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              )
            else
              const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }
}

/// 折叠展示的思考块（Anthropic Extended Thinking / OpenAI reasoning）
///
/// 流式期间默认展开，便于观察推理过程；进入完成态后自动折叠。
class _ThinkingBlock extends StatefulWidget {
  final String text;
  final bool isStreaming;

  const _ThinkingBlock({required this.text, required this.isStreaming});

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool? _userExpanded;

  bool get _expanded => _userExpanded ?? widget.isStreaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _userExpanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.psychology_alt_outlined,
                    size: 14,
                    color: color,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.ai_thinkingLabel,
                    style: theme.textTheme.labelSmall?.copyWith(color: color),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: color,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SelectableText(
                widget.text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: color,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 用户消息的附件缩略图（一行 horizontal scrollable）
class _AttachmentThumbnails extends StatelessWidget {
  final List<AiChatAttachment> attachments;

  const _AttachmentThumbnails({required this.attachments});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final att = attachments[index];
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: _attachmentImage(att, size: 80),
          );
        },
      ),
    );
  }

  Widget _attachmentImage(AiChatAttachment att, {required double size}) {
    final remote = att.remoteUrl;
    if (remote != null && remote.isNotEmpty) {
      return Image.network(
        remote,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(size),
      );
    }
    final base64Data = att.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      try {
        return Image.memory(
          base64Decode(base64Data),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(size),
        );
      } catch (_) {
        return _placeholder(size);
      }
    }
    final localPath = att.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      return Image.file(
        File(localPath),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(size),
      );
    }
    return _placeholder(size);
  }

  Widget _placeholder(double size) => Container(
        width: size,
        height: size,
        color: Colors.black12,
        child: const Icon(Icons.image_outlined, size: 24),
      );
}

/// 紧凑的操作按钮
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
