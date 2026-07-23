import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../models/emoji.dart';
import '../../utils/platform_utils.dart';
import 'emoji_picker.dart';
import 'sticker_picker.dart';
import '../../../../../l10n/s.dart';

/// 悬浮 Tab 的高度（含上下内边距），用于给内容区预留底部空间
const double floatingTabHeight = 48;

/// 紧凑模式(桌面悬浮弹层)的悬浮 Tab 预留高度
const double floatingTabHeightCompact = 40;

/// 表情/表情包面板容器
///
/// 通过底部悬浮 Tab 或左右滑动切换"内置表情"和"表情包"两种模式。
/// 使用 Stack 布局，内容区在底层，悬浮 Tab 在顶层。
class EmojiStickerPanel extends StatefulWidget {
  /// 选中内置表情的回调
  final ValueChanged<Emoji> onEmojiSelected;

  /// 选中表情包的回调，参数为 Markdown 图片文本
  final ValueChanged<String> onStickerSelected;

  /// 退格回调(移动端表情键盘标配:面板打开时软键盘收起,没有它
  /// 就只能切回键盘删)。null 或桌面端不显示退格键(桌面端焦点常驻
  /// 输入框,物理退格直接可用)。
  final VoidCallback? onBackspace;

  /// 搜索用内联视图(桌面悬浮弹层场景:bottomSheet 会被压在
  /// OverlayEntry 弹层下面,且交互割裂),false 走 bottomSheet。
  final bool inlineSearch;

  /// 紧凑模式(桌面悬浮弹层):切换胶囊/间距按小窗比例收紧,
  /// 圆角背景交给弹层壳,面板自身不再画顶部圆角。
  final bool compact;

  /// 请求宿主收起面板(桌面悬浮弹层:面板内要弹 Navigator 层的 sheet
  /// 时先收弹层,否则 sheet 被 root overlay 的弹层压住)
  final VoidCallback? onDismissRequested;

  const EmojiStickerPanel({
    super.key,
    required this.onEmojiSelected,
    required this.onStickerSelected,
    this.onBackspace,
    this.inlineSearch = false,
    this.compact = false,
    this.onDismissRequested,
  });

  @override
  State<EmojiStickerPanel> createState() => _EmojiStickerPanelState();
}

class _EmojiStickerPanelState extends State<EmojiStickerPanel> {
  late final PageController _pageController;
  int _currentPage = 0;

  /// 悬浮 Tab 是否可见
  bool _tabVisible = true;

  /// 滚动累积量，正值=向下滚动，负值=向上滚动
  double _scrollDelta = 0;

  /// 两个 picker 页面的实例缓存。
  ///
  /// 悬浮 Tab 显隐(滚动阈值触发)和翻页都会 setState ——
  /// 如果每次 build 都 new EmojiPicker/StickerPicker,这些 setState 会让
  /// PageView 子树整体 rebuild,grid 里几百个 cell 在滚动中途一帧内全部
  /// 重建,体感就是"滚一段卡一下"。缓存实例后 updateChild 直接跳过子树。
  List<Widget>? _pages;
  double? _pagesBottomPadding;

  List<Widget> _buildPages(double bottomPadding) {
    if (_pages == null || _pagesBottomPadding != bottomPadding) {
      _pagesBottomPadding = bottomPadding;
      _pages = [
        EmojiPicker(
          onEmojiSelected: widget.onEmojiSelected,
          bottomPadding: bottomPadding,
          inlineSearch: widget.inlineSearch,
          compact: widget.compact,
        ),
        StickerPicker(
          onStickerSelected: widget.onStickerSelected,
          bottomPadding: bottomPadding,
          compact: widget.compact,
          onDismissRequested: widget.onDismissRequested,
        ),
      ];
    }
    return _pages!;
  }

  @override
  void didUpdateWidget(EmojiStickerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 回调变了必须重建缓存页,否则点选回调指向旧闭包
    if (widget.onEmojiSelected != oldWidget.onEmojiSelected ||
        widget.onStickerSelected != oldWidget.onStickerSelected) {
      _pages = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onScrollUpdate(ScrollUpdateNotification notification) {
    // 只响应垂直滚动，忽略 PageView 的水平翻页
    if (notification.metrics.axis != Axis.vertical) return;

    final delta = notification.scrollDelta ?? 0;
    if (delta == 0) return;

    // 方向反转时重置累积值
    if ((_scrollDelta > 0 && delta < 0) || (_scrollDelta < 0 && delta > 0)) {
      _scrollDelta = 0;
    }

    _scrollDelta += delta;

    // 向下累积 80px 隐藏
    if (_scrollDelta > 80 && _tabVisible) {
      setState(() => _tabVisible = false);
      _scrollDelta = 0;
    }
    // 向上累积 40px 显示
    else if (_scrollDelta < -40 && !_tabVisible) {
      setState(() => _tabVisible = true);
      _scrollDelta = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    final tabHeight =
        widget.compact ? floatingTabHeightCompact : floatingTabHeight;
    final totalBottomPadding = tabHeight + safeBottom;

    return Stack(
      children: [
        // 内容区：NotificationListener 只处理垂直滚动
        NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) {
            _onScrollUpdate(notification);
            return false;
          },
          child: PageView(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _currentPage = index;
                _tabVisible = true;
                _scrollDelta = 0;
              });
            },
            children: _buildPages(totalBottomPadding),
          ),
        ),

        // 悬浮切换 Tab(紧凑模式桌面无安全区,补 6px 底距不贴边)
        Positioned(
          left: 0,
          right: 0,
          bottom: widget.compact ? safeBottom + 6 : safeBottom,
          child: Center(
            child: AnimatedSlide(
              offset: _tabVisible ? Offset.zero : const Offset(0, 2),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: _buildFloatingTab(context),
            ),
          ),
        ),

        // 悬浮退格键(仅移动端,与 Tab 同层同显隐节奏,靠右)
        if (widget.onBackspace != null && PlatformUtils.isMobile)
          Positioned(
            right: 12,
            bottom: safeBottom + 4,
            child: AnimatedSlide(
              offset: _tabVisible ? Offset.zero : const Offset(0, 2),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: Material(
                color: theme.colorScheme.surface.withValues(alpha: 0.95),
                shape: const CircleBorder(),
                elevation: 2,
                shadowColor: Colors.black.withValues(alpha: 0.1),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: widget.onBackspace,
                  child: SizedBox(
                    width: 42,
                    height: 42,
                    child: Center(
                      // backspace 字形视觉重心偏右(左侧是箭头尖),
                      // 几何居中后看着偏右,向左 1px 光学补偿。
                      child: Transform.translate(
                        offset: const Offset(-1, 0),
                        child: Icon(
                          Symbols.backspace_rounded,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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

  Widget _buildFloatingTab(BuildContext context) {
    final theme = Theme.of(context);
    final compact = widget.compact;
    final buttonWidth = compact ? 76.0 : 90.0;
    const gap = 4.0;

    return Container(
      padding: EdgeInsets.all(compact ? 3 : 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(24),
        // 紧凑模式在弹层里,弹层自带边框阴影,胶囊影收轻 + 加细边
        border: compact
            ? Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              )
            : null,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: compact ? 0.06 : 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: AnimatedBuilder(
        animation: _pageController,
        builder: (context, _) {
          final page = _pageController.hasClients
              ? (_pageController.page ?? _currentPage.toDouble())
              : _currentPage.toDouble();

          return SizedBox(
            height: compact ? 30 : 34,
            child: Stack(
              children: [
                // 滑动指示器
                Positioned(
                  left: page * (buttonWidth + gap),
                  top: 0,
                  bottom: 0,
                  width: buttonWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.7,
                      ),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                // 按钮
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTabLabel(
                      theme: theme,
                      icon: AppIcons.smileyOutline,
                      label: S.current.emoji_tab,
                      selected: _currentPage == 0,
                      width: buttonWidth,
                      onTap: () => _pageController.animateToPage(
                        0,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      ),
                    ),
                    const SizedBox(width: gap),
                    _buildTabLabel(
                      theme: theme,
                      icon: AppIcons.stickerOutline,
                      label: S.current.sticker_tab,
                      selected: _currentPage == 1,
                      width: buttonWidth,
                      onTap: () => _pageController.animateToPage(
                        1,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTabLabel({
    required ThemeData theme,
    required Object icon,
    required String label,
    required bool selected,
    required double width,
    required VoidCallback onTap,
  }) {
    final compact = widget.compact;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                icon,
                size: compact ? 16 : 18,
                fill: selected ? 1 : 0,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              SizedBox(width: compact ? 5 : 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: compact ? 12 : 13,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.normal,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
