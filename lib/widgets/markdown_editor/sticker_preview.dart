import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../models/sticker.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/cached_image.dart';

/// 表情放大预览的浮层控制器(表情面板、分组预览页共用)。
///
/// 两种形态:
/// - 跟手:长按出现,手指滑到别的表情切换,松手消失;浮层不吃事件。
/// - 固定:点按出现,点任意处消失;浮层自带全屏点击关闭层。
class StickerPreviewController {
  OverlayEntry? _entry;
  final _data = ValueNotifier<_PreviewData?>(null);
  BuildContext? _context;

  bool get isShowing => _entry != null;

  /// 长按开始:显示跟手预览。
  void start(BuildContext context, StickerItem sticker, Rect itemRect) {
    _show(context, sticker, itemRect, pinned: false);
  }

  /// 点按:显示固定预览,点任意处关闭。
  void showPinned(BuildContext context, StickerItem sticker, Rect itemRect) {
    _show(context, sticker, itemRect, pinned: true);
  }

  void _show(
    BuildContext context,
    StickerItem sticker,
    Rect itemRect, {
    required bool pinned,
  }) {
    end();
    HapticFeedback.mediumImpact();
    _context = context;
    _data.value = _PreviewData(
      sticker,
      itemRect,
      MediaQuery.sizeOf(context),
      pinned: pinned,
    );
    _entry = OverlayEntry(
      builder: (_) => _StickerPreviewOverlay(notifier: _data, onDismiss: end),
    );
    Overlay.of(context).insert(_entry!);
  }

  /// 长按滑动:手指移到另一张表情上时切换预览。
  void move(Offset globalPosition) {
    final current = _data.value;
    final context = _context;
    if (current == null || context == null || !context.mounted) return;
    final found = _findStickerAt(context, globalPosition);
    if (found != null && found.$1.id != current.sticker.id) {
      HapticFeedback.selectionClick();
      _data.value = _PreviewData(
        found.$1,
        found.$2,
        current.screenSize,
        pinned: current.pinned,
      );
    }
  }

  /// 长按结束:只收起跟手预览,固定预览等点击关闭。
  void release() {
    if (_data.value?.pinned ?? false) return;
    end();
  }

  void end() {
    _entry?.remove();
    _entry = null;
    _data.value = null;
  }

  void dispose() {
    end();
    _data.dispose();
  }

  static (StickerItem, Rect)? _findStickerAt(
    BuildContext context,
    Offset globalPosition,
  ) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      globalPosition,
      View.of(context).viewId,
    );
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is StickerItem) {
        final rect = target.localToGlobal(Offset.zero) & target.size;
        return (target.metaData as StickerItem, rect);
      }
    }
    return null;
  }
}

/// 表情网格里的单个格子:点按、长按滑动预览,缩略图走贴纸缩略图管线。
class StickerGridCell extends StatelessWidget {
  const StickerGridCell({
    super.key,
    required this.sticker,
    required this.preview,
    this.onTap,
    this.priority = DownloadPriority.normal,
  });

  final StickerItem sticker;
  final StickerPreviewController preview;

  /// 缩略图下载优先级:用户正盯着看的网格(分组预览页)传 high,
  /// 越过市场预览条等后台请求。
  final DownloadPriority priority;

  /// 为 null 时点按显示固定预览。
  final VoidCallback? onTap;

  Rect _rectOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary 隔离单 cell 的重绘 — 一张 sticker 解码完 setImage 时
    // 只这一格重绘,不连累整个 grid。30 张同时陆续 setImage 时这是关键优化。
    return RepaintBoundary(
      child: MetaData(
        metaData: sticker,
        behavior: HitTestBehavior.opaque,
        child: GestureDetector(
          onTap:
              onTap ??
              () => preview.showPinned(context, sticker, _rectOf(context)),
          onLongPressStart: (_) =>
              preview.start(context, sticker, _rectOf(context)),
          onLongPressMoveUpdate: (details) =>
              preview.move(details.globalPosition),
          onLongPressEnd: (_) => preview.release(),
          onLongPressCancel: preview.release,
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: StickerThumbnail(sticker: sticker, priority: priority),
          ),
        ),
      ),
    );
  }
}

/// 表情缩略图(160px 首帧,与面板共用缩略图缓存)。
class StickerThumbnail extends StatelessWidget {
  const StickerThumbnail({
    super.key,
    required this.sticker,
    this.priority = DownloadPriority.normal,
  });

  final StickerItem sticker;
  final DownloadPriority priority;

  @override
  Widget build(BuildContext context) {
    return CachedImage(
      url: sticker.url,
      fit: BoxFit.contain,
      memCacheWidth: 160,
      memCacheHeight: 160,
      thumbnailMode: true,
      thumbnailDisplayUrl: sticker.displayUrl,
      bucket: BlobImageCache.stickerOriginalBucket,
      priority: priority,
      // 解码期占位:灰色圆角骨架,不用 spinner
      // (每格一个 spinner 会让 grid 视觉吵)。配合 gaplessPlayback 平滑切到图。
      placeholder: (ctx) => DecoratedBox(
        decoration: ShapeDecoration(
          color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
          shape: RoundedSuperellipseBorder(
            borderRadius: ctx.shapes.borderRadius(6),
          ),
        ),
      ),
      errorBuilder: (_, _, _) => Icon(
        Symbols.broken_image_rounded,
        size: 24,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

/// 预览数据
class _PreviewData {
  final StickerItem sticker;
  final Rect itemRect;
  final Size screenSize;
  final bool pinned;
  const _PreviewData(
    this.sticker,
    this.itemRect,
    this.screenSize, {
    required this.pinned,
  });
}

/// 预览 Overlay（监听 ValueNotifier 实时更新）
class _StickerPreviewOverlay extends StatelessWidget {
  final ValueNotifier<_PreviewData?> notifier;
  final VoidCallback onDismiss;
  const _StickerPreviewOverlay({
    required this.notifier,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_PreviewData?>(
      valueListenable: notifier,
      builder: (context, data, _) {
        if (data == null) return const SizedBox.shrink();
        final popup = _StickerPreviewPopup(
          sticker: data.sticker,
          itemRect: data.itemRect,
          screenSize: data.screenSize,
        );
        if (!data.pinned) return Stack(children: [popup]);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
              ),
            ),
            popup,
          ],
        );
      },
    );
  }
}

/// 长按弹出的表情包放大预览
class _StickerPreviewPopup extends StatelessWidget {
  final StickerItem sticker;
  final Rect itemRect;
  final Size screenSize;

  static const double _previewSize = 180;
  static const double _nameHeight = 28;
  static const double _cardPadding = 8;
  static const double _totalHeight =
      _previewSize + _nameHeight + _cardPadding * 2;
  static const double _totalWidth = _previewSize + _cardPadding * 2;
  static const double _screenMargin = 12;

  const _StickerPreviewPopup({
    required this.sticker,
    required this.itemRect,
    required this.screenSize,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 垂直定位：优先上方，空间不足时改下方
    final spaceAbove = itemRect.top - _screenMargin;
    final showAbove = spaceAbove >= _totalHeight;
    final dy = showAbove
        ? itemRect.top - _totalHeight - 8
        : itemRect.bottom + 8;

    // 水平居中对齐缩略图，clamp 防溢出
    final dx = (itemRect.center.dx - _totalWidth / 2).clamp(
      _screenMargin,
      screenSize.width - _totalWidth - _screenMargin,
    );

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      left: dx,
      top: dy,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          builder: (context, value, child) => Opacity(
            opacity: value.clamp(0.0, 1.0),
            child: Transform.scale(
              scale: 0.6 + 0.4 * value,
              alignment: showAbove
                  ? Alignment.bottomCenter
                  : Alignment.topCenter,
              child: child,
            ),
          ),
          child: Material(
            elevation: 8,
            shape: RoundedSuperellipseBorder(
              borderRadius: context.shapes.borderRadius(16),
            ),
            color: theme.colorScheme.surfaceContainerHigh,
            child: Padding(
              padding: const EdgeInsets.all(_cardPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: _previewSize,
                    height: _previewSize,
                    child: CachedImage(
                      url: sticker.url,
                      fit: BoxFit.contain,
                      // 不传 memCacheWidth → AVIF 完整解码（含动画）
                      bucket: BlobImageCache.stickerOriginalBucket,
                      errorBuilder: (_, _, _) => Icon(
                        Symbols.broken_image_rounded,
                        size: 48,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _previewSize,
                    height: _nameHeight,
                    child: Center(
                      child: Text(
                        sticker.name,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
