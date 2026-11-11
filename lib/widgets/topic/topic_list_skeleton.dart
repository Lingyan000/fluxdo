import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../common/skeleton.dart';

/// 话题列表骨架屏
class TopicListSkeleton extends StatelessWidget {
  final EdgeInsetsGeometry padding;

  /// Gmail 式私信卡骨架(发件人置顶、主题次行),私信列表用
  final bool messageStyle;

  const TopicListSkeleton({
    super.key,
    this.padding = const EdgeInsets.all(12),
    this.messageStyle = false,
  });

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: padding,
        itemCount: 8,
        itemBuilder: (context, index) => messageStyle
            ? const _MessageCardSkeleton()
            : const _TopicCardSkeleton(),
      ),
    );
  }
}

/// 单个话题卡片的骨架屏 — 匹配标题置顶布局:
/// 标题两行 / 头像跨两行 + 昵称·时间 / 分类·统计
class _TopicCardSkeleton extends StatelessWidget {
  const _TopicCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: PageBackgroundScope.isActive(context) ? Colors.transparent : null,
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      shape: RoundedSuperellipseBorder(borderRadius: context.shapes.borderRadius(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题满宽两行(次行部分宽)
            SkeletonBox(width: double.infinity, height: 16),
            const SizedBox(height: 4),
            SkeletonBox(width: 180, height: 16),
            const SizedBox(height: 8),
            // 署名块:头像 32 跨两行,右侧昵称/时间、分类/统计
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

/// 私信卡骨架 — Gmail 式:头像 40 + 发件人·时间 / 主题
class _MessageCardSkeleton extends StatelessWidget {
  const _MessageCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: PageBackgroundScope.isActive(context) ? Colors.transparent : null,
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      shape: RoundedSuperellipseBorder(borderRadius: context.shapes.borderRadius(10)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SkeletonCircle(size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 发件人 ······ 时间
                  Row(
                    children: [
                      SkeletonBox(width: 96, height: 14),
                      const Spacer(),
                      SkeletonBox(width: 44, height: 11),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 会话主题
                  SkeletonBox(width: double.infinity, height: 14),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
