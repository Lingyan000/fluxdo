import 'dart:convert';
import 'dart:io';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:image_picker/image_picker.dart';
import '../../../l10n/s.dart';

/// 输入框 onSend 回调，携带文本和可选附件
typedef AiChatInputSend = void Function(
  String text,
  List<AiChatAttachment> attachments,
);

/// AI 聊天输入框
///
/// 设计参考 Kelivo：输入框上方一行附件预览，下方一行只剩 + 号 / 发送按钮。
/// 拍照、相册、切生图全部收纳到 + 号点击后**内嵌展开**的工具区（不弹 sheet）。
class AiChatInput extends StatefulWidget {
  final bool isGenerating;
  final AiChatInputSend onSend;
  final VoidCallback onStop;
  final VoidCallback? onEscape;

  /// 是否启用图片附件功能（取决于当前模型是否支持多模态）
  ///
  /// false 时 + 号菜单里的「拍照」「相册」会 dim/不可用
  final bool allowAttachments;

  /// 是否当前在图像生成模式（用于 + 号菜单的"切生图"卡片激活态）
  final bool isImageMode;

  /// 用户配了图像模型时为 true
  final bool canEnterImageMode;

  /// 点击 + 号菜单中"切生图"卡片时的回调
  final VoidCallback? onToggleImageMode;

  /// 底部行最左侧的模型按钮（圆形 logo），父级传入
  final Widget? modelButton;

  /// 思考深度按钮（灯泡图标），父级传入
  final Widget? thinkingButton;

  const AiChatInput({
    super.key,
    required this.isGenerating,
    required this.onSend,
    required this.onStop,
    this.onEscape,
    this.allowAttachments = true,
    this.isImageMode = false,
    this.canEnterImageMode = false,
    this.onToggleImageMode,
    this.modelButton,
    this.thinkingButton,
  });

  @override
  State<AiChatInput> createState() => _AiChatInputState();
}

class _AiChatInputState extends State<AiChatInput> {
  final _controller = TextEditingController();
  late final FocusNode _focusNode;
  final _picker = ImagePicker();

  final List<AiChatAttachment> _pendingAttachments = [];

  /// 工具区是否展开（+ 号点击切换）
  bool _toolsExpanded = false;

  bool get _canSend =>
      _controller.text.trim().isNotEmpty || _pendingAttachments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        widget.onEscape != null) {
      widget.onEscape!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty && _pendingAttachments.isEmpty) return;
    final attachments = List<AiChatAttachment>.unmodifiable(_pendingAttachments);
    widget.onSend(text, attachments);
    _controller.clear();
    setState(_pendingAttachments.clear);
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;
      final bytes = await File(picked.path).readAsBytes();
      setState(() {
        _pendingAttachments.add(AiChatAttachment(
          mimeType: _inferMimeType(picked.path),
          base64Data: base64Encode(bytes),
        ));
      });
    } catch (_) {
      // 用户取消或权限被拒，静默处理
    }
  }

  void _toggleTools() {
    setState(() => _toolsExpanded = !_toolsExpanded);
  }

  String _inferMimeType(String path) {
    final ext = path.toLowerCase().split('.').last;
    return switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: 4 + bottomPadding,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 待发送附件预览
          if (_pendingAttachments.isNotEmpty) ...[
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _pendingAttachments.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final att = _pendingAttachments[index];
                  return _PendingAttachmentTile(
                    attachment: att,
                    onRemove: () =>
                        setState(() => _pendingAttachments.removeAt(index)),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
          ],
          // 输入框
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            maxLines: 5,
            minLines: 1,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: context.l10n.ai_inputHint,
              hintStyle: TextStyle(
                color: theme.colorScheme.onSurfaceVariant
                    .withValues(alpha: 0.5),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              isDense: true,
              filled: true,
              fillColor: theme.colorScheme.surface,
              hoverColor: Colors.transparent,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 4),
          // 底部栏：左侧模型 logo 按钮，右侧 [+] [发送/停止]
          Row(
            children: [
              if (widget.modelButton != null) widget.modelButton!,
              if (widget.thinkingButton != null) ...[
                const SizedBox(width: 4),
                widget.thinkingButton!,
              ],
              const Spacer(),
              // + 号：默认无背景，只 hover/按下时才有色调；展开时旋转成 ×。
              // 尺寸跟发送按钮对齐（36×36 + icon 20）
              IconButton(
                onPressed: widget.isGenerating ? null : _toggleTools,
                icon: AnimatedRotation(
                  turns: _toolsExpanded ? 0.125 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Symbols.add_rounded, size: 20),
                ),
                tooltip: _toolsExpanded
                    ? context.l10n.common_close
                    : context.l10n.ai_toolsTooltip,
                style: IconButton.styleFrom(
                  minimumSize: const Size(36, 36),
                  padding: EdgeInsets.zero,
                ),
                color: _toolsExpanded
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              widget.isGenerating
                  ? IconButton.filled(
                      onPressed: widget.onStop,
                      icon: const Icon(Symbols.stop_rounded, size: 20),
                      style: IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.errorContainer,
                        foregroundColor: theme.colorScheme.onErrorContainer,
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                      ),
                      tooltip: context.l10n.ai_stopGenerate,
                    )
                  : IconButton.filled(
                      onPressed: _canSend ? _handleSend : null,
                      icon: const Icon(Symbols.arrow_upward_rounded, size: 20),
                      style: IconButton.styleFrom(
                        backgroundColor: _canSend
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurface
                                .withValues(alpha: 0.1),
                        foregroundColor: _canSend
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.4),
                        minimumSize: const Size(36, 36),
                        padding: EdgeInsets.zero,
                      ),
                      tooltip: context.l10n.ai_sendTooltip,
                    ),
            ],
          ),
          // 工具区：默认折叠，+ 号点击展开 → 拍照 / 相册 / 切生图
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _toolsExpanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                    child: Row(
                      children: [
                        _ToolCard(
                          icon: Symbols.camera_alt_rounded,
                          label: context.l10n.ai_toolsCamera,
                          // 非多模态模型 → 视觉置灰（onTap 也是 null 不响应）
                          dimmed: !widget.allowAttachments,
                          onTap: widget.allowAttachments && !widget.isGenerating
                              ? () {
                                  setState(() => _toolsExpanded = false);
                                  _pickImage(ImageSource.camera);
                                }
                              : null,
                        ),
                        const SizedBox(width: 10),
                        _ToolCard(
                          icon: Symbols.photo_library_rounded,
                          label: context.l10n.ai_toolsPhotos,
                          dimmed: !widget.allowAttachments,
                          onTap: widget.allowAttachments && !widget.isGenerating
                              ? () {
                                  setState(() => _toolsExpanded = false);
                                  _pickImage(ImageSource.gallery);
                                }
                              : null,
                        ),
                        const SizedBox(width: 10),
                        _ToolCard(
                          icon: widget.isImageMode
                              ? Symbols.brush_rounded
                              : Symbols.brush_rounded,
                          label: widget.isImageMode
                              ? context.l10n.ai_modeBackToChat
                              : context.l10n.ai_modeSwitchToImage,
                          active: widget.isImageMode,
                          dimmed: !widget.canEnterImageMode &&
                              !widget.isImageMode,
                          onTap: widget.onToggleImageMode == null
                              ? null
                              : () {
                                  setState(() => _toolsExpanded = false);
                                  widget.onToggleImageMode!();
                                },
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// 内嵌工具区的圆角卡片（之前 BottomSheet 里的设计搬到 inline）
class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.dimmed = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final baseColor = active
        ? theme.colorScheme.primaryContainer
        : (isDark ? Colors.white10 : const Color(0xFFF2F3F5));
    final fg = active
        ? theme.colorScheme.onPrimaryContainer
        : (dimmed
            ? theme.colorScheme.onSurface.withValues(alpha: 0.4)
            : theme.colorScheme.onSurface);
    return Expanded(
      child: SizedBox(
        height: 72,
        child: Material(
          color: baseColor,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 24, color: fg),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: fg,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 待发送附件的小卡片，右上角带删除按钮
class _PendingAttachmentTile extends StatelessWidget {
  final AiChatAttachment attachment;
  final VoidCallback onRemove;

  const _PendingAttachmentTile({
    required this.attachment,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: _buildPreview(64),
        ),
        Positioned(
          top: -4,
          right: -4,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: onRemove,
              customBorder: const CircleBorder(),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Symbols.close_rounded, size: 12, color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview(double size) {
    final base64Data = attachment.base64Data;
    if (base64Data != null && base64Data.isNotEmpty) {
      try {
        return Image.memory(
          base64Decode(base64Data),
          width: size,
          height: size,
          fit: BoxFit.cover,
        );
      } catch (_) {/* fall through */}
    }
    final localPath = attachment.localPath;
    if (localPath != null && localPath.isNotEmpty) {
      return Image.file(
        File(localPath),
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }
    return Container(
      width: size,
      height: size,
      color: Colors.black12,
      child: const Icon(Symbols.image_rounded),
    );
  }
}
