import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import '../../../models/topic.dart';
import '../../../providers/preferences_provider.dart';
import '../../../widgets/topic/topic_progress.dart';
import 'topic_bottom_bar.dart';
import 'topic_progress_gestures.dart';

/// 话题详情页浮层
/// 包含进度栏、底部操作栏和悬浮回复按钮
class TopicDetailOverlay extends StatelessWidget {
  final bool showBottomBar;
  final bool isLoggedIn;
  final int currentStreamIndex;
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
  /// scrub 目标为真实楼层号 post_number（不是 stream 序号）
  final ValueChanged<int>? onProgressScrubToPostNumber;
  /// scrub 松手时的最终楼层（可做完整跳转）
  final ValueChanged<int>? onProgressScrubEnd;
  /// 当前可见帖的 post_number，供 scrub 起点
  final int currentPostNumber;
  /// 话题最大楼层号（posts_count）
  final int maxPostNumber;
  final bool isSummaryMode;
  final bool isAuthorOnlyMode;
  final bool isTopLevelMode;
  final bool isNestedMode;
  final bool isLoading;
  final VoidCallback? onShowTopReplies;
  final VoidCallback? onShowAuthorOnly;
  final VoidCallback? onShowTopLevelReplies;
  final VoidCallback? onCancelFilter;
  final VoidCallback? onShowNestedView;

  const TopicDetailOverlay({
    super.key,
    required this.showBottomBar,
    required this.isLoggedIn,
    required this.currentStreamIndex,
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
    this.onProgressScrubToPostNumber,
    this.onProgressScrubEnd,
    this.currentPostNumber = 1,
    this.maxPostNumber = 1,
    this.isSummaryMode = false,
    this.isAuthorOnlyMode = false,
    this.isTopLevelMode = false,
    this.isNestedMode = false,
    this.isLoading = false,
    this.onShowTopReplies,
    this.onShowAuthorOnly,
    this.onShowTopLevelReplies,
    this.onCancelFilter,
    this.onShowNestedView,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final progressPercent = totalCount > 1
        ? (currentStreamIndex - 1) / (totalCount - 1)
        : 0.0;

    return Stack(
      children: [
        // 固定的进度栏（嵌套模式下隐藏）
        if (!isNestedMode)
          AnimatedPositioned(
            key: const ValueKey('progress_bar'),
            duration: const Duration(milliseconds: 200),
            bottom: showBottomBar ? 96 : 24 + bottomPadding,
            left: 0,
            right: 0,
            child: Center(
              child: TopicProgressGestures(
                onAction: onProgressGesture ?? (_) {},
                // scrub 用真实楼层号，避免隐藏楼导致序号错位
                currentIndex: currentPostNumber,
                totalCount: maxPostNumber > 0 ? maxPostNumber : totalCount,
                onScrubToIndex: onProgressScrubToPostNumber ?? (_) {},
                onScrubEnd: onProgressScrubEnd,
                child: TopicProgress(
                  currentIndex: currentStreamIndex,
                  totalCount: totalCount,
                  progressPercent: progressPercent,
                  onTap: onProgressTap,
                ),
              ),
            ),
          ),
        // 底部操作栏
        AnimatedPositioned(
          key: const ValueKey('bottom_bar'),
          duration: const Duration(milliseconds: 200),
          left: 0,
          right: 0,
          bottom: showBottomBar ? 0 : -80,
          child: TopicBottomBar(
            onScrollToTop: onScrollToTop,
            onShare: onShare,
            onShareAsImage: onShareAsImage,
            onExport: onExport,
            onOpenInBrowser: onOpenInBrowser,
            hasSummary: detail.hasSummary,
            isSummaryMode: isSummaryMode,
            isAuthorOnlyMode: isAuthorOnlyMode,
            isTopLevelMode: isTopLevelMode,
            isNestedMode: isNestedMode,
            isLoading: isLoading,
            isPrivateMessage: detail.isPrivateMessage,
            onShowTopReplies: onShowTopReplies,
            onShowAuthorOnly: onShowAuthorOnly,
            onShowTopLevelReplies: onShowTopLevelReplies,
            onCancelFilter: onCancelFilter,
            onShowNestedView: onShowNestedView,
          ),
        ),
        // 悬浮回复按钮
        if (isLoggedIn)
          AnimatedPositioned(
            key: const ValueKey('fab_reply'),
            duration: const Duration(milliseconds: 200),
            right: 16,
            bottom: showBottomBar
                ? bottomPadding + (80 - bottomPadding - 56) / 2
                : 16 + bottomPadding,
            child: FloatingActionButton(
              heroTag: 'replyTopic',
              onPressed: onReply,
              child: const Icon(Symbols.reply_rounded),
            ),
          ),
      ],
    );
  }
}
