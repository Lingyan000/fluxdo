import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../../../models/topic.dart';
import '../../../../../services/discourse_cache_manager.dart';

export '../../../../../models/topic.dart' show LinkCount;

/// Onebox 基础容器
class OneboxContainer extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets margin;
  final EdgeInsets padding;
  final double borderRadius;

  const OneboxContainer({
    super.key,
    required this.child,
    this.onTap,
    this.margin = const EdgeInsets.symmetric(vertical: 8),
    this.padding = const EdgeInsets.all(12),
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: margin,
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(borderRadius),
          side: BorderSide(color: theme.colorScheme.outlineVariant, width: 1),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Onebox 带头部的容器
class OneboxContainerWithHeader extends StatelessWidget {
  final Widget header;
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets margin;
  final double borderRadius;

  const OneboxContainerWithHeader({
    super.key,
    required this.header,
    required this.child,
    this.onTap,
    this.margin = const EdgeInsets.symmetric(vertical: 8),
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = theme.colorScheme.outlineVariant;

    return Container(
      margin: margin,
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(borderRadius),
          side: BorderSide(color: borderColor, width: 1),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: borderColor)),
              ),
              child: header,
            ),
            Padding(padding: const EdgeInsets.all(12), child: child),
          ],
        ),
      ),
    );
  }
}

/// 统计项组件（star、fork、issue 数等）
class OneboxStatItem extends StatelessWidget {
  final IconData icon;
  final String value;
  final Color? iconColor;
  final double iconSize;
  final TextStyle? textStyle;

  const OneboxStatItem({
    super.key,
    required this.icon,
    required this.value,
    this.iconColor,
    this.iconSize = 14,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: iconSize,
          color: iconColor ?? theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style:
              textStyle ??
              theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

/// 标签组件
class OneboxLabel extends StatelessWidget {
  final String text;
  final Color? backgroundColor;
  final Color? textColor;

  const OneboxLabel({
    super.key,
    required this.text,
    this.backgroundColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: ShapeDecoration(
        color: backgroundColor ?? theme.colorScheme.surfaceContainerHigh,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: textColor ?? theme.colorScheme.onSurfaceVariant,
          fontSize: 10,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 状态指示器（开启/关闭/合并等）
class OneboxStatusIndicator extends StatelessWidget {
  final String status;
  final Color color;
  final IconData? icon;

  const OneboxStatusIndicator({
    super.key,
    required this.status,
    required this.color,
    this.icon,
  });

  /// GitHub Issue 开启状态
  factory OneboxStatusIndicator.issueOpen() {
    return const OneboxStatusIndicator(
      status: 'Open',
      color: Color(0xFF238636),
      icon: Symbols.circle_rounded,
    );
  }

  /// GitHub Issue 关闭状态
  factory OneboxStatusIndicator.issueClosed() {
    return const OneboxStatusIndicator(
      status: 'Closed',
      color: Color(0xFF8957e5),
      icon: Symbols.check_circle_rounded,
    );
  }

  /// GitHub PR 开启状态
  factory OneboxStatusIndicator.prOpen() {
    return const OneboxStatusIndicator(
      status: 'Open',
      color: Color(0xFF238636),
      icon: Symbols.call_merge_rounded,
    );
  }

  /// GitHub PR 合并状态
  factory OneboxStatusIndicator.prMerged() {
    return const OneboxStatusIndicator(
      status: 'Merged',
      color: Color(0xFF8957e5),
      icon: Symbols.merge_rounded,
    );
  }

  /// GitHub PR 关闭状态
  factory OneboxStatusIndicator.prClosed() {
    return const OneboxStatusIndicator(
      status: 'Closed',
      color: Color(0xFFda3633),
      icon: Symbols.close_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.15),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: color.withValues(alpha: 0.3)),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            status,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 点击数徽章（统一样式）
class OneboxClickCount extends StatelessWidget {
  final String count;

  const OneboxClickCount({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Symbols.visibility_rounded,
            size: 10,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            count,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10,
              color: theme.colorScheme.onSurfaceVariant,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 来源头部组件
class OneboxSourceHeader extends StatelessWidget {
  final String? iconUrl;
  final String sourceName;
  final String? clickCount;

  const OneboxSourceHeader({
    super.key,
    this.iconUrl,
    required this.sourceName,
    this.clickCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        if (iconUrl != null && iconUrl!.isNotEmpty) ...[
          Image(
            image: discourseImageProvider(iconUrl!),
            width: 16,
            height: 16,
            errorBuilder: (context, error, stackTrace) {
              return const Icon(Symbols.link_rounded, size: 16);
            },
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            sourceName,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (clickCount != null) ...[
          const SizedBox(width: 8),
          OneboxClickCount(count: clickCount!),
        ],
      ],
    );
  }
}

/// 头像组件
class OneboxAvatar extends StatelessWidget {
  final String? imageUrl;
  final double size;
  final double borderRadius;
  final IconData fallbackIcon;

  const OneboxAvatar({
    super.key,
    this.imageUrl,
    this.size = 40,
    this.borderRadius = 20,
    this.fallbackIcon = Symbols.person_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (imageUrl == null || imageUrl!.isEmpty) {
      return _buildFallback(theme);
    }

    return ClipRSuperellipse(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image(
        image: discourseImageProvider(imageUrl!),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildFallback(theme),
      ),
    );
  }

  Widget _buildFallback(ThemeData theme) {
    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: theme.colorScheme.primaryContainer,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
      child: Icon(
        fallbackIcon,
        color: theme.colorScheme.onPrimaryContainer,
        size: size * 0.5,
      ),
    );
  }
}

/// 从 onebox 元素中提取点击数
/// 从 linkCounts 数据中通过 URL 匹配查找
String? extractClickCountFromOnebox(
  dynamic element, {
  List<LinkCount>? linkCounts,
}) {
  if (element == null || linkCounts == null) return null;

  // 提取 onebox 的 URL
  final url = extractUrl(element);
  if (url.isEmpty) return null;

  // 从 linkCounts 数据中通过 URL 匹配查找
  for (final lc in linkCounts) {
    if (lc.clicks > 0 && _urlMatches(lc.url, url)) {
      return _formatClickCount(lc.clicks);
    }
  }

  return null;
}

/// URL 匹配（忽略末尾斜杠和协议差异）
bool _urlMatches(String url1, String url2) {
  final normalized1 = url1
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceFirst(RegExp(r'/$'), '');
  final normalized2 = url2
      .replaceFirst(RegExp(r'^https?://'), '')
      .replaceFirst(RegExp(r'/$'), '');
  return normalized1 == normalized2;
}

/// 格式化点击数 (如: 1234 -> 1.2k)
String _formatClickCount(int count) {
  if (count >= 1000) {
    return '${(count / 1000).toStringAsFixed(1)}k';
  }
  return count.toString();
}

/// 从元素中提取 URL
String extractUrl(dynamic element) {
  // 尝试从 data-onebox-src 获取
  final dataSource = element.attributes['data-onebox-src'];
  if (dataSource != null && dataSource.isNotEmpty) {
    return dataSource;
  }

  // 尝试从 header 链接获取
  final headerLink = element.querySelector('header a');
  if (headerLink != null) {
    return headerLink.attributes['href'] ?? '';
  }

  // 尝试从 h3 链接获取
  final h3Link = element.querySelector('h3 a');
  if (h3Link != null) {
    return h3Link.attributes['href'] ?? '';
  }

  // 尝试从任意 a 标签获取
  final anyLink = element.querySelector('a');
  if (anyLink != null) {
    return anyLink.attributes['href'] ?? '';
  }

  return '';
}
