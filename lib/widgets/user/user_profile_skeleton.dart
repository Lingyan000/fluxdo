import 'package:flutter/material.dart';
import '../../utils/responsive.dart';
import '../common/grain_gradient_background.dart';
import '../common/skeleton.dart';

/// 用户资料页骨架屏
///
/// 与正式页面同一条宽窄分流([UserProfileWideLayout.minWidth],按实际
/// 可用宽度):宽版=左资料栏+右内容横排,竖版=折叠头图。loading 形态
/// 必须与加载完成后的成品形态一致,否则数据到达瞬间整页跳版式。
class UserProfileSkeleton extends StatelessWidget {
  const UserProfileSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= UserProfileWideLayout.minWidth) {
          return _buildWide(context);
        }
        return _buildNarrow(context);
      },
    );
  }

  /// 宽版骨架:左资料栏(头图横幅+骑缝头像+正常底色信息区)+ 右侧
  /// Tab 行与列表——与正式宽版同结构。
  Widget _buildWide(BuildContext context) {
    final theme = Theme.of(context);
    const bannerHeight = UserProfileWideLayout.bannerHeight;
    const avatarRadius = UserProfileWideLayout.avatarRadius;
    return Scaffold(
      body: Skeleton(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: UserProfileWideLayout.infoPanelWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SizedBox(
                        height: bannerHeight,
                        width: double.infinity,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const GrainGradientBackground(animated: false),
                            Container(
                              color: Colors.black.withValues(alpha: 0.2),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        left: 20,
                        bottom: -avatarRadius,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.scaffoldBackgroundColor,
                              width: 4,
                            ),
                          ),
                          child: _SkeletonCircleWhite(size: avatarRadius * 2),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: avatarRadius + 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SkeletonBox(width: 140, height: 26, borderRadius: 4),
                          const SizedBox(height: 8),
                          SkeletonBox(width: 100, height: 16, borderRadius: 4),
                          const SizedBox(height: 20),
                          SkeletonBox(
                            width: double.infinity,
                            height: 64,
                            borderRadius: 12,
                          ),
                          const SizedBox(height: 24),
                          SkeletonBox(width: 200, height: 40, borderRadius: 4),
                          const SizedBox(height: 16),
                          SkeletonBox(width: 260, height: 40, borderRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 1,
              child: ColoredBox(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  SafeArea(
                    bottom: false,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: Breakpoints.maxContentWidth,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _buildTabBarSkeleton(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: Breakpoints.maxContentWidth,
                        ),
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          itemCount: 5,
                          itemBuilder: (context, index) =>
                              const UserActionItemSkeleton(),
                        ),
                      ),
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

  /// 竖版骨架:折叠头图 + Tab + 列表(原形态)。
  Widget _buildNarrow(BuildContext context) {
    // 横屏时屏幕高度有限，限制 expandedHeight 不超过屏幕高度的 70%
    final screenHeight = MediaQuery.of(context).size.height;
    final double expandedHeight = 410.0.clamp(0.0, screenHeight * 0.7);
    // 与正式页面同口径的精简模式(见 UserProfilePage._buildSliverAppBar):
    // 高度装不下完整头部时骨架同步精简,保证 loading->成品不跳版式。
    final bool compactHeader = expandedHeight < 340;

    return Scaffold(
      body: Skeleton(
        child: CustomScrollView(
          slivers: [
            // AppBar 骨架屏
            SliverAppBar(
              expandedHeight: expandedHeight,
              pinned: true,
              stretch: true,
              elevation: 0,
              scrolledUnderElevation: 0,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              iconTheme: const IconThemeData(color: Colors.white),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _buildTabBarSkeleton(context),
                ),
              ),
              flexibleSpace: _buildFlexibleSpaceSkeleton(
                context,
                compact: compactHeader,
              ),
            ),
            // 内容骨架屏
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => const UserActionItemSkeleton(),
                  childCount: 5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBarSkeleton(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(6, (index) {
          // 不同宽度模拟真实 Tab 文字长度
          final widths = [32.0, 32.0, 32.0, 32.0, 24.0, 32.0];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SkeletonBox(
              width: widths[index],
              height: 20,
              borderRadius: 4,
            ),
          );
        }),
      ),
    );
  }

  Widget _buildFlexibleSpaceSkeleton(
    BuildContext context, {
    bool compact = false,
  }) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 背景 - 使用 GrainGradient，与正式页面同款
        // 骨架屏只需保持视觉一致，无需在加载期间持续提交 shader 帧。
        const GrainGradientBackground(animated: false),
        // 压暗遮罩（与正式页面展开时一致）
        Container(color: Colors.black.withValues(alpha: 0.6)),
        // 内容
        Positioned(
          left: 20 + MediaQuery.of(context).padding.left,
          right: 20 + MediaQuery.of(context).padding.right,
          bottom: 36 + (compact ? 12 : 24), // TabBar 高度 + 间距
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头像和信息行
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 头像 (radius=36 + border 2 = 76，但内部圆72)
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const _SkeletonCircleWhite(size: 72),
                  ),
                  const SizedBox(width: 16),
                  // 姓名和信息
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 名字 (fontSize: 22)
                        const _SkeletonBoxWhite(width: 120, height: 22),
                        const SizedBox(height: 2),
                        // 用户名 (fontSize:13, 下方留 bottom:6 给等级标签)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6),
                          child: _SkeletonBoxWhite(width: 80, height: 16),
                        ),
                        // 等级标签 (padding vertical:2, fontSize:10, 总高约18)
                        const _SkeletonBoxWhite(
                          width: 72,
                          height: 18,
                          borderRadius: 12,
                        ),
                      ],
                    ),
                  ),
                  // 关注按钮 (高度32)
                  const _SkeletonBoxWhite(
                    width: 72,
                    height: 32,
                    borderRadius: 18,
                  ),
                ],
              ),
              // 与真实页面一致：16 + 12 = 28
              const SizedBox(height: 16),
              // 签名区域 (高度54,精简模式与正式页面同步隐藏)
              if (!compact) ...[
                const SizedBox(height: 12),
                Container(
                  height: 54,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ],
              // 签名后间距
              const SizedBox(height: 16),
              // 统计行1：关注、粉丝（高度17）
              const _SkeletonBoxWhite(width: 140, height: 17),
              const SizedBox(height: 8),
              // 统计行2：获赞、访问、话题、回复（高度17）
              const _SkeletonBoxWhite(width: 200, height: 17),
              // 活动时间(精简模式与正式页面同步隐藏)
              if (!compact) ...[
                const SizedBox(height: 12),
                const _SkeletonBoxWhite(
                  width: 80,
                  height: 20,
                  borderRadius: 12,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 用户动态项骨架屏
class UserActionItemSkeleton extends StatelessWidget {
  const UserActionItemSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部：类型图标和时间
            Row(
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 8),
                SkeletonBox(width: 48, height: 14, borderRadius: 4),
                const Spacer(),
                SkeletonBox(width: 40, height: 12, borderRadius: 4),
              ],
            ),
            const SizedBox(height: 12),
            // 标题
            SkeletonBox(width: double.infinity, height: 18, borderRadius: 4),
            const SizedBox(height: 6),
            SkeletonBox(width: 180, height: 18, borderRadius: 4),
            const SizedBox(height: 10),
            // 摘要
            SkeletonBox(width: double.infinity, height: 14, borderRadius: 4),
            const SizedBox(height: 5),
            SkeletonBox(width: double.infinity, height: 14, borderRadius: 4),
            const SizedBox(height: 5),
            SkeletonBox(width: 120, height: 14, borderRadius: 4),
          ],
        ),
      ),
    );
  }
}

/// 用户动态列表骨架屏（用于 Tab 内容的初始加载）
class UserActionListSkeleton extends StatelessWidget {
  final int itemCount;

  const UserActionListSkeleton({super.key, this.itemCount = 5});

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: itemCount,
        itemBuilder: (context, index) => const UserActionItemSkeleton(),
      ),
    );
  }
}

/// 白色骨架框（用于深色背景）
class _SkeletonBoxWhite extends StatelessWidget {
  final double? width;
  final double height;
  final double borderRadius;

  const _SkeletonBoxWhite({
    this.width,
    required this.height,
    this.borderRadius = 4,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// 白色圆形骨架框（用于深色背景）
class _SkeletonCircleWhite extends StatelessWidget {
  final double size;

  const _SkeletonCircleWhite({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        shape: BoxShape.circle,
      ),
    );
  }
}
