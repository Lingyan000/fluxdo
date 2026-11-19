import 'package:material_ui/material_ui.dart';
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
import '../../utils/quote_builder.dart';
import '../content/discourse_html_content/image_utils.dart';

import 'package:common_ui/common_ui.dart';

/// 图片上下文菜单
///
/// 提供统一的图片操作菜单，可在内容页和图片查看页复用。
/// 按可用空间和输入方式展示图片预览、指针菜单或底部操作列表。
class ImageContextMenu {
  ImageContextMenu._();

  /// 显示图片上下文菜单
  ///
  /// [imageUrl] 图片 URL（会自动转换为原图 URL）
  /// [showViewFullImage] 是否显示「查看大图」选项（图片查看页内不需要）
  /// [post] 帖子对象（用于引用功能，为 null 时隐藏引用选项）
  /// [topicId] 话题 ID（用于引用功能）
  /// [onQuoteImage] 引用回调（打开回复框），为 null 时隐藏「引用」选项
  /// [position] 无提升预览的入口在右键时传入鼠标全局位置。
  /// [onClose] 关闭回调（图片查看页内传入，显示「关闭」选项）
  /// [heroTag] 源缩略图的 Hero tag(「查看大图」打开查看器时飞行转场用)
  /// [lift] 提供源图位置与预览。帖子中长按可浮起图片并展开操作列表；
  /// 在查看器内或源图不可见时，按输入方式展示普通操作菜单。
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

    final actions = _imageActions(
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

    final press = position != null
        ? ImageMenuPress.secondaryTap(position)
        : lift?.press ?? const ImageMenuPress.longPress();
    if (lift != null && lift.sourceContext.mounted) {
      final previewTap =
          lift.onPreviewTap ??
          actions.where((action) => action.id == 'viewFull').firstOrNull?.run;
      final opened = ImageLiftMenu.show(
        context: lift.sourceContext,
        previewBuilder: lift.previewBuilder,
        sourceRadius: lift.sourceRadius,
        onPreviewTap: previewTap,
        press: press,
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
    }
    final pointer = press.position;
    if (press.secondary && pointer != null) {
      final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
      if (overlay is RenderBox && overlay.hasSize) {
        final anchor = overlay.globalToLocal(pointer);
        showSwipeDismissibleMenu<_ImageAction>(
          context: context,
          position: RelativeRect.fromRect(
            anchor & Size.zero,
            Offset.zero & overlay.size,
          ),
          items: [
            for (final action in actions) ...[
              if (action.id == 'close') const PopupMenuDivider(),
              PopupMenuItem(
                value: action,
                child: _MenuItemRow(icon: action.icon, label: action.label),
              ),
            ],
          ],
        ).then((action) {
          if (context.mounted) action?.run();
        });
        return;
      }
    }
    _showSheet(context, actions);
  }

  static List<_ImageAction> _imageActions({
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
        _ImageAction(
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
      _ImageAction(
        'copyImage',
        Symbols.content_copy_rounded,
        S.current.image_copyImage,
        () => _copyImage(originalUrl),
      ),
      _ImageAction(
        'copyLink',
        Symbols.link_rounded,
        S.current.image_copyLink,
        () {
          Clipboard.setData(ClipboardData(text: originalUrl));
          ToastService.showSuccess(S.current.common_linkCopied);
        },
      ),
      _ImageAction(
        'save',
        Symbols.save_alt_rounded,
        ImageSaveUtils.actionLabel,
        () => _saveImage(originalUrl, fileName: fileName),
      ),
      if (ShareUtils.canShareFiles)
        _ImageAction(
          'share',
          Symbols.share_rounded,
          S.current.common_shareImage,
          () => _shareImage(originalUrl, fileName: fileName),
        ),
      if (post != null && topicId != null && onQuoteImage != null)
        _ImageAction(
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
        _ImageAction(
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
        _ImageAction(
          'close',
          Symbols.close_rounded,
          S.current.common_close,
          onClose,
        ),
    ];
  }

  static void _showSheet(BuildContext context, List<_ImageAction> actions) {
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

/// 各种图片菜单共用的操作与展示顺序。
class _ImageAction {
  const _ImageAction(this.id, this.icon, this.label, this.run);

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
