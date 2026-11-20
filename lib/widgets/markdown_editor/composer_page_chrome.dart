import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../theme/theme_style.dart';
import '../../utils/platform_utils.dart';
import 'composer_block_hover.dart';
import 'composer_chrome.dart';

/// 文档操作的统一图标规格。
class ComposerActionButton extends StatelessWidget {
  const ComposerActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.busy = false,
    this.color,
  });
  final Object icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final Color? color;

  static ButtonStyle get buttonStyle => IconButton.styleFrom(
    minimumSize: const Size(44, 44),
    maximumSize: const Size(44, 44),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    color: color,
    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    padding: const EdgeInsets.all(10),
    style: buttonStyle,
    icon: busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : AppIcon(icon, size: 21),
  );
}

/// 顶栏胶囊：顶栏只有渐隐遮罩、没有实底，返回键、标题和操作落在实色胶囊
/// 上，内容从下面滚过时仍然清楚。内容滚到顶栏下面时胶囊再浮起（加阴影），
/// 阴影跟随主题的阴影开关，关闭时改用发丝描边勾出轮廓。
///
/// 布局见 [ComposerPageGrid]：返回键、标题、「操作 + 提交」各一块胶囊，
/// 桌面端的分类 / 标签另成一块。
class ComposerBarCapsule extends StatelessWidget {
  const ComposerBarCapsule({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.height = defaultHeight,
  });

  /// 与提交键的触控外框同高，胶囊内的 44px 图标按钮上下各留 2px
  static const double defaultHeight = 48;

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scrolledUnder = ComposerChromeScope.scrolledUnderOf(context);
    if (scrolledUnder == null) return _build(context, 1);
    final animate =
        !(MediaQuery.disableAnimationsOf(context) ||
            MediaQuery.reduceMotionOf(context));
    return ValueListenableBuilder<bool>(
      valueListenable: scrolledUnder,
      builder: (context, under, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: under ? 1 : 0),
        duration: animate ? const Duration(milliseconds: 180) : Duration.zero,
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => _build(context, t),
      ),
    );
  }

  /// [t]：0 静止、1 浮起（只影响阴影 / 描边，底色始终保留）
  Widget _build(BuildContext context, double t) {
    final colors = Theme.of(context).colorScheme;
    final shadows = context.themeStyle.shadows;
    return Material(
      color: colors.surfaceContainerHigh,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(9999),
        side: shadows
            ? BorderSide.none
            : BorderSide(color: colors.outlineVariant.withValues(alpha: t)),
      ),
      clipBehavior: Clip.antiAlias,
      elevation: shadows ? 2 * t : 0,
      shadowColor: Colors.black26,
      animationDuration: Duration.zero,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: padding,
          child: Center(widthFactor: 1, child: child),
        ),
      ),
    );
  }
}

/// 编辑页的布局网格，顶栏与正文共用：
///
/// - 宽屏（≥ [expandedWidth]）：顶栏横跨全宽、两侧边距 24，分类 / 标签内联在
///   标题后；正文居中到阅读栏，不与顶栏对齐；
/// - 窄屏桌面：正文左侧是把手栏（[ComposerReadingGutter.pageGutter]），返回键
///   与正文的块把手同在这一栏，标题、分类 / 标签与正文共用把手栏右侧这条边；
/// - 窄屏手机：标准页边距 16，返回键与正文同一条左边，标题跟在返回键后。
class ComposerPageGrid {
  const ComposerPageGrid._({
    required this.expanded,
    required this.hasBack,
    required this.backStart,
    required this.titleStart,
    required this.contentStart,
    required this.end,
  });

  factory ComposerPageGrid.of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final hasBack = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
    double after(double start) => hasBack ? start + _backSize + _gap : start;
    if (width >= expandedWidth) {
      return ComposerPageGrid._(
        expanded: true,
        hasBack: hasBack,
        backStart: _expandedMargin,
        titleStart: after(_expandedMargin),
        contentStart: _expandedMargin,
        end: _expandedMargin,
      );
    }
    if (PlatformUtils.isDesktop) {
      final gutter = ComposerReadingGutter.pageGutter(width);
      return ComposerPageGrid._(
        expanded: false,
        hasBack: hasBack,
        backStart: (gutter - _backSize) / 2,
        titleStart: gutter,
        contentStart: gutter,
        end: _compactMargin,
      );
    }
    return ComposerPageGrid._(
      expanded: false,
      hasBack: hasBack,
      backStart: _compactMargin,
      titleStart: after(_compactMargin),
      contentStart: _compactMargin,
      end: _compactMargin,
    );
  }

  static const double expandedWidth = ComposerBlockHover.expandedControlWidth;
  static const double _compactMargin = 16;
  static const double _expandedMargin = 24;
  static const double _backSize = ComposerBarCapsule.defaultHeight;
  static const double _gap = 8;

  /// 宽屏：分类 / 标签内联进顶栏，不再单占一行
  final bool expanded;
  final bool hasBack;

  /// 返回键胶囊左缘
  final double backStart;

  /// 标题胶囊左缘
  final double titleStart;

  /// 顶栏第二行（窄屏桌面的分类 / 标签）左缘
  final double contentStart;

  /// 顶栏右边距
  final double end;

  /// AppBar 的 leading / leadingWidth / titleSpacing：返回键放进 leading 并
  /// 按网格定位，标题紧接在 leading 之后
  Widget? get leading => hasBack
      ? Padding(
          padding: EdgeInsetsDirectional.only(start: backStart),
          child: const Align(
            alignment: AlignmentDirectional.centerStart,
            child: ComposerBarBack(),
          ),
        )
      : null;
  double? get leadingWidth => hasBack ? titleStart : null;
  double get titleSpacing => hasBack ? 0 : titleStart;
}

/// 顶栏的返回 / 关闭键，单独一块圆形胶囊。关闭键与 AppBar 自动推导的规则
/// 一致（全屏弹出的页面用关闭）。
class ComposerBarBack extends StatelessWidget {
  const ComposerBarBack({super.key});

  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final close = route is PageRoute && route.fullscreenDialog;
    return ComposerBarCapsule(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: close
          ? CloseButton(style: ComposerActionButton.buttonStyle)
          : BackButton(style: ComposerActionButton.buttonStyle),
    );
  }
}

/// 顶栏的页面标题胶囊。可点的标题（[ComposerTopicKindPicker]）自己铺满
/// 胶囊并带上 [padding]，悬停 / 水波纹才是整块；纯文字标题由胶囊留白
class ComposerBarTitle extends StatelessWidget {
  const ComposerBarTitle({super.key, required this.child});

  static const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 16);

  final Widget child;

  @override
  Widget build(BuildContext context) => ComposerBarCapsule(
    padding: child is ComposerTopicKindPicker ? EdgeInsets.zero : padding,
    child: child,
  );
}

/// 可切换的创建页标题，继承 AppBar 的标题样式。
class ComposerTopicKindPicker extends StatelessWidget {
  const ComposerTopicKindPicker({
    super.key,
    required this.question,
    required this.onChanged,
    this.enabled = true,
    this.locked = false,
  });
  final bool question;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = question
        ? S.current.composer_kindQuestion
        : S.current.composer_kindTopic;
    return SwipeDismissiblePopupMenuButton<bool>(
      enabled: enabled && !locked,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      padding: EdgeInsets.zero,
      borderRadius: context.shapes.borderRadius(8),
      tooltip: '',
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 220),
      color: colors.surfaceContainer,
      elevation: 3,
      shadowColor: colors.shadow.withValues(alpha: .24),
      surfaceTintColor: Colors.transparent,
      shape: RoundedSuperellipseBorder(
        borderRadius: context.shapes.borderRadius(12),
        side: BorderSide(
          color: colors.outlineVariant.withValues(alpha: .45),
          width: .6,
        ),
      ),
      // 不传 initialValue：Flutter 会用它将选中行居中到触发点，从而覆盖入口。
      // 当前项的勾选标识由菜单内容自行绘制。
      onSelected: (value) {
        if (value != question) onChanged(value);
      },
      itemBuilder: (_) => [
        for (final value in [false, true])
          PopupMenuItem<bool>(
            key: ValueKey('composer-kind-option-$value'),
            value: value,
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value
                        ? S.current.composer_kindQuestion
                        : S.current.composer_kindTopic,
                  ),
                ),
                if (value == question)
                  Icon(
                    Symbols.check_rounded,
                    size: 18,
                    color: context.emphasis.selected,
                  ),
              ],
            ),
          ),
      ],
      // 触发区铺满整块标题胶囊（左右留白也在点按 / 悬停范围内）
      child: Container(
        key: const ValueKey('composer-kind-trigger'),
        height: ComposerBarCapsule.defaultHeight,
        padding: ComposerBarTitle.padding,
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          // 箭头参与标题的自然省略，窄屏优先保留标题文字。
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: label),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      locked
                          ? Symbols.lock_rounded
                          : Symbols.expand_more_rounded,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            key: const ValueKey('composer-title-label'),
            semanticsLabel: label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
