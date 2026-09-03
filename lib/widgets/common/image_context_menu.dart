import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart';
import '../../l10n/s.dart';
import '../../utils/image_save_utils.dart';
import '../../utils/share_utils.dart';
import '../../models/topic.dart';
import '../../pages/image_viewer_page.dart';
import '../../services/discourse_cache_manager.dart';
import '../../services/toast_service.dart';
import 'app_bottom_sheet.dart';
import 'image_lift_menu.dart';
import '../../utils/platform_utils.dart';
import '../../utils/quote_builder.dart';
import '../content/discourse_html_content/image_utils.dart';
import 'package:common_ui/common_ui.dart';

/// 图片上下文菜单
///
/// 提供统一的图片操作菜单，可在内容页和图片查看页复用。
/// 桌面端支持在鼠标位置弹出 Popup Menu，移动端使用底部弹出菜单。
class ImageContextMenu {
  ImageContextMenu._();

  /// 显示图片上下文菜单
  ///
  /// [imageUrl] 图片 URL（会自动转换为原图 URL）
  /// [showViewFullImage] 是否显示「查看大图」选项（图片查看页内不需要）
  /// [post] 帖子对象（用于引用功能，为 null 时隐藏引用选项）
  /// [topicId] 话题 ID（用于引用功能）
  /// [onQuoteImage] 引用回调（打开回复框），为 null 时隐藏「引用」选项
  /// [position] 鼠标全局位置（桌面端右键时传入，用于定位 Popup Menu）
  /// [onClose] 关闭回调（图片查看页内传入，显示「关闭」选项）
  /// [heroTag] 源缩略图的 Hero tag(「查看大图」打开查看器时飞行转场用)
  /// [lift] X 风格浮起菜单源信息(移动端长按):源图 context + 预览
  /// 内容。非 null 且非桌面右键路径时用「长按浮起 + 底部动作面板」呈现
  /// (对齐 X/iOS 系统上下文菜单动效),取不到源矩形时回退底部弹层;
  /// null(如图片查看页,图已全屏,X 本就只用底部菜单)走底部弹层。
  static void show({
    required BuildContext context,
    required String imageUrl,
    bool showViewFullImage = true,
    Post? post,
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
    Offset? position,
    VoidCallback? onClose,
    // 引用/复制引用用的 markdown(理想情况是 `![alt](upload://sha1.ext)`,
    // 对齐 Web 端「复制引用」原样保留图片格式的行为)。为 null 时(如
    // cooked 里找不到匹配 img)降级用 `![image](CDN 完整 URL)`。
    String? quoteMarkdown,
    String? heroTag,
    ImageLiftSpec? lift,
    /// 原始文件名(接口/cooked 提供):分享与「查看大图」的命名依据。
    String? fileName,
  }) {
    final originalUrl = DiscourseImageUtils.getOriginalUrl(imageUrl);

    if (PlatformUtils.isDesktop && position != null) {
      _showDesktopMenu(
        context: context,
        originalUrl: originalUrl,
        imageUrl: imageUrl,
        showViewFullImage: showViewFullImage,
        post: post,
        topicId: topicId,
        onQuoteImage: onQuoteImage,
        position: position,
        onClose: onClose,
        quoteMarkdown: quoteMarkdown,
        heroTag: heroTag,
        fileName: fileName,
      );
    } else {
      _showMobileMenu(
        context: context,
        originalUrl: originalUrl,
        imageUrl: imageUrl,
        showViewFullImage: showViewFullImage,
        post: post,
        topicId: topicId,
        onQuoteImage: onQuoteImage,
        onClose: onClose,
        quoteMarkdown: quoteMarkdown,
        heroTag: heroTag,
        lift: lift,
        fileName: fileName,
      );
    }
  }
  /// 桌面端：在鼠标位置弹出 Popup Menu
  static void _showDesktopMenu({
    required BuildContext context,
    required String originalUrl,
    required String imageUrl,
    required bool showViewFullImage,
    Post? post,
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
    required Offset position,
    VoidCallback? onClose,
    String? quoteMarkdown,
    String? heroTag,
    String? fileName,
  }) {
    final overlayRenderObject = Overlay.of(context).context.findRenderObject();
    if (overlayRenderObject is! RenderBox || !overlayRenderObject.hasSize) {
      // Overlay 未就绪，回退到移动端菜单
      _showMobileMenu(
        context: context,
        originalUrl: originalUrl,
        imageUrl: imageUrl,
        showViewFullImage: showViewFullImage,
        post: post,
        topicId: topicId,
        onQuoteImage: onQuoteImage,
        quoteMarkdown: quoteMarkdown,
        heroTag: heroTag,
        fileName: fileName,
      );
      return;
    }
    final relativeRect = RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlayRenderObject.size,
    );

    final items = <PopupMenuEntry<String>>[
      if (showViewFullImage)
        PopupMenuItem(
          value: 'viewFull',
          child: _MenuItemRow(
            icon: Symbols.zoom_in_rounded,
            label: S.current.image_viewFull,
          ),
        ),
      PopupMenuItem(
        value: 'copyImage',
        child: _MenuItemRow(icon: Symbols.content_copy_rounded, label: S.current.image_copyImage),
      ),
      PopupMenuItem(
        value: 'copyLink',
        child: _MenuItemRow(icon: Symbols.link_rounded, label: S.current.image_copyLink),
      ),
      PopupMenuItem(
        value: 'save',
        child: _MenuItemRow(
          icon: Symbols.save_alt_rounded,
          label: ImageSaveUtils.actionLabel,
        ),
      ),
      // Linux 上 share_plus 不支持分享文件,隐藏该项(保存仍可用)
      if (ShareUtils.canShareFiles)
        PopupMenuItem(
          value: 'share',
          child: _MenuItemRow(
            icon: Symbols.share_rounded,
            label: S.current.common_shareImage,
          ),
        ),
      if (post != null && topicId != null && onQuoteImage != null)
        PopupMenuItem(
          value: 'quote',
          child: _MenuItemRow(
            icon: Symbols.format_quote_rounded,
            label: S.current.common_quote,
          ),
        ),
      if (post != null && topicId != null)
        PopupMenuItem(
          value: 'copyQuote',
          child: _MenuItemRow(
            icon: Symbols.copy_all_rounded,
            label: S.current.common_copyQuote,
          ),
        ),
      if (onClose != null) ...[
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'close',
          child: _MenuItemRow(icon: Symbols.close_rounded, label: S.current.common_close),
        ),
      ],
    ];

    showSwipeDismissibleMenu<String>(
      context: context,
      position: relativeRect,
      items: items,
    ).then((value) {
      if (value == null) return;
      if (!context.mounted) return;
      _handleMenuAction(
        context: context,
        action: value,
        originalUrl: originalUrl,
        imageUrl: imageUrl,
        post: post,
        topicId: topicId,
        onQuoteImage: onQuoteImage,
        onClose: onClose,
        quoteMarkdown: quoteMarkdown,
        heroTag: heroTag,
        fileName: fileName,
      );
    });
  }

  /// 移动端动作(浮起菜单与底部弹层共用同一份顺序与语义)。

  static List<_MobileAction> _mobileActions({
    required BuildContext context,
    required String originalUrl,
    required String imageUrl,
    required bool showViewFullImage,
    Post? post,
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
    String? quoteMarkdown,
    String? heroTag,
    String? fileName,
    VoidCallback? onClose,
  }) {
    return [
      if (showViewFullImage)
        _MobileAction(
          'viewFull',
          Symbols.zoom_in_rounded,
          S.current.image_viewFull,
          () {
            if (!context.mounted) return;
            ImageViewerPage.open(
              context,
              originalUrl,
              thumbnailUrl: imageUrl,
              heroTag: heroTag,
              filenames: [fileName],
            );
          },
        ),
      _MobileAction(
        'copyImage',
        Symbols.content_copy_rounded,
        S.current.image_copyImage,
        () => _copyImage(originalUrl),
      ),
      _MobileAction(
        'copyLink',
        Symbols.link_rounded,
        S.current.image_copyLink,
        () {
          Clipboard.setData(ClipboardData(text: originalUrl));
          ToastService.showSuccess(S.current.common_linkCopied);
        },
      ),
      _MobileAction(
        'save',
        Symbols.save_alt_rounded,
        ImageSaveUtils.actionLabel,
        () => _saveImage(originalUrl, fileName: fileName),
      ),
      if (ShareUtils.canShareFiles)
        _MobileAction(
          'share',
          Symbols.share_rounded,
          S.current.common_shareImage,
          () => _shareImage(originalUrl, fileName: fileName),
        ),
      if (post != null && topicId != null && onQuoteImage != null)
        _MobileAction(
          'quote',
          Symbols.format_quote_rounded,
          S.current.common_quote,
          () => onQuoteImage(
                QuoteBuilder.build(
                  markdown: quoteMarkdown ?? '![image]($originalUrl)',
                  displayName: post.name,
                  username: post.username,
                  postNumber: post.postNumber,
                  topicId: topicId,
                ),
                post,
              ),
        ),
      if (post != null && topicId != null)
        _MobileAction(
          'copyQuote',
          Symbols.copy_all_rounded,
          S.current.common_copyQuote,
          () {
            final quote = QuoteBuilder.build(
              markdown: quoteMarkdown ?? '![image]($originalUrl)',
              displayName: post.name,
              username: post.username,
              postNumber: post.postNumber,
              topicId: topicId,
            );
            Clipboard.setData(ClipboardData(text: quote));
            ToastService.showSuccess(S.current.common_quoteCopied);
          },
        ),
      if (onClose != null)
        _MobileAction(
          'close',
          Symbols.close_rounded,
          S.current.common_close,
          onClose,
        ),
    ];
  }

  /// 移动端:优先 X 风格浮起菜单(长按浮起 + 底部动作面板同时出现),
  /// 无浮起源信息或浮起失败时回退底部弹层。
  static void _showMobileMenu({
    required BuildContext context,
    required String originalUrl,
    required String imageUrl,
    required bool showViewFullImage,
    Post? post,
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
    VoidCallback? onClose,
    String? quoteMarkdown,
    String? heroTag,
    String? fileName,
    ImageLiftSpec? lift,
  }) {
    final actions = _mobileActions(
      context: context,
      originalUrl: originalUrl,
      imageUrl: imageUrl,
      showViewFullImage: showViewFullImage,
      post: post,
      topicId: topicId,
      onQuoteImage: onQuoteImage,
      quoteMarkdown: quoteMarkdown,
      heroTag: heroTag,
      fileName: fileName,
      onClose: onClose,
    );

    if (lift != null && lift.sourceContext.mounted) {
      // 点预览图 = 查看大图(iOS 语义:点预览打开内容)。
      VoidCallback? previewTap = lift.onPreviewTap;
      if (previewTap == null) {
        for (final action in actions) {
          if (action.id == 'viewFull') previewTap = action.run;
        }
      }
      final opened = ImageLiftMenu.show(
        context: lift.sourceContext,
        previewBuilder: lift.previewBuilder,
        sourceRadius: lift.sourceRadius,
        onPreviewTap: previewTap,
        actions: [
          for (final action in actions)
            ImageLiftAction(
              icon: action.icon,
              label: action.label,
              onTap: action.run,
            ),
        ],
      );
      if (opened) return;
      // 浮起失败(源图已卸载等)→ 回退底部弹层。
    }

    AppBottomSheet.show(
      context: context,
      contentPadding: EdgeInsets.zero,
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              ListTile(
                leading: Icon(action.icon),
                title: Text(action.label),
                onTap: () {
                  Navigator.pop(ctx);
                  action.run();
                },
              ),
          ],
        );
      },
    );
  }

  /// 处理菜单选项
  static void _handleMenuAction({
    required BuildContext context,
    required String action,
    required String originalUrl,
    required String imageUrl,
    Post? post,
    int? topicId,
    void Function(String quote, Post post)? onQuoteImage,
    VoidCallback? onClose,
    String? quoteMarkdown,
    String? heroTag,
    String? fileName,
  }) {
    switch (action) {
      case 'viewFull':
        ImageViewerPage.open(
          context,
          originalUrl,
          thumbnailUrl: imageUrl,
          heroTag: heroTag,
          filenames: [fileName],
        );
      case 'copyImage':
        _copyImage(originalUrl);
      case 'copyLink':
        Clipboard.setData(ClipboardData(text: originalUrl));
        ToastService.showSuccess(S.current.common_linkCopied);
      case 'save':
        _saveImage(originalUrl, fileName: fileName);
      case 'share':
        _shareImage(originalUrl, fileName: fileName);
      case 'quote':
        if (post != null && topicId != null && onQuoteImage != null) {
          final quote = QuoteBuilder.build(
            markdown: quoteMarkdown ?? '![image]($originalUrl)',
            displayName: post.name,
            username: post.username,
            postNumber: post.postNumber,
            topicId: topicId,
          );
          onQuoteImage(quote, post);
        }
      case 'copyQuote':
        if (post != null && topicId != null) {
          final quote = QuoteBuilder.build(
            markdown: quoteMarkdown ?? '![image]($originalUrl)',
            displayName: post.name,
            username: post.username,
            postNumber: post.postNumber,
            topicId: topicId,
          );
          Clipboard.setData(ClipboardData(text: quote));
          ToastService.showSuccess(S.current.common_quoteCopied);
        }
      case 'close':
        onClose?.call();
    }
  }

  /// 复制图片到剪贴板
  static Future<void> _copyImage(String imageUrl) async {
    try {
      final bytes = await BlobImageCache.fetch(
        BlobImageCache.contentBucket,
        imageUrl,
      );
      if (bytes.isEmpty) {
        ToastService.showError(S.current.image_fetchFailed);
        return;
      }
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        ToastService.showError(S.current.common_clipboardUnavailable);
        return;
      }
      final item = DataWriterItem();
      item.add(Formats.png(bytes));
      await clipboard.write([item]);
      ToastService.showSuccess(S.current.image_copied);
    } catch (e) {
      debugPrint('[ImageContextMenu] copyImage error: $e');
      ToastService.showError(S.current.image_copyFailed);
    }
  }

  /// 保存图片（移动端进相册、桌面端另存为文件）
  static Future<void> _saveImage(String imageUrl, {String? fileName}) async {
    try {
      final bytes = await BlobImageCache.fetch(
        BlobImageCache.contentBucket,
        imageUrl,
      );
      // 命名与分享同口径：原始文件名 → URL 末段 → 时间戳，逐级回退
      final base =
          ShareUtils.safeFileBaseName(fileName) ??
          'fluxdo_${DateTime.now().millisecondsSinceEpoch}';
      final ext = BlobImageCache.httpUrlExtension(imageUrl);
      await ImageSaveUtils.saveBytes(bytes, fileName: '$base.$ext');
    } catch (e) {
      debugPrint('[ImageContextMenu] saveImage error: $e');
      ToastService.showError(S.current.share_saveFailed);
    }
  }

  /// 分享图片
  static Future<void> _shareImage(String imageUrl, {String? fileName}) async {
    try {
      final file = await BlobImageCache.getFile(
        BlobImageCache.contentBucket,
        imageUrl,
      );
      // 复制为可读文件名的临时文件再分享(缓存文件按 md5 寻址):
      // 原始文件名(接口/cooked) → URL 末段 → 时间戳,逐级回退。
      await ShareUtils.shareImageFile(
        file,
        ext: BlobImageCache.httpUrlExtension(imageUrl),
        fileName: fileName,
        urlHint: imageUrl,
      );
    } catch (e) {
      debugPrint('[ImageContextMenu] shareImage error: $e');
      ToastService.showError(S.current.common_shareFailed);
    }
  }
}

/// 移动端动作模型(浮起菜单与底部弹层共用同一份顺序与语义)。
class _MobileAction {
  const _MobileAction(this.id, this.icon, this.label, this.run);

  final String id;
  final IconData icon;
  final String label;

  /// 纯动作,不含任何菜单关闭逻辑(关闭由菜单外壳负责)。
  final VoidCallback run;
}

/// Popup Menu 菜单项行（图标 + 文字）
class _MenuItemRow extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuItemRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
    );
  }
}
