import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../../models/topic.dart';
import '../../../providers/preferences_provider.dart';
import '../../../widgets/topic/topic_progress.dart';
import 'topic_bottom_bar.dart';
import 'topic_progress_gestures.dart';

/// 话题详情页浮层
/// 包含进度栏、底部操作栏和悬浮回复按钮
///
/// 滚动中高频变化的状态一律走 ValueListenable 细粒度下沉,不要提升为
/// 本组件的构造参数(那会整棵重建底栏 + FAB,实测单次 6~7ms):
/// - 楼层号([streamIndexListenable])→ 只重建 [TopicProgress]
/// - 底栏显隐([showBottomBarListenable],滚动方向切换即翻转)→ 只重建
///   三个 AnimatedPositioned 定位包装,内容经 VLB child 缓存整棵短路
class TopicDetailOverlay extends StatelessWidget {
  final ValueListenable<bool> showBottomBarListenable;
  final bool isLoggedIn;
  final ValueListenable<int> streamIndexListenable;
  final int totalCount;
  final TopicDetail detail;
  final VoidCallback onScrollToTop;
  final VoidCallback onShare;
  final VoidCallback? onShareAsImage;
  final VoidCallback? onExport;
  final VoidCallback onOpenInBrowser;
  final VoidCallback onReply;
  final VoidCallback onProgressTap;
  final ValueChanged<ProgressGestureAction>? onProgressGesture;
  final bool isSummaryMode;
  final bool isActivityMode;
  final bool isAuthorOnlyMode;
  final bool isTopLevelMode;
  final bool isNestedMode;
  final bool isLoading;
  final VoidCallback? onShowTopReplies;
  final VoidCallback? onShowByActivity;
  final VoidCallback? onShowAuthorOnly;
  final VoidCallback? onShowTopLevelReplies;
  final VoidCallback? onCancelFilter;
  final VoidCallback? onShowNestedView;

  const TopicDetailOverlay({
    super.key,
    required this.showBottomBarListenable,
    required this.isLoggedIn,
    required this.streamIndexListenable,
    required this.totalCount,
    required this.detail,
    required this.onScrollToTop,
    required this.onShare,
    this.onShareAsImage,
    this.onExport,
    required this.onOpenInBrowser,
    required this.onReply,
    required this.onProgressTap,
    this.onProgressGesture,
    this.isSummaryMode = false,
    this.isActivityMode = false,
    this.isAuthorOnlyMode = false,
    this.isTopLevelMode = false,
    this.isNestedMode = false,
    this.isLoading = false,
    this.onShowTopReplies,
    this.onShowByActivity,
    this.onShowAuthorOnly,
    this.onShowTopLevelReplies,
    this.onCancelFilter,
    this.onShowNestedView,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    // 三块内容都不依赖 showBottomBar,只有 AnimatedPositioned 的 bottom
    // 依赖 —— 用 VLB 的 child 参数把内容缓存住,滚动方向切换(底栏
    // 显隐翻转,高频)时只重建定位包装,内容整棵短路(实测全量重建
    // 一次 7.4ms,常与楼层挂载同帧叠加成 40ms 级大帧)。
    return Stack(
      children: [
        // 固定的进度栏（嵌套模式下隐藏）。楼层号变化只重建 TopicProgress,
        // 手势层与定位动画不参与。
        if (!isNestedMode)
          ValueListenableBuilder<bool>(
            valueListenable: showBottomBarListenable,
            child: Center(
              child: TopicProgressGestures(
                onAction: onProgressGesture ?? (_) {},
                child: RepaintBoundary(
                  // 楼层号滚动中连续变化,elevation Card 的阴影+抗锯齿裁剪
                  // 重绘不便宜(耗时榜 Card/_ShapeBorderPaint ~3ms);独立
                  // 图层后自身重绘不与列表脏区互相放大,底栏显隐的位移也
                  // 只是 layer offset 平移
                  child: ValueListenableBuilder<int>(
                    valueListenable: streamIndexListenable,
                    builder: (context, currentStreamIndex, _) {
                      final progressPercent = totalCount > 1
                          ? (currentStreamIndex - 1) / (totalCount - 1)
                          : 0.0;
                      return TopicProgress(
                        currentIndex: currentStreamIndex,
                        totalCount: totalCount,
                        progressPercent: progressPercent,
                        onTap: onProgressTap,
                      );
                    },
                  ),
                ),
              ),
            ),
            builder: (context, showBottomBar, child) => AnimatedPositioned(
              key: const ValueKey('progress_bar'),
              duration: const Duration(milliseconds: 200),
              bottom: showBottomBar ? 96 : 24 + bottomPadding,
              left: 0,
              right: 0,
              child: child!,
            ),
          ),
        // 底部操作栏
        ValueListenableBuilder<bool>(
          valueListenable: showBottomBarListenable,
          child: TopicBottomBar(
            onScrollToTop: onScrollToTop,
            onShare: onShare,
            onShareAsImage: onShareAsImage,
            onExport: onExport,
            onOpenInBrowser: onOpenInBrowser,
            hasSummary: detail.hasSummary,
            isPostVoting: detail.isPostVoting,
            isSummaryMode: isSummaryMode,
            isActivityMode: isActivityMode,
            isAuthorOnlyMode: isAuthorOnlyMode,
            isTopLevelMode: isTopLevelMode,
            isNestedMode: isNestedMode,
            isLoading: isLoading,
            isPrivateMessage: detail.isPrivateMessage,
            onShowTopReplies: onShowTopReplies,
            onShowByActivity: onShowByActivity,
            onShowAuthorOnly: onShowAuthorOnly,
            onShowTopLevelReplies: onShowTopLevelReplies,
            onCancelFilter: onCancelFilter,
            onShowNestedView: onShowNestedView,
          ),
          builder: (context, showBottomBar, child) => AnimatedPositioned(
            key: const ValueKey('bottom_bar'),
            duration: const Duration(milliseconds: 200),
            left: 0,
            right: 0,
            bottom: showBottomBar ? 0 : -80,
            child: child!,
          ),
        ),
        // 悬浮回复按钮
        if (isLoggedIn)
          ValueListenableBuilder<bool>(
            valueListenable: showBottomBarListenable,
            child: FloatingActionButton(
              heroTag: 'replyTopic',
              onPressed: onReply,
              child: const Icon(Symbols.reply_rounded),
            ),
            builder: (context, showBottomBar, child) => AnimatedPositioned(
              key: const ValueKey('fab_reply'),
              duration: const Duration(milliseconds: 200),
              right: 16,
              bottom: showBottomBar
                  ? bottomPadding + (80 - bottomPadding - 56) / 2
                  : 16 + bottomPadding,
              child: child!,
            ),
          ),
      ],
    );
  }
}
