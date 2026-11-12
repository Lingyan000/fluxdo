import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../utils/responsive.dart';
import '../common/skeleton.dart';

/// 加载占位沿用资料页的宽窄排版和内容流结构。
class UserProfileSkeleton extends StatelessWidget {
  const UserProfileSkeleton({
    super.key,
    this.embeddedMode = false,
    this.onBack,
  });
  final bool embeddedMode;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => PageBackdrop(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: UserProfileWideLayout.maxWidth,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final topInset = MediaQuery.paddingOf(context).top;
            final wide =
                constraints.maxWidth >= UserProfileWideLayout.minWidth &&
                constraints.maxWidth >=
                    MediaQuery.textScalerOf(context).scale(14) * 60;
            final coverHeight = (constraints.maxWidth / 3).clamp(
              topInset + kToolbarHeight + 32,
              224.0,
            );
            return Scaffold(
              body: Skeleton(
                child: Stack(
                  children: [
                    ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        SizedBox(
                          height: coverHeight + 80,
                          child: Stack(
                            children: [
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                height: coverHeight,
                                child: SkeletonBox(
                                  width: double.infinity,
                                  height: coverHeight,
                                ),
                              ),
                              Positioned(
                                left: wide ? 24 : 16,
                                top: coverHeight - 16,
                                child: const SkeletonCircle(size: 80),
                              ),
                              if (wide)
                                Positioned(
                                  left: 128,
                                  top: coverHeight + 12,
                                  child: const Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SkeletonBox(width: 160, height: 24),
                                      SizedBox(height: 6),
                                      SkeletonBox(width: 100, height: 14),
                                    ],
                                  ),
                                ),
                              Positioned(
                                right: 16,
                                top: coverHeight + 8,
                                child: const SkeletonCircle(size: 40),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (!wide) ...[
                                const SkeletonBox(width: 160, height: 24),
                                const SizedBox(height: 6),
                                const SkeletonBox(width: 100, height: 14),
                                const SizedBox(height: 16),
                              ],
                              SkeletonBox(
                                width: wide ? 600 : double.infinity,
                                height: 36,
                              ),
                              const SizedBox(height: 12),
                              const SkeletonBox(width: 180, height: 14),
                              const SizedBox(height: 16),
                              const SkeletonBox(width: 200, height: 16),
                              const SizedBox(height: 16),
                              if (!wide) ...[
                                const SkeletonBox(
                                  width: double.infinity,
                                  height: 48,
                                ),
                                const SizedBox(height: 16),
                              ],
                            ],
                          ),
                        ),
                        const PageBackdrop(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                SkeletonBox(width: 64, height: 18),
                                SkeletonBox(width: 20, height: 18),
                                SkeletonBox(width: 20, height: 18),
                                SkeletonBox(width: 20, height: 18),
                              ],
                            ),
                          ),
                        ),
                        const UserSummaryStatsSkeleton(),
                      ],
                    ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: topInset + kToolbarHeight,
                      child: AppBar(
                        forceMaterialTransparency: true,
                        automaticallyImplyLeading: !embeddedMode,
                        leading: embeddedMode && onBack != null
                            ? BackButton(onPressed: onBack)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class UserActionItemSkeleton extends StatelessWidget {
  const UserActionItemSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SkeletonCircle(size: 40),
        const SizedBox(width: 10),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(width: 140, height: 16),
              SizedBox(height: 10),
              SkeletonBox(width: double.infinity, height: 18),
              SizedBox(height: 8),
              SkeletonBox(width: double.infinity, height: 14),
              SizedBox(height: 6),
              SkeletonBox(width: double.infinity, height: 14),
              SizedBox(height: 12),
              SkeletonBox(width: 70, height: 12),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 用户动态列表骨架屏（用于 Tab 内容的初始加载）
class UserActionListSkeleton extends StatelessWidget {
  final int itemCount;

  const UserActionListSkeleton({super.key, this.itemCount = 5});

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: itemCount,
        itemBuilder: (context, index) => const UserActionItemSkeleton(),
      ),
    );
  }
}

/// 总览统计的加载占位与真实分组使用相同结构。
class UserSummaryStatsSkeleton extends StatelessWidget {
  const UserSummaryStatsSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Skeleton(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available =
              constraints.maxWidth / MediaQuery.textScalerOf(context).scale(14);
          final columns = available >= 52
              ? 4
              : available >= 14
              ? 2
              : 1;
          return SegmentedCardGroup(
            children: [
              for (var row = 0; row < 4; row += columns)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      for (var column = 0; column < columns; column++)
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBox(width: 18, height: 18),
                              SizedBox(height: 10),
                              SkeletonBox(width: 52, height: 28),
                              SizedBox(height: 6),
                              SkeletonBox(width: 40, height: 14),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
