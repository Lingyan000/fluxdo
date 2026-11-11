import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../common/skeleton.dart';

/// 信任级别要求页骨架屏
class TrustLevelSkeleton extends StatelessWidget {
  const TrustLevelSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Skeleton(
      child: CustomScrollView(
        slivers: [
          // AppBar 骨架
          SliverAppBar.large(
            title: const Text('信任要求'),
            centerTitle: false,
            expandedHeight: 200,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      colorScheme.surface,
                      colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.5,
                      ),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -20,
                      top: -20,
                      child: Icon(
                        Symbols.verified_user_rounded,
                        size: 200,
                        color: context.emphasis.accent.withValues(alpha: 0.05),
                      ),
                    ),
                    Positioned(
                      left: 20 + MediaQuery.of(context).padding.left,
                      bottom: 20,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SkeletonBox(width: 120, height: 16),
                          const SizedBox(height: 8),
                          SkeletonBox(width: 180, height: 28),
                          const SizedBox(height: 12),
                          SkeletonBox(width: 60, height: 20, borderRadius: 20),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 内容骨架
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // 活跃程度卡片
                _buildCardSkeleton(
                  context,
                  height: 160,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildRingSkeleton(),
                      _buildRingSkeleton(),
                      _buildRingSkeleton(),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // 互动参与卡片
                _buildCardSkeleton(
                  context,
                  height: 300,
                  child: Column(
                    children: List.generate(
                      5,
                      (index) => _buildBarSkeleton(),
                    ).toList(),
                  ),
                ),
                const SizedBox(height: 16),
                // 合规记录卡片
                _buildCardSkeleton(
                  context,
                  height: 220,
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: SkeletonBox(height: 80, borderRadius: 12),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SkeletonBox(height: 80, borderRadius: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: SkeletonBox(height: 100, borderRadius: 12),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SkeletonBox(height: 100, borderRadius: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCardSkeleton(
    BuildContext context, {
    required double height,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: ShapeDecoration(
        color: colorScheme.surfaceContainerLow,
        shape: RoundedSuperellipseBorder(
          borderRadius: context.shapes.borderRadius(16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: 80, height: 18),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }

  Widget _buildRingSkeleton() {
    return Column(
      children: [
        SkeletonCircle(size: 80),
        const SizedBox(height: 12),
        SkeletonBox(width: 40, height: 12),
      ],
    );
  }

  Widget _buildBarSkeleton() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SkeletonBox(width: 60, height: 14),
              SkeletonBox(width: 40, height: 14),
            ],
          ),
          const SizedBox(height: 8),
          SkeletonBox(width: double.infinity, height: 8),
        ],
      ),
    );
  }
}
