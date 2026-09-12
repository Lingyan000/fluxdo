import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

/// 网格与迁移层共用同一图标框；宽字形按自然宽度居中，不被方框压缩。
class ComposerToolGlyph extends StatelessWidget {
  const ComposerToolGlyph({super.key, required this.icon});
  static const extent = 20.0;
  final Widget icon;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: extent,
    child: OverflowBox(
      minWidth: 0,
      maxWidth: double.infinity,
      minHeight: 0,
      maxHeight: extent,
      alignment: Alignment.center,
      child: icon,
    ),
  );
}

/// 网格单元格内容：圆角图标块 + 文字标签（自定义模式下带外显角标）
///
/// 公开供富文本工具面板复用 —— 两种模式的面板必须长得一模一样，
/// 否则用户切模式会以为进了别的功能。
class ToolCellBody extends StatelessWidget {
  static const iconExtent = 52.0;

  final Widget icon;
  final String label;
  final bool pinned;
  final bool showPinBadge;

  const ToolCellBody({
    super.key,
    required this.icon,
    required this.label,
    this.pinned = false,
    this.showPinBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlight = pinned;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: iconExtent,
              height: iconExtent,
              decoration: BoxDecoration(
                color: highlight
                    ? theme.colorScheme.primaryContainer
                    : theme.colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.6,
                      ),
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              // 通过 IconTheme 统一图标尺寸和颜色（兼容 FaIcon 和 Icon）
              child: IconTheme.merge(
                data: IconThemeData(
                  size: 20,
                  color: highlight
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
                child: icon,
              ),
            ),
            // 自定义模式角标：已外显 ✓ / 未外显 ＋
            if (showPinBadge)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: pinned
                        ? theme.colorScheme.primary
                        : theme.colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(
                      BorderSide(color: theme.colorScheme.surface, width: 1.5),
                    ),
                  ),
                  child: Icon(
                    pinned ? Symbols.check_rounded : Symbols.add_rounded,
                    size: 12,
                    color: pinned
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 普通工具单元格（点击直接执行）
/// 普通工具格子（公开供富文本面板复用）
class ToolCell extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool pinned;
  final bool showPinBadge;

  const ToolCell({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.pinned = false,
    this.showPinBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onLongPress,
        child: ToolCellBody(
          icon: icon,
          label: label,
          pinned: pinned,
          showPinBadge: showPinBadge,
        ),
      ),
    );
  }
}
