import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../l10n/s.dart';
import '../../utils/dialog_utils.dart';

/// 大屏「页面弹窗」:把整页内容装进居中弹窗,内部自带独立 Navigator,
/// 页内跳转(话题内链、点头像进个人页等)在弹窗内前进后退,像一扇
/// 迷你窗口。通知等外部入口在大屏的统一落点 —— 不进工作区栈、不切
/// tab,看完即走,不打断底下工作区正在进行的浏览。
///
/// 关闭途径:面板右上外侧 ✕ / 点遮罩 / Esc / Android 返回键(返回键
/// 先退弹窗内导航,退到根再关弹窗,由 NavigatorPopHandler 保证)。
///
/// 页面内 showDialog/showModalBottomSheet 默认走 root navigator,仍是
/// 全屏级弹层,不受嵌套 Navigator 影响。
Future<T?> showPageDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showAppGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: S.current.common_close,
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return PageDialogScaffold(builder: builder, fullscreenBuilder: builder);
    },
  );
}

/// 页面弹窗的外壳:顶部操作行(✕ + 调用方追加的 [topBar])+ 嵌套导航
/// 面板。需要在弹窗内切换内容的调用方(如通知的上一条/下一条)自行
/// showAppGeneralDialog 并直接使用本外壳,通过改变 [contentKey] 让嵌套
/// Navigator 整体重建 —— 上一条通知里点开的内链子页不应残留到下一条。
class PageDialogScaffold extends StatefulWidget {
  const PageDialogScaffold({
    super.key,
    required this.builder,
    this.topBar = const [],
    this.contentKey,
    this.sidebar,
    this.sidebarWidth = 332,
    this.overlay,
    this.fullscreenBuilder,
  });

  final WidgetBuilder builder;

  /// 追加在 ✕ 左侧的操作(如上一条/下一条),与 ✕ 同一行
  final List<Widget> topBar;

  /// 非 null 时顶部操作行出现「全屏打开」按钮:关掉弹窗,改以全屏
  /// 路由在根导航打开该页面 —— 把选择权交给想沉浸阅读的用户。翻页类
  /// 调用方传当前条目的落点页;弹窗内已产生的内链子页不随迁。
  final WidgetBuilder? fullscreenBuilder;

  /// 内容身份。变化时嵌套 Navigator 连同其路由栈整体重建
  final Key? contentKey;

  /// 常驻左侧栏(如通知列表)。非 null 时面板加宽,内容区在右
  final Widget? sidebar;
  final double sidebarWidth;

  /// 盖在内容区上方的覆盖层(如窄弹窗模式下滑出的列表抽屉);
  /// null = 无覆盖。始终参与布局便于调用方做出入场动画
  final Widget? overlay;

  @override
  State<PageDialogScaffold> createState() => _PageDialogScaffoldState();
}

class _PageDialogScaffoldState extends State<PageDialogScaffold> {
  GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  void didUpdateWidget(covariant PageDialogScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contentKey != widget.contentKey) {
      // 换 GlobalKey 强制旧 Navigator 子树销毁重建(路由栈清零)
      _navKey = GlobalKey<NavigatorState>();
    }
  }

  /// 全屏打开:先关弹窗,再把同一页面推成根导航的全屏路由。顺序不能
  /// 反 —— 先 push 会让 pop 关掉的是刚推上去的全屏页
  void _openFullscreen() {
    final builder = widget.fullscreenBuilder!;
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.pop();
    navigator.push(MaterialPageRoute(builder: builder));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    // 正文自身有 maxContentWidth(800)约束,面板略宽留出呼吸感;带侧栏
    // 时整体加宽,内容区保持原宽。高度含顶部操作行,面板本体在
    // Flexible 内吃剩余空间
    final width = math.min(
      screen.width - 96.0,
      widget.sidebar != null ? 880.0 + widget.sidebarWidth : 880.0,
    );
    final maxHeight = math.min(screen.height * 0.92, 1040.0);

    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 操作行悬在面板外右上:弹窗内是带自己 AppBar 的完整页面,
              // 叠进去会与页面的 actions 抢位,放外侧对任意页面都成立
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...widget.topBar,
                  if (widget.fullscreenBuilder != null)
                    _PageDialogTopButton(
                      tooltip: context.l10n.common_fullscreenOpen,
                      icon: Symbols.open_in_full_rounded,
                      onPressed: _openFullscreen,
                    ),
                  _PageDialogTopButton(
                    tooltip: context.l10n.common_close,
                    icon: Symbols.close_rounded,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Material(
                  color: theme.colorScheme.surface,
                  clipBehavior: Clip.antiAlias,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(28),
                  child: _buildPanelBody(theme),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on _PageDialogScaffoldState {
  Widget _buildPanelBody(ThemeData theme) {
    Widget content = KeyedSubtree(
      key: widget.contentKey,
      child: NavigatorPopHandler(
        onPopWithResult: (_) => _navKey.currentState?.maybePop(),
        child: Navigator(
          key: _navKey,
          onGenerateInitialRoutes: (nav, initialRoute) => [
            MaterialPageRoute(builder: widget.builder),
          ],
        ),
      ),
    );
    if (widget.overlay != null) {
      content = Stack(children: [content, widget.overlay!]);
    }
    final sidebar = widget.sidebar;
    if (sidebar == null) return content;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: widget.sidebarWidth, child: sidebar),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
        Expanded(child: content),
      ],
    );
  }
}

/// 顶部操作行的圆形按钮(✕/上一条/下一条共用同一观感)
class _PageDialogTopButton extends StatelessWidget {
  const _PageDialogTopButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: IconButton(
          tooltip: tooltip,
          icon: Icon(
            icon,
            color: onPressed == null
                ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38)
                : theme.colorScheme.onSurfaceVariant,
          ),
          onPressed: onPressed,
        ),
      ),
    );
  }
}

/// 供调用方以统一观感往 [PageDialogScaffold.topBar] 里放按钮
Widget pageDialogTopButton({
  required String tooltip,
  required IconData icon,
  required VoidCallback? onPressed,
}) {
  return _PageDialogTopButton(
    tooltip: tooltip,
    icon: icon,
    onPressed: onPressed,
  );
}
