import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../l10n/s.dart';
import '../../models/read_later_item.dart';
import '../../providers/read_later_provider.dart';
import '../../pages/topic_detail_page/topic_detail_page.dart';
import '../../services/local_notification_service.dart'; // navigatorKey
import '../../utils/dialog_utils.dart';
import '../../utils/responsive.dart';
import '../../utils/time_utils.dart';

/// 稍后阅读整屏浮层
///
/// 整屏模糊遮罩 + 横向卡片列表:每个话题一张紧凑卡片,一屏可见
/// 多张,自由横滑浏览、点击继续阅读、单独移除。
/// 入场为错峰动画:标题先落,卡片按顺序依次弹入。
class ReadLaterOverlay extends ConsumerStatefulWidget {
  const ReadLaterOverlay({super.key, required this.animation});

  /// 路由过渡动画,用于内部错峰入场
  final Animation<double> animation;

  /// 显示稍后阅读浮层
  static Future<void> show() {
    final context = navigatorKey.currentContext;
    if (context == null) return Future.value();
    return showAppGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 340),
      pageBuilder: (context, animation, secondaryAnimation) =>
          ReadLaterOverlay(animation: animation),
      // 内容自带错峰动画,过渡层不再叠加整体效果
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          child,
    );
  }

  @override
  ConsumerState<ReadLaterOverlay> createState() => _ReadLaterOverlayState();
}

class _ReadLaterOverlayState extends ConsumerState<ReadLaterOverlay> {
  static const double _cardHeight = 264.0;
  static const double _cardSpacing = 12.0;

  /// 卡片弹入的弹簧曲线(与对话框入场同族,轻微过冲落座)
  static final Curve _springCurve = M3eMotion.defaultSpatial.curveFor(
    const Duration(milliseconds: 340),
  );

  void _openTopic(ReadLaterItem item) {
    Navigator.of(context).pop();
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: item.topicId,
          initialTitle: item.title,
          scrollToPostNumber: item.scrollToPostNumber,
        ),
      ),
    );
  }

  /// 错峰区间动画:整体 340ms 内各区各占一段
  Animation<double> _interval(double begin, double end, [Curve? curve]) {
    return CurvedAnimation(
      parent: widget.animation,
      curve: Interval(begin, end, curve: curve ?? Curves.easeOutCubic),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(readLaterProvider);
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    // 桌面/平板侧栏在遮罩下仍可见,内容区整体避让侧栏宽度
    final railInset = Responsive.showNavigationRail(context) ? 72.0 : 0.0;
    final availWidth = screenWidth - railInset;
    // 一屏约可见 2.2 张,桌面宽窗口下限制单卡上限宽度
    final cardWidth = (availWidth * 0.44).clamp(180.0, 240.0);
    // 宽屏下内容块不铺满全屏:约束最大宽度并在避让区内居中,
    // 标题/关闭钮与卡片条对齐,不再贴边散落
    final contentWidth = math.min(availWidth, cardWidth * 3 + 96);

    // 删除最后一个后自动关闭
    ref.listen<List<ReadLaterItem>>(readLaterProvider, (prev, next) {
      if (next.isEmpty && (prev?.isNotEmpty ?? false)) {
        Navigator.of(context).pop();
      }
    });

    if (items.isEmpty) return const SizedBox.shrink();

    // 整屏内容会盖住路由 barrier,空白区点击关闭在这里自行处理
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(left: railInset),
            child: Center(
              child: SizedBox(
                width: contentWidth,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildHeader(context, theme, items.length),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: _cardHeight,
                      // 桌面端支持鼠标拖拽横滑
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(
                          scrollbars: false,
                          dragDevices: {
                            PointerDeviceKind.touch,
                            PointerDeviceKind.mouse,
                            PointerDeviceKind.trackpad,
                            PointerDeviceKind.stylus,
                          },
                        ),
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          physics: const BouncingScrollPhysics(),
                          itemCount: items.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(width: _cardSpacing),
                          itemBuilder: (context, index) => _buildCardItem(
                            context,
                            items[index],
                            index,
                            cardWidth,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeData theme, int count) {
    final colorScheme = theme.colorScheme;
    return FadeTransition(
      opacity: _interval(0.0, 0.55),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.4),
          end: Offset.zero,
        ).animate(_interval(0.0, 0.7)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.readLater_title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$count / $maxReadLaterItems',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Symbols.close_rounded, size: 22),
                style: IconButton.styleFrom(
                  backgroundColor: colorScheme.surfaceContainerHigh,
                  foregroundColor: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单张卡片:按索引错峰依次弹入
  Widget _buildCardItem(
    BuildContext context,
    ReadLaterItem item,
    int index,
    double cardWidth,
  ) {
    // 每张卡入场起点依次后移,前几张主导观感,后续收敛避免拖尾
    final begin = (0.12 + index * 0.06).clamp(0.0, 0.6);
    return FadeTransition(
      opacity: _interval(begin, (begin + 0.35).clamp(0.0, 1.0)),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.12),
          end: Offset.zero,
        ).animate(_interval(begin, 1.0, _springCurve)),
        child: SizedBox(
          width: cardWidth,
          child: _ReadLaterCard(
            item: item,
            onOpen: () => _openTopic(item),
            onRemove: () =>
                ref.read(readLaterProvider.notifier).remove(item.topicId),
          ),
        ),
      ),
    );
  }
}

/// 单张话题卡片(紧凑版,一屏并列多张)
class _ReadLaterCard extends StatelessWidget {
  const _ReadLaterCard({
    required this.item,
    required this.onOpen,
    required this.onRemove,
  });

  final ReadLaterItem item;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final postNumber = item.scrollToPostNumber;

    return Material(
      color: colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      child: InkWell(
        onTap: onOpen,
        child: Stack(
          children: [
            // 右下角大图标水印,给卡片一点层次
            Positioned(
              right: -14,
              bottom: 26,
              child: Icon(
                Symbols.auto_stories_rounded,
                size: 96,
                color: colorScheme.primary.withValues(alpha: 0.05),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (postNumber != null)
                        Expanded(child: _ProgressPill(postNumber: postNumber))
                      else
                        const Spacer(),
                      IconButton(
                        onPressed: onRemove,
                        tooltip: context.l10n.common_remove,
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Symbols.delete_rounded,
                          size: 18,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: item.excerpt == null
                        ? const SizedBox.shrink()
                        : Text(
                            item.excerpt!,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Row(
                      children: [
                        Icon(
                          Symbols.schedule_rounded,
                          size: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            context.l10n.readLater_addedTime(
                              TimeUtils.formatRelativeTime(item.addedAt),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // 继续阅读圆钮(装饰性,整卡可点)
                        Tooltip(
                          message: context.l10n.readLater_continueReading,
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Symbols.arrow_forward_rounded,
                              size: 16,
                              color: colorScheme.onPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 阅读进度胶囊:「读到 #n」
class _ProgressPill extends StatelessWidget {
  const _ProgressPill({required this.postNumber});

  final int postNumber;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.auto_stories_rounded,
              size: 12,
              color: colorScheme.onPrimaryContainer,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                context.l10n.readLater_readAt(postNumber),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
