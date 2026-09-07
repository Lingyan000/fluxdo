import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

// 统一底部弹框外壳常量
const double _kSheetCornerRadius = 20.0;
const double _kHandleWidth = 32.0;
const double _kHandleHeight = 4.0;

/// 底部弹框的两种受控形态。
enum AppSheetStyle {
  /// 贴边列表式:贴屏幕左右下边、顶部圆角,默认带拖拽条、可下滑关闭。
  /// 适合浏览 / 选择 / 列表 / 快速输入。
  edge,

  /// 表单卡片式:同样贴边、仅顶部圆角,但默认无拖拽条、带关闭按钮,
  /// 并由弹出入口(AppBottomSheet.show)禁止下滑关闭,避免误关丢失输入。
  /// 适合表单 / 编辑 / 确认。
  card,
}

/// 统一的底部弹框外壳。
///
/// 提供两种受控形态(见 [AppSheetStyle]):贴边列表式与浮岛卡片式。
/// 统一负责拖拽条、可选标题栏、键盘顶起与高度策略,各 Sheet 只需把
/// 「内容」作为 [child] 传入,不再各自手写外壳。
///
/// 纯外壳 widget,零业务依赖(只依赖 Flutter material),因此放在 common_ui
/// 供主 app 与各子包共用。主 app 的弹出入口 `AppBottomSheet.show /
/// showDraggable`(带背景模糊与快捷键)会自动包裹本组件;子包可在自己的
/// `showModalBottomSheet`/封装中直接把本组件作为 builder 返回。
class AppSheetScaffold extends StatelessWidget {
  const AppSheetScaffold({
    super.key,
    this.style = AppSheetStyle.edge,
    this.title,
    this.titleWidget,
    this.actions = const [],
    this.showCloseButton = true,
    this.showDragHandle,
    this.showTitleDivider = false,
    this.contentPadding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
    this.maxHeightFactor = 0.9,
    this.expandToFill = false,
    this.footer,
    required this.child,
  });

  /// 外壳形态:贴边列表式或浮岛卡片式
  final AppSheetStyle style;

  /// 标题文字(为空且无 [titleWidget] 时不显示标题栏)
  final String? title;

  /// 自定义标题(优先于 [title])
  final Widget? titleWidget;

  /// 标题栏右侧操作按钮(位于关闭按钮左侧)
  final List<Widget> actions;

  /// 是否显示右上角关闭按钮(仅在有标题栏时生效)
  final bool showCloseButton;

  /// 是否显示顶部拖拽条;为 null 时按 [style] 默认(贴边式显示、卡片式隐藏)
  final bool? showDragHandle;

  /// 是否在标题栏下方显示分隔线
  final bool showTitleDivider;

  /// 内容内边距
  final EdgeInsetsGeometry contentPadding;

  /// 普通模式下高度上限(占屏比);[expandToFill] 为 true 时忽略
  final double maxHeightFactor;

  /// 是否撑满给定高度。用于 [DraggableScrollableSheet] 等已经定高的场景:
  /// 此时内容用 [Expanded] 撑满,且不再叠加键盘内边距(交由内容自身处理)。
  final bool expandToFill;

  /// 固定在内容下方、不随内容滚动的底部区域(如确认/提交按钮)。
  /// 位于内容滚动区之外,自带内边距,处于底部安全区内。
  final Widget? footer;

  /// 内容
  final Widget child;

  bool get _hasTitle => title != null || titleWidget != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isCard = style == AppSheetStyle.card;
    // 拖拽条默认:贴边式显示、卡片式隐藏;显式指定则以指定为准。
    final resolvedShowHandle = showDragHandle ?? !isCard;

    final content = expandToFill
        ? Expanded(
            child: Padding(padding: contentPadding, child: child),
          )
        : Flexible(
            child: Padding(padding: contentPadding, child: child),
          );

    // 用 Material(而非 Container)作外壳:Material 自带 ink 层,内部 ListTile/
    // InkWell 的水波纹与长按高亮才能画在背景之上、正常显示;Container 不提供
    // ink 层会导致点击反馈被不透明背景遮挡。
    final shell = Material(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(_kSheetCornerRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: expandToFill ? MainAxisSize.max : MainAxisSize.min,
          children: [
            if (resolvedShowHandle) _buildDragHandle(cs),
            if (_hasTitle) _buildTitleBar(context, theme, resolvedShowHandle),
            if (_hasTitle && showTitleDivider)
              const Divider(height: 1, indent: 16, endIndent: 16),
            content,
            // Column 默认按内容宽度居中,footer 里的按钮会缩成一小段;
            // 这里给它 tight 宽约束,让 footer 自己决定要不要占满。
            if (footer != null) SizedBox(width: double.infinity, child: footer),
          ],
        ),
      ),
    );

    // 可拖拽模式:高度由 DraggableScrollableSheet 决定,不封顶、不叠加键盘内边距。
    if (expandToFill) return shell;

    // 两种形态均贴边:底部贴屏幕底,仅顶部圆角,从根本上避开「卡片底部圆角
    // 与屏幕曲率不匹配」的问题;键盘弹出时整体上顶(需配合 isScrollControlled)。
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * maxHeightFactor,
        ),
        child: shell,
      ),
    );
  }

  Widget _buildDragHandle(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          width: _kHandleWidth,
          height: _kHandleHeight,
          decoration: BoxDecoration(
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(_kHandleHeight / 2),
          ),
        ),
      ),
    );
  }

  Widget _buildTitleBar(BuildContext context, ThemeData theme, bool hasHandle) {
    return Padding(
      // 有拖拽条时顶部间距已由拖拽条提供
      padding: EdgeInsets.fromLTRB(16, hasHandle ? 0 : 12, 8, 8),
      child: Row(
        children: [
          Expanded(
            child:
                titleWidget ??
                Text(
                  title!,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
          ),
          ...actions,
          if (showCloseButton)
            IconButton(
              icon: const Icon(Symbols.close_rounded),
              visualDensity: VisualDensity.compact,
              tooltip: MaterialLocalizations.of(
                context,
              ).modalBarrierDismissLabel,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
        ],
      ),
    );
  }
}
