import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../utils/responsive.dart';
import '../common/skeleton.dart';

/// 加载占位沿用资料页的单列阅读宽度和内容流结构。
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
          maxWidth: Breakpoints.maxContentWidth,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final topInset = MediaQuery.paddingOf(context).top;
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
                                left: 16,
                                top: coverHeight - 16,
                                child: const SkeletonCircle(size: 80),
                              ),
                              Positioned(
                                right: 16,
                                top: coverHeight + 8,
                                child: const SkeletonCircle(size: 40),
                              ),
                            ],
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SkeletonBox(width: 160, height: 24),
                              SizedBox(height: 6),
                              SkeletonBox(width: 100, height: 14),
                              SizedBox(height: 16),
                              SkeletonBox(width: double.infinity, height: 36),
                              SizedBox(height: 12),
                              SkeletonBox(width: 180, height: 14),
                              SizedBox(height: 16),
                              SkeletonBox(width: 200, height: 16),
                              SizedBox(height: 16),
                              SkeletonBox(width: double.infinity, height: 48),
                              SizedBox(height: 16),
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
                        for (var index = 0; index < 4; index++)
                          const UserActionItemSkeleton(),
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
