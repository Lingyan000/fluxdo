import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import '../common/skeleton.dart';

/// 帖子骨架屏
class PostItemSkeleton extends StatelessWidget {
  const PostItemSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像和用户信息行
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头像
              SkeletonCircle(size: 40),
              const SizedBox(width: 12),
              // 用户名和时间
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkeletonBox(width: 120, height: 16),
                    const SizedBox(height: 6),
                    SkeletonBox(width: 80, height: 12),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 内容区域（多行）
          SkeletonBox(width: double.infinity, height: 16),
          const SizedBox(height: 8),
          SkeletonBox(width: double.infinity, height: 16),
          const SizedBox(height: 8),
          SkeletonBox(width: 200, height: 16),
          const SizedBox(height: 16),
          // 操作按钮行
          Row(
            children: [
              SkeletonBox(width: 60, height: 32, borderRadius: 16),
              const SizedBox(width: 12),
              SkeletonBox(width: 60, height: 32, borderRadius: 16),
            ],
          ),
        ],
      ),
    );
  }
}

/// 单个骨架屏项的估算高度
const double kPostItemSkeletonHeight = 200.0;

/// 根据可用高度计算骨架屏数量
int calculateSkeletonCount(double availableHeight, {int minCount = 3}) {
  final count = (availableHeight / kPostItemSkeletonHeight).ceil();
  return count.clamp(minCount, 20);
}

/// 话题详情 Header 骨架屏
class TopicDetailHeaderSkeleton extends StatelessWidget {
  const TopicDetailHeaderSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PageBackgroundScope.contentColor(
          context,
          theme.colorScheme.surface,
        ),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题（两行）
          SkeletonBox(width: double.infinity, height: 24),
          const SizedBox(height: 8),
          SkeletonBox(width: 200, height: 24),
          const SizedBox(height: 12),
          // 分类和标签
          Row(
            children: [
              SkeletonBox(width: 80, height: 24, borderRadius: 4),
              const SizedBox(width: 8),
              SkeletonBox(width: 60, height: 24, borderRadius: 4),
            ],
          ),
          const SizedBox(height: 12),
          // 元数据行（回复、浏览、时间）
          Row(
            children: [
              SkeletonBox(width: 60, height: 14),
              const SizedBox(width: 16),
              SkeletonBox(width: 60, height: 14),
              const SizedBox(width: 16),
              SkeletonBox(width: 80, height: 14),
            ],
          ),
        ],
      ),
    );
  }
}

/// Header 骨架屏的估算高度
const double kTopicDetailHeaderSkeletonHeight = 150.0;

/// 帖子列表骨架屏（用于初始加载）
class PostListSkeleton extends StatelessWidget {
  final int? itemCount;
  final bool withHeader;

  const PostListSkeleton({
    super.key,
    this.itemCount,
    this.withHeader = false,
  });

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final appBarHeight = kToolbarHeight + MediaQuery.of(context).padding.top;
    var availableHeight = screenHeight - appBarHeight;

    if (withHeader) {
      availableHeight -= kTopicDetailHeaderSkeletonHeight;
    }

    final count = itemCount ?? calculateSkeletonCount(availableHeight);

    return Skeleton(
      child: ListView.builder(
        itemCount: count + (withHeader ? 1 : 0),
        itemBuilder: (context, index) {
          if (withHeader && index == 0) {
            return const TopicDetailHeaderSkeleton();
          }
          return const PostItemSkeleton();
        },
      ),
    );
  }
}

/// 增量加载骨架屏 Sliver（共享单一动画控制器）
class LoadingSkeletonSliver extends StatelessWidget {
  final int itemCount;
  final Widget Function(BuildContext context, Widget skeleton) wrapContent;

  const LoadingSkeletonSliver({
    super.key,
    required this.itemCount,
    required this.wrapContent,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Skeleton(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            itemCount,
            (index) => wrapContent(context, const PostItemSkeleton()),
          ),
        ),
      ),
    );
  }
}
