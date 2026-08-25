// 本文件是 chat_channel_page.dart 的 part(私有类互引,拆物理文件
// 不拆库);新增聊天页组件按职责归档到对应 part。

part of 'chat_channel_page.dart';

/// 纯 emoji 消息判定:cooked 仅由 emoji 图(+ p 标签/空白)组成且 ≤6 个,
/// 返回解析后的 emoji 图 URL 列表用于 jumbo 大图渲染;否则 null。
List<String>? jumboEmojiUrls(String cooked) {
  final imgRe = RegExp(r'<img\b[^>]*>', caseSensitive: false);
  final imgs = imgRe.allMatches(cooked).map((m) => m.group(0)!).toList();
  if (imgs.isEmpty || imgs.length > 6) return null;
  // 去掉所有 img + p 标签 + 空白/&nbsp; 后若还有内容,则非纯 emoji
  var rest = cooked.replaceAll(imgRe, '');
  rest = rest.replaceAll(RegExp(r'</?p>', caseSensitive: false), '');
  rest = rest.replaceAll(RegExp(r'(\s|&nbsp;)+'), '');
  if (rest.isNotEmpty) return null;
  final srcRe = RegExp('src="([^"]+)"', caseSensitive: false);
  final urls = <String>[];
  for (final img in imgs) {
    if (!img.toLowerCase().contains('emoji')) return null; // 含非 emoji 图
    final src = srcRe.firstMatch(img)?.group(1);
    if (src == null) return null;
    urls.add(UrlHelper.resolveUrlWithCdn(src));
  }
  return urls;
}

/// 多选工具栏(对齐官方 selection-manager:引用/复制/删除/由 AppBar 取消)
class _SelectionToolbar extends StatelessWidget {
  final int count;
  final bool canDelete;
  final VoidCallback onQuote;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  const _SelectionToolbar({
    required this.count,
    required this.canDelete,
    required this.onQuote,
    required this.onCopy,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final enabled = count > 0;
    return Container(
      padding: EdgeInsets.only(top: 6, bottom: 6 + bottomPadding),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _SelectionAction(
            icon: Symbols.format_quote_rounded,
            label: context.l10n.chat_selectionQuote,
            enabled: enabled,
            onTap: onQuote,
          ),
          _SelectionAction(
            icon: Symbols.content_copy_rounded,
            label: context.l10n.chat_menuCopy,
            enabled: enabled,
            onTap: onCopy,
          ),
          _SelectionAction(
            icon: Symbols.delete_rounded,
            label: context.l10n.chat_menuDelete,
            enabled: enabled && canDelete,
            destructive: true,
            onTap: onDelete,
          ),
        ],
      ),
    );
  }
}

class _SelectionAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool destructive;
  final VoidCallback onTap;

  const _SelectionAction({
    required this.icon,
    required this.label,
    required this.enabled,
    this.destructive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = !enabled
        ? theme.colorScheme.onSurface.withValues(alpha: 0.3)
        : destructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏"正在输入"副标题:状态文字 + 三点循环动画
class _TypingSubtitle extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _TypingSubtitle({required this.text, required this.style});

  @override
  State<_TypingSubtitle> createState() => _TypingSubtitleState();
}

class _TypingSubtitleState extends State<_TypingSubtitle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 文案自带尾部省略号(l10n),动画点另画,先剥掉静态省略号
    final base = widget.text.replaceFirst(RegExp(r'[….]+\s*$'), '');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            base,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          ),
        ),
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final phase = (_controller.value * 3).floor();
            return SizedBox(
              // 定宽防止点数变化时文字横跳
              width: (widget.style.fontSize ?? 11) * 1.4,
              child: Text('.' * (phase + 1), style: widget.style),
            );
          },
        ),
      ],
    );
  }
}

/// 置顶横幅:列表顶部悬浮一条,竖线记号+置顶人/摘要,
/// 点击跳到消息(多条时轮换);pin/unpin 广播实时增删
class _PinnedBanner extends StatelessWidget {
  final List<ChatMessage> pins;
  final int cursor;
  final VoidCallback onTap;

  const _PinnedBanner({
    required this.pins,
    required this.cursor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pin = pins[cursor];
    return Material(
      color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.97),
      elevation: 1,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: [
              // 竖线记号:多条时分段指示当前位置
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < pins.length && i < 4; i++)
                    Container(
                      width: 2.5,
                      height: pins.length > 1 ? 10.0 : 26.0,
                      margin: EdgeInsets.only(top: i == 0 ? 0 : 2),
                      decoration: BoxDecoration(
                        color: i == cursor
                            ? theme.colorScheme.primary
                            : theme.colorScheme.primary.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pins.length > 1
                          ? context.l10n.chat_pinnedCount(pins.length)
                          : context.l10n.chat_pinnedBanner,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    EmojiText(
                      chatPreviewText(
                        context,
                        pin.excerpt?.isNotEmpty == true
                            ? pin.excerpt!
                            : pin.message,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Symbols.keep_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// @提及候选条:悬浮卡(Overlay 挂载,不占输入区布局)
class _MentionCandidateBar extends StatelessWidget {
  final List<MentionUser> candidates;
  final void Function(MentionUser user) onSelect;

  const _MentionCandidateBar({
    required this.candidates,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - 24,
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final user in candidates)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: InkWell(
                    onTap: () => onSelect(user),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SmartAvatar(
                            imageUrl: _ChatComposerState._mentionAvatarUrl(
                              user,
                            ),
                            radius: 11,
                            fallbackText: user.username,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            user.username,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 消息附件区:图片=圆角缩略图(点开 viewer,同消息多图组画廊);
/// 其他文件=图标+文件名卡
class _MessageUploads extends StatelessWidget {
  final List<ChatUpload> uploads;
  final bool interactive;
  final String heroNamespace;

  const _MessageUploads({
    required this.uploads,
    required this.interactive,
    required this.heroNamespace,
  });

  static const _imageExts = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif'};

  bool _isImage(ChatUpload u) =>
      _imageExts.contains((u.extension ?? '').toLowerCase());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final images = uploads.where(_isImage).toList();
    final files = uploads.where((u) => !_isImage(u)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (images.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < images.length; i++)
                _buildImage(context, images, i),
            ],
          ),
        for (final file in files)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.description_rounded,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      file.originalFilename ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// 气泡缩略图的展示方式:cover 裁切 + 圆角 10(与下方 ClipRRect 同值)。
  /// 一处给出,同时约束源端与 openViewer 两侧参数(见 ViewerSourceStyle)。
  static const _bubbleStyle = ViewerSourceStyle.cover(radius: 10);

  Widget _buildImage(BuildContext context, List<ChatUpload> images, int i) {
    final upload = images[i];
    final url = upload.resolvedUrl;
    if (url == null) return const SizedBox.shrink();
    // 多图缩小档;单图按上限约束,保持宽高比
    final many = images.length > 1;
    final maxW = many ? 132.0 : 240.0;
    final ratio = (upload.width ?? 0) > 0 && (upload.height ?? 0) > 0
        ? upload.width! / upload.height!
        : 1.0;
    final w = maxW;
    final h = (w / ratio).clamp(72.0, 320.0);
    final heroTag = '${heroNamespace}_$i';

    final image = ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image(
        image: discourseImageProvider(url),
        width: w,
        height: h,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: w,
          height: 72,
          alignment: Alignment.center,
          color: Theme.of(context).colorScheme.surface,
          child: const Icon(Symbols.broken_image_rounded),
        ),
      ),
    );
    if (!interactive) return image;
    // HeroImage 统一件:源端隐藏/占位/飞行起点/裁切插值都由它保证;
    // _bubbleStyle 同时约束 openViewer 侧参数(见 ViewerSourceStyle)
    return HeroImage(
      heroTag: heroTag,
      style: _bubbleStyle,
      flightImage: discourseImageProvider(url),
      onTap: () => ImageViewerPage.open(
        context,
        url,
        heroTag: heroTag,
        galleryImages: [for (final u in images) u.resolvedUrl ?? ''],
        heroTags: [
          for (var j = 0; j < images.length; j++) '${heroNamespace}_$j',
        ],
        initialIndex: i,
        filenames: [for (final u in images) u.originalFilename],
        // 气泡缩略图是 cover 裁切 + 圆角展示,必须告知查看器 —— 否则飞行体
        // 不走裁切插值,尾帧停在「裁切后的画面」而不是完整图(真机实测:
        // 聊天图片预测返回到最后是裁切的)。网格瓦片同为 cover,一直传着
        // 这两个参数;聊天此前漏了。
        thumbnailUrl: url,
        thumbnailUrls: [for (final u in images) u.resolvedUrl ?? ''],
        // 与源端同源:_bubbleStyle 一处给出,两侧不可能不一致
        heroSourceFit: _bubbleStyle.openViewerArgs.fit,
        heroSourceRadius: _bubbleStyle.openViewerArgs.radius,
        heroSourceCircular: _bubbleStyle.openViewerArgs.circular,
      ),
      child: image,
    );
  }
}

