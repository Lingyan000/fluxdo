import 'dart:async';

import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../models/sticker.dart';
import '../../services/discourse_cache_manager.dart';
import '../common/cached_image.dart';

/// 预览浮层里的操作项。
class StickerPreviewAction {
  const StickerPreviewAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final bool destructive;
}

/// 网格格子携带的预览目标:表情本身 + 它所在的分区(由宿主定义,
/// 例如「最近使用」),用于决定菜单里出现哪些操作。
class StickerPreviewTarget {
  const StickerPreviewTarget(this.sticker, {this.origin});

  final StickerItem sticker;
  final Object? origin;
}

typedef StickerPreviewActionsBuilder = List<StickerPreviewAction> Function(
  StickerPreviewTarget target,
);

/// 表情放大预览的浮层控制器(表情面板、分组预览页共用)。
///
/// 形态:
/// - 跟手:长按出现,手指滑到别的表情切换,松手消失;浮层不吃事件。
///   宿主提供了 [actionsBuilder] 时,在同一张表情上停留 [menuDelay] 会
///   弹出操作菜单并转为固定,松手后菜单留着等点选。
/// - 固定:点按出现,点任意处消失;浮层自带全屏点击关闭层。
/// - 菜单:鼠标右键直接弹出预览与操作菜单。
/// - 悬停:鼠标在格子上停留 [hoverDelay] 显示预览,移出即消失。
class StickerPreviewController {
  StickerPreviewController({this.actionsBuilder});

  final StickerPreviewActionsBuilder? actionsBuilder;

  static const Duration menuDelay = Duration(milliseconds: 1300);
  static const Duration hoverDelay = Duration(milliseconds: 400);

  OverlayEntry? _entry;
  final _data = ValueNotifier<_PreviewData?>(null);
  BuildContext? _context;
  Timer? _menuTimer;
  Timer? _hoverTimer;

  bool get isShowing => _entry != null;

  /// 长按开始:显示跟手预览,停留后弹菜单。
  void start(BuildContext context, StickerPreviewTarget target, Rect rect) {
    _show(context, target, rect, pinned: false);
    HapticFeedback.mediumImpact();
    _scheduleMenu();
  }

  /// 点按:显示固定预览,点任意处关闭。
  void showPinned(
    BuildContext context,
    StickerPreviewTarget target,
    Rect rect,
  ) {
    _show(context, target, rect, pinned: true);
  }

  /// 右键:直接显示预览与操作菜单。
  void showMenu(BuildContext context, StickerPreviewTarget target, Rect rect) {
    _show(
      context,
      target,
      rect,
      pinned: true,
      actions: actionsBuilder?.call(target),
    );
  }

  /// 鼠标进入格子:停留一会儿再显示预览,避免划过时闪烁。
  void hoverStart(
    BuildContext context,
    StickerPreviewTarget target,
    Rect rect,
  ) {
    _hoverTimer?.cancel();
    if (_data.value?.pinned ?? false) return;
    _hoverTimer = Timer(hoverDelay, () {
      if (!context.mounted || (_data.value?.pinned ?? false)) return;
      _show(context, target, rect, pinned: false, hover: true);
    });
  }

  /// 鼠标离开格子:收起悬停预览(固定/菜单形态不受影响)。
  void hoverEnd() {
    _hoverTimer?.cancel();
    final data = _data.value;
    if (data != null && data.hover) end();
  }

  void _show(
    BuildContext context,
    StickerPreviewTarget target,
    Rect rect, {
    required bool pinned,
    bool hover = false,
    List<StickerPreviewAction>? actions,
  }) {
    end();
    _context = context;
    _data.value = _PreviewData(
      target,
      rect,
      MediaQuery.sizeOf(context),
      pinned: pinned,
      hover: hover,
      actions: actions,
    );
    _entry = OverlayEntry(
      builder: (_) => _StickerPreviewOverlay(
        notifier: _data,
        onDismiss: end,
        onAction: (action) {
          end();
          action.onSelected();
        },
      ),
    );
    Overlay.of(context).insert(_entry!);
  }

  void _scheduleMenu() {
    _menuTimer?.cancel();
    if (actionsBuilder == null) return;
    _menuTimer = Timer(menuDelay, () {
      final current = _data.value;
      if (current == null || current.pinned) return;
      final actions = actionsBuilder!(current.target);
      if (actions.isEmpty) return;
      HapticFeedback.heavyImpact();
      _data.value = current.copyWith(pinned: true, actions: actions);
    });
  }

  /// 长按滑动:手指移到另一张表情上时切换预览并重新计时。菜单出现后
  /// 不再跟手,避免选菜单时误切。
  void move(Offset globalPosition) {
    final current = _data.value;
    final context = _context;
    if (current == null || current.pinned) return;
    if (context == null || !context.mounted) return;
    final found = _findTargetAt(context, globalPosition);
    if (found != null && found.$1.sticker.id != current.target.sticker.id) {
      HapticFeedback.selectionClick();
      _data.value = _PreviewData(
        found.$1,
        found.$2,
        current.screenSize,
        pinned: false,
      );
      _scheduleMenu();
    }
  }

  /// 长按结束:只收起跟手预览,固定预览与菜单等点击关闭。
  void release() {
    _menuTimer?.cancel();
    if (_data.value?.pinned ?? false) return;
    end();
  }

  void end() {
    _menuTimer?.cancel();
    _hoverTimer?.cancel();
    _entry?.remove();
    _entry = null;
    _data.value = null;
  }

  void dispose() {
    end();
    _data.dispose();
  }

  static (StickerPreviewTarget, Rect)? _findTargetAt(
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
      if (target is RenderMetaData && target.metaData is StickerPreviewTarget) {
        final rect = target.localToGlobal(Offset.zero) & target.size;
        return (target.metaData as StickerPreviewTarget, rect);
      }
    }
    return null;
  }
}

/// 表情网格里的单个格子:点按、长按滑动预览、右键菜单、悬停预览,
/// 缩略图走贴纸缩略图管线。
class StickerGridCell extends StatelessWidget {
  const StickerGridCell({
    super.key,
    required this.sticker,
    required this.preview,
    this.origin,
    this.onTap,
    this.priority = DownloadPriority.normal,
  });

  final StickerItem sticker;
  final StickerPreviewController preview;

  /// 所在分区,原样交给 [StickerPreviewController.actionsBuilder]。
  final Object? origin;

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
    final target = StickerPreviewTarget(sticker, origin: origin);
    // RepaintBoundary 隔离单 cell 的重绘 — 一张 sticker 解码完 setImage 时
    // 只这一格重绘,不连累整个 grid。30 张同时陆续 setImage 时这是关键优化。
    return RepaintBoundary(
      child: MetaData(
        metaData: target,
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(
          onEnter: (_) => preview.hoverStart(context, target, _rectOf(context)),
          onExit: (_) => preview.hoverEnd(),
          child: GestureDetector(
            onTap: () {
              preview.hoverEnd();
              if (onTap != null) {
                onTap!();
              } else {
                preview.showPinned(context, target, _rectOf(context));
              }
            },
            onSecondaryTapUp: preview.actionsBuilder == null
                ? null
                : (_) => preview.showMenu(context, target, _rectOf(context)),
            onLongPressStart: (_) =>
                preview.start(context, target, _rectOf(context)),
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
  final StickerPreviewTarget target;
  final Rect itemRect;
  final Size screenSize;
  final bool pinned;
  final bool hover;

  /// 非空时在预览下方显示操作菜单。
  final List<StickerPreviewAction>? actions;

  const _PreviewData(
    this.target,
    this.itemRect,
    this.screenSize, {
    required this.pinned,
    this.hover = false,
    this.actions,
  });

  _PreviewData copyWith({bool? pinned, List<StickerPreviewAction>? actions}) =>
      _PreviewData(
        target,
        itemRect,
        screenSize,
        pinned: pinned ?? this.pinned,
        hover: hover,
        actions: actions ?? this.actions,
      );
}

/// 预览 Overlay（监听 ValueNotifier 实时更新）
class _StickerPreviewOverlay extends StatelessWidget {
  final ValueNotifier<_PreviewData?> notifier;
  final VoidCallback onDismiss;
  final ValueChanged<StickerPreviewAction> onAction;
  const _StickerPreviewOverlay({
    required this.notifier,
    required this.onDismiss,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_PreviewData?>(
      valueListenable: notifier,
      builder: (context, data, _) {
        if (data == null) return const SizedBox.shrink();
        final popup = _StickerPreviewPopup(data: data, onAction: onAction);
        if (!data.pinned) return Stack(children: [popup]);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                onSecondaryTap: onDismiss,
              ),
            ),
            popup,
          ],
        );
      },
    );
  }
}

/// 表情包放大预览(可带操作菜单)
class _StickerPreviewPopup extends StatelessWidget {
  final _PreviewData data;
  final ValueChanged<StickerPreviewAction> onAction;

  static const double _previewSize = 180;
  static const double _nameHeight = 28;
  static const double _cardPadding = 8;
  static const double _previewHeight =
      _previewSize + _nameHeight + _cardPadding * 2;
  static const double _totalWidth = _previewSize + _cardPadding * 2;
  static const double _screenMargin = 12;
  static const double _menuGap = 8;
  static const double _menuItemHeight = 44;
  static const double _menuPadding = 6;

  const _StickerPreviewPopup({required this.data, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sticker = data.target.sticker;
    final itemRect = data.itemRect;
    final screenSize = data.screenSize;
    final actions = data.actions ?? const <StickerPreviewAction>[];
    final menuHeight = actions.isEmpty
        ? 0.0
        : _menuGap + actions.length * _menuItemHeight + _menuPadding * 2;
    final totalHeight = _previewHeight + menuHeight;

    // 垂直定位：优先上方，空间不足时改下方，都放不下就贴住屏幕边
    final spaceAbove = itemRect.top - _screenMargin;
    final showAbove = spaceAbove >= totalHeight;
    final rawDy = showAbove
        ? itemRect.top - totalHeight - 8
        : itemRect.bottom + 8;
    final dy = rawDy.clamp(
      _screenMargin,
      (screenSize.height - totalHeight - _screenMargin).clamp(
        _screenMargin,
        double.infinity,
      ),
    );

    // 水平居中对齐缩略图，clamp 防溢出
    final dx = (itemRect.center.dx - _totalWidth / 2).clamp(
      _screenMargin,
      screenSize.width - _totalWidth - _screenMargin,
    );

    final card = Material(
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
    );

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      left: dx,
      top: dy,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutBack,
        builder: (context, value, child) => Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.6 + 0.4 * value,
            alignment: showAbove ? Alignment.bottomCenter : Alignment.topCenter,
            child: child,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IgnorePointer(child: card),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: _menuGap),
              _ActionMenu(
                width: _totalWidth,
                itemHeight: _menuItemHeight,
                padding: _menuPadding,
                actions: actions,
                onAction: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ActionMenu extends StatelessWidget {
  const _ActionMenu({
    required this.width,
    required this.itemHeight,
    required this.padding,
    required this.actions,
    required this.onAction,
  });

  final double width;
  final double itemHeight;
  final double padding;
  final List<StickerPreviewAction> actions;
  final ValueChanged<StickerPreviewAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * -8),
          child: child,
        ),
      ),
      child: Material(
        elevation: 8,
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(16),
        ),
        color: theme.colorScheme.surfaceContainerHigh,
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: padding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final action in actions)
                  InkWell(
                    onTap: () => onAction(action),
                    child: SizedBox(
                      height: itemHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            Icon(
                              action.icon,
                              size: 20,
                              color: action.destructive
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                action.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: action.destructive
                                      ? theme.colorScheme.error
                                      : null,
                                ),
                              ),
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
      ),
    );
  }
}
