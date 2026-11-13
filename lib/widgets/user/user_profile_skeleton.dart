import 'dart:math' as math;

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../utils/responsive.dart';
import '../common/skeleton.dart';
import 'activity_card_layout.dart';

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

enum UserActivitySkeletonType {
  post,
  reply,
  quoted,
  receivedLike,
  reaction,
  boost,
  topic,
}

class UserActionItemSkeleton extends StatelessWidget {
  const UserActionItemSkeleton({
    super.key,
    this.type = UserActivitySkeletonType.post,
  });

  final UserActivitySkeletonType type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final authorStyle = theme.textTheme.labelLarge!;
    final authorHeight =
        scaler.scale(authorStyle.fontSize!) * (authorStyle.height ?? 1);
    final metadataHeight =
        (scaler.scale(theme.textTheme.bodySmall!.fontSize!) * 1.4)
            .ceilToDouble();
    final titleHeight =
        scaler.scale(theme.textTheme.titleSmall!.fontSize!) * 1.4;
    final quoted =
        type == UserActivitySkeletonType.quoted ||
        type == UserActivitySkeletonType.receivedLike ||
        type == UserActivitySkeletonType.reaction;
    final bodyStyle = quoted
        ? theme.textTheme.bodyMedium!
        : theme.textTheme.bodyLarge!;
    final bodyHeight = scaler.scale(bodyStyle.fontSize!) * 1.5;
    final bodyFirst = type == UserActivitySkeletonType.reply;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (type == UserActivitySkeletonType.receivedLike) ...[
          ActivityCardHeader(
            metadata: Row(
              children: [
                Flexible(
                  child: SkeletonBox(width: 180, height: metadataHeight),
                ),
              ],
            ),
            timestamp: SkeletonBox(width: 40, height: metadataHeight),
          ),
          const SizedBox(height: 12),
        ],
        ActivityCardHeader(
          avatar: const SizedBox(
            width: 44,
            height: 44,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: SkeletonCircle(size: 36),
            ),
          ),
          identity: SkeletonBox(width: 120, height: authorHeight),
          metadata: SkeletonBox(
            key: const ValueKey('activity-skeleton-metadata'),
            width: 100,
            height: metadataHeight,
          ),
          timestamp: type == UserActivitySkeletonType.receivedLike
              ? null
              : SkeletonBox(width: 40, height: metadataHeight),
        ),
        if (bodyFirst) ...[
          const SizedBox(height: 12),
          SkeletonBox(width: double.infinity, height: bodyHeight * 2),
        ],
        const SizedBox(height: 12),
        Padding(
          padding: EdgeInsets.only(left: bodyFirst ? 21 : 0),
          child: SkeletonBox(
            key: const ValueKey('activity-skeleton-title'),
            width: double.infinity,
            height: bodyFirst
                ? scaler.scale(theme.textTheme.bodySmall!.fontSize!) * 1.5
                : titleHeight,
          ),
        ),
        if (type == UserActivitySkeletonType.reaction) ...[
          const SizedBox(height: 10),
          const SkeletonBox(width: 28, height: 28),
        ],
        if (!bodyFirst && type != UserActivitySkeletonType.topic) ...[
          const SizedBox(height: 10),
          if (quoted)
            SkeletonBox(
              width: double.infinity,
              height: bodyHeight * 2 + 20,
              borderRadius: 10,
            )
          else
            SkeletonBox(width: double.infinity, height: bodyHeight * 2),
        ],
        if (type == UserActivitySkeletonType.boost) ...[
          const SizedBox(height: 10),
          const SkeletonBox(width: 200, height: 44, borderRadius: 22),
        ],
        const SizedBox(height: 4),
        SizedBox(
          height: math.max(44, metadataHeight + 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SkeletonBox(width: 120, height: metadataHeight),
          ),
        ),
        if (type == UserActivitySkeletonType.topic) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              for (var index = 0; index < 3; index++)
                SkeletonBox(width: 44, height: metadataHeight),
            ],
          ),
        ],
      ],
    );
  }
}

/// 用户动态列表骨架屏（用于 Tab 内容的初始加载）
class UserActionListSkeleton extends StatelessWidget {
  final int itemCount;

  final UserActivitySkeletonType type;

  const UserActionListSkeleton({
    super.key,
    this.itemCount = 5,
    this.type = UserActivitySkeletonType.post,
  });

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: itemCount,
        itemBuilder: (context, index) => ActivityCardFrame(
          position: (index: index, count: itemCount),
          child: UserActionItemSkeleton(type: type),
        ),
      ),
    );
  }
}

/// 徽章列表沿用分组标题与双行条目的占位结构。
class UserBadgeListSkeleton extends StatelessWidget {
  const UserBadgeListSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Skeleton(
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SkeletonBox(width: 64, height: 20),
          ),
        ),
        SegmentedCardGroup(
          children: [
            for (var index = 0; index < 4; index++)
              const ListTile(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                leading: SkeletonBox(width: 24, height: 24),
                title: Align(
                  alignment: Alignment.centerLeft,
                  child: SkeletonBox(width: 120, height: 20),
                ),
                subtitle: Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: SkeletonBox(width: double.infinity, height: 16),
                ),
              ),
          ],
        ),
      ],
    ),
  );
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
