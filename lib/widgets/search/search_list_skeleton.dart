import 'package:flutter/material.dart';
import '../common/skeleton.dart';

/// 搜索结果列表骨架屏 — 匹配 SearchPostCard 的标题置顶布局:
/// 标题两行 / 摘要两行 / 头像跨两行 + 用户名·时间 / 分类·统计
class SearchListSkeleton extends StatelessWidget {
  final EdgeInsetsGeometry padding;

  const SearchListSkeleton({
    super.key,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: padding,
        itemCount: 6,
        itemBuilder: (context, index) => const _SearchPostCardSkeleton(),
      ),
    );
  }
}

class _SearchPostCardSkeleton extends StatelessWidget {
  const _SearchPostCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题满宽两行(次行部分宽)
            SkeletonBox(width: double.infinity, height: 15),
            const SizedBox(height: 4),
            SkeletonBox(width: 200, height: 15),
            const SizedBox(height: 6),
            // 摘要两行
            SkeletonBox(width: double.infinity, height: 12),
            const SizedBox(height: 4),
            SkeletonBox(width: 240, height: 12),
            const SizedBox(height: 8),
            // 署名块:头像 32 跨两行,右侧用户名/时间、分类/统计
            Row(
              children: [
                const SkeletonCircle(size: 32),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SkeletonBox(width: 72, height: 11),
                          const Spacer(),
                          SkeletonBox(width: 44, height: 11),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          SkeletonBox(width: 110, height: 11),
                          const Spacer(),
                          SkeletonBox(width: 32, height: 11),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
