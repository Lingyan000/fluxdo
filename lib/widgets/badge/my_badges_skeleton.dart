import 'package:flutter/material.dart';

import '../common/skeleton.dart';
import '../../../../../l10n/s.dart';

/// 我的徽章页骨架屏
class MyBadgesSkeleton extends StatelessWidget {
  const MyBadgesSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Skeleton(
      child: CustomScrollView(
        slivers: [
          // AppBar 骨架
          SliverAppBar.large(
            title: Text(S.current.badge_myBadges),
            centerTitle: false,
            expandedHeight: 200,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colorScheme.surface,
                      colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.5,
                      ),
                    ],
                  ),
                ),
                child: Stack(
                  children: [
                    // 统计信息骨架
                    Positioned(
                      left: 20 + MediaQuery.of(context).padding.left,
                      bottom: 20,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SkeletonBox(width: 50, height: 14),
                          const SizedBox(height: 8),
                          SkeletonBox(width: 40, height: 36),
                          const SizedBox(height: 6),
                          SkeletonBox(width: 36, height: 14),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(top: 16)),
          // 徽章分类骨架
          _buildBadgeSectionSkeleton(context),
          _buildBadgeSectionSkeleton(context),
          const SliverPadding(padding: EdgeInsets.only(bottom: 48)),
        ],
      ),
    );
  }

  Widget _buildBadgeSectionSkeleton(BuildContext context) {
    return SliverMainAxisGroup(
      slivers: [
        // 分类标题骨架
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                SkeletonBox(width: 20, height: 20, borderRadius: 4),
                const SizedBox(width: 12),
                SkeletonBox(width: 60, height: 18),
                const Spacer(),
                SkeletonBox(width: 28, height: 22, borderRadius: 11),
              ],
            ),
          ),
        ),
        // 徽章网格骨架
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              childAspectRatio: 1.35,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildBadgeItemSkeleton(context),
              childCount: 4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBadgeItemSkeleton(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 图标骨架
          SkeletonCircle(size: 48),
          const SizedBox(height: 8),
          // 名称骨架
          SkeletonBox(width: 80, height: 14),
          const SizedBox(height: 4),
          SkeletonBox(width: 60, height: 14),
        ],
      ),
    );
  }
}
