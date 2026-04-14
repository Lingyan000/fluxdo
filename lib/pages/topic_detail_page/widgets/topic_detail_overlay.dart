import 'package:flutter/material.dart';
import '../../../models/topic.dart';
import '../../../widgets/topic/topic_progress.dart';
import 'topic_bottom_bar.dart';

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
              child: TopicProgress(
                currentIndex: currentStreamIndex,
                totalCount: totalCount,
                progressPercent: progressPercent,
                onTap: onProgressTap,
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
              child: const Icon(Icons.reply),
            ),
          ),
      ],
    );
  }
}
