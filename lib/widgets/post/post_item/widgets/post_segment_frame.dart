import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../l10n/s.dart';
import '../../../../models/topic.dart';
import '../../../../providers/preferences_provider.dart';

/// 护眼气泡在长帖分段中的位置，用于拼成完整卡片。
enum EyeCareBubblePart {
  /// 整楼（短帖）
  full,

  /// 长帖头部
  start,

  /// 长帖中间内容块
  middle,

  /// 长帖底部
  end,
}

class PostSegmentFrame extends ConsumerWidget {
  final Post post;
  final bool selected;
  final bool highlight;
  final Widget child;
  final bool showTopDateSeparator;
  final String? topDateSeparatorLabel;
  final bool showBottomDateSeparator;
  final String? bottomDateSeparatorLabel;
  final bool showDivider;
  final bool showBottomBorder;
  final BoxConstraints? constraints;
  final bool isTopicOwner;
  final EyeCareBubblePart eyeCareBubblePart;

  const PostSegmentFrame({
    super.key,
    required this.post,
    required this.selected,
    required this.highlight,
    required this.child,
    this.showTopDateSeparator = false,
    this.topDateSeparatorLabel,
    this.showBottomDateSeparator = false,
    this.bottomDateSeparatorLabel,
    this.showDivider = false,
    this.showBottomBorder = true,
    this.constraints,
    this.isTopicOwner = false,
    this.eyeCareBubblePart = EyeCareBubblePart.full,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final eyeCareBubbles = ref.watch(
      preferencesProvider.select((p) => p.eyeCareBubbles),
    );
    final targetColor = buildPostTargetColor(
      theme,
      post,
      highlight,
      eyeCareBubbles: eyeCareBubbles,
      isTopicOwner: isTopicOwner,
    );
    final borderColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.5);

    final Widget framed = eyeCareBubbles
        ? _buildEyeCareBubble(
            context: context,
            theme: theme,
            targetColor: targetColor,
          )
        : Container(
            constraints: constraints,
            decoration: BoxDecoration(
              color: targetColor,
              border: Border(
                bottom: showBottomBorder
                    ? BorderSide(color: borderColor, width: 0.5)
                    : BorderSide.none,
              ),
            ),
            child: _buildInnerStack(context, theme, targetColor),
          );

    return RepaintBoundary(
      child: Opacity(
        opacity: post.isDeleted || post.hidden ? 0.6 : 1.0,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            framed,
            if (selected)
              _PostSelectionIndicator(
                color: buildPostSelectionIndicatorColor(theme),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEyeCareBubble({
    required BuildContext context,
    required ThemeData theme,
    required Color targetColor,
  }) {
    final palette = eyeCareBubblePalette(theme, isTopicOwner: isTopicOwner);
    final radius = eyeCareBubbleRadius(eyeCareBubblePart);
    final margin = eyeCareBubbleMargin(eyeCareBubblePart);
    final showShadow =
        eyeCareBubblePart == EyeCareBubblePart.full ||
        eyeCareBubblePart == EyeCareBubblePart.start;
    // 长帖拆成 start/middle/end 后若每段各自画完整渐变，
    // 段与段交界会从浅色跳回深色，形成绿色断层。
    // 渐变只留给完整短帖；分段统一用纯色，视觉上拼成一张卡。
    // 跳转高亮时也禁用渐变，避免高亮叠色与渐变同时出现脏色。
    final useGradient =
        eyeCareBubblePart == EyeCareBubblePart.full &&
        !highlight &&
        !post.isDeleted &&
        !post.hidden;
    // 高亮用更深边框提示，不再叠 primaryContainer（肤色）到绿/黄卡上
    final borderColor = highlight
        ? Color.alphaBlend(
            theme.brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.22)
                : Colors.black.withValues(alpha: 0.12),
            palette.border,
          )
        : palette.border;

    return Padding(
      padding: margin,
      child: Container(
        constraints: constraints,
        decoration: BoxDecoration(
          color: targetColor,
          gradient: useGradient ? palette.gradient : null,
          borderRadius: radius,
          border: eyeCareBubbleBorder(borderColor, eyeCareBubblePart),
          boxShadow: showShadow
              ? [
                  BoxShadow(
                    color: palette.shadow,
                    // Windows 软件合成大 blur 很贵；护眼气泡只保留轻阴影。
                    blurRadius: Platform.isWindows
                        ? (highlight ? 8 : 6)
                        : (highlight ? 22 : 18),
                    offset: Offset(0, Platform.isWindows ? 3 : 8),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: _buildInnerStack(context, theme, targetColor),
        ),
      ),
    );
  }

  Widget _buildInnerStack(
    BuildContext context,
    ThemeData theme,
    Color targetColor,
  ) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showDivider)
              SelectionContainer.disabled(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 12,
                  ),
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.3,
                  ),
                  child: Text(
                    context.l10n.post_lastReadHere,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            child,
          ],
        ),
        if (showTopDateSeparator && topDateSeparatorLabel != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FractionalTranslation(
              translation: const Offset(0, -0.5),
              child: Center(
                child: SelectionContainer.disabled(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 1,
                    ),
                    color: targetColor,
                    child: Text(
                      topDateSeparatorLabel!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.6,
                        ),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (showBottomDateSeparator && bottomDateSeparatorLabel != null)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: FractionalTranslation(
              translation: const Offset(0, 0.5),
              child: Center(
                child: SelectionContainer.disabled(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 1,
                    ),
                    color: targetColor,
                    child: Text(
                      bottomDateSeparatorLabel!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: 0.6,
                        ),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PostSelectionIndicator extends StatelessWidget {
  const _PostSelectionIndicator({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(color: color),
          child: const SizedBox(width: 3),
        ),
      ),
    );
  }
}

/// 护眼气泡色板（对齐 Linux.do 暖黄默认主题）
class EyeCareBubblePalette {
  final Color card;
  final Color border;
  final Color shadow;
  final LinearGradient? gradient;

  const EyeCareBubblePalette({
    required this.card,
    required this.border,
    required this.shadow,
    this.gradient,
  });
}

EyeCareBubblePalette eyeCareBubblePalette(
  ThemeData theme, {
  required bool isTopicOwner,
}) {
  final isDark = theme.brightness == Brightness.dark;
  if (isTopicOwner) {
    if (isDark) {
      const top = Color(0xFF243528);
      const bottom = Color(0xFF1C2A20);
      return const EyeCareBubblePalette(
        card: bottom,
        border: Color(0xFF4F7A4A),
        shadow: Color(0x33000000),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ),
      );
    }
    const top = Color(0xFFD8EDCC);
    const bottom = Color(0xFFEAF6DF);
    return const EyeCareBubblePalette(
      card: bottom,
      border: Color(0xFF9FCA88),
      shadow: Color(0x144B7535),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [top, bottom],
      ),
    );
  }

  if (isDark) {
    return const EyeCareBubblePalette(
      card: Color(0xFF2A2618),
      border: Color(0xFF5A4F32),
      shadow: Color(0x33000000),
    );
  }
  return const EyeCareBubblePalette(
    card: Color(0xFFFFF8DF),
    border: Color(0xFFEAD9A6),
    shadow: Color(0x145D4819),
  );
}

BorderRadius eyeCareBubbleRadius(EyeCareBubblePart part) {
  const r = Radius.circular(18);
  return switch (part) {
    EyeCareBubblePart.full => const BorderRadius.all(r),
    EyeCareBubblePart.start => const BorderRadius.only(
      topLeft: r,
      topRight: r,
    ),
    EyeCareBubblePart.middle => BorderRadius.zero,
    EyeCareBubblePart.end => const BorderRadius.only(
      bottomLeft: r,
      bottomRight: r,
    ),
  };
}

EdgeInsets eyeCareBubbleMargin(EyeCareBubblePart part) {
  const horizontal = 8.0;
  return switch (part) {
    EyeCareBubblePart.full => const EdgeInsets.fromLTRB(
      horizontal,
      0,
      horizontal,
      12,
    ),
    EyeCareBubblePart.start => const EdgeInsets.fromLTRB(
      horizontal,
      0,
      horizontal,
      0,
    ),
    EyeCareBubblePart.middle => const EdgeInsets.symmetric(
      horizontal: horizontal,
    ),
    EyeCareBubblePart.end => const EdgeInsets.fromLTRB(
      horizontal,
      0,
      horizontal,
      12,
    ),
  };
}

Border eyeCareBubbleBorder(Color color, EyeCareBubblePart part) {
  final borderSide = BorderSide(color: color, width: 1);
  return switch (part) {
    EyeCareBubblePart.full => Border.fromBorderSide(borderSide),
    EyeCareBubblePart.start => Border(
      top: borderSide,
      left: borderSide,
      right: borderSide,
    ),
    EyeCareBubblePart.middle => Border(
      left: borderSide,
      right: borderSide,
    ),
    EyeCareBubblePart.end => Border(
      left: borderSide,
      right: borderSide,
      bottom: borderSide,
    ),
  };
}

/// 判断帖子是否为楼主（护眼气泡绿卡）。
///
/// [createdByUsername] 来自话题 details.created_by；若尚未解析到，
/// 用 [postNumber] == 1 兜底，避免主楼先被画成回帖暖黄再闪成绿。
bool isEyeCareTopicOwner({
  required String postUsername,
  required int postNumber,
  String? createdByUsername,
}) {
  final owner = createdByUsername;
  if (owner != null && owner.isNotEmpty) {
    return owner == postUsername;
  }
  return postNumber == 1;
}

Color buildPostTargetColor(
  ThemeData theme,
  Post post,
  bool highlight, {
  bool eyeCareBubbles = false,
  bool isTopicOwner = false,
}) {
  final backgroundColor = eyeCareBubbles
      ? eyeCareBubblePalette(theme, isTopicOwner: isTopicOwner).card
      : theme.colorScheme.surface;
  if (highlight) {
    // 护眼气泡开启时：勿用 primaryContainer（主题肤色/桃色）叠在绿/黄卡上，
    // 否则进帖跳转高亮约 2 秒会出现「肤色+绿色」脏色。
    // 底色保持纯卡色，高亮只靠边框加深（见 _buildEyeCareBubble）。
    if (eyeCareBubbles) {
      return backgroundColor;
    }
    return Color.alphaBlend(
      theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
      backgroundColor,
    );
  }
  return post.isDeleted
      ? theme.colorScheme.errorContainer.withValues(alpha: 0.15)
      : post.hidden
      ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3)
      : backgroundColor;
}

Color buildPostSelectionIndicatorColor(ThemeData theme) {
  return theme.colorScheme.primary;
}
