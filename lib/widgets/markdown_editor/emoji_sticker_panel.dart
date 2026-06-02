import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../models/emoji.dart';
import 'emoji_picker.dart';
import 'sticker_picker.dart';
import '../../../../../l10n/s.dart';

/// 悬浮 Tab 的高度（含上下内边距），用于给内容区预留底部空间
const double floatingTabHeight = 48;

/// 表情/表情包面板容器
///
/// 通过底部悬浮 Tab 或左右滑动切换"内置表情"和"表情包"两种模式。
/// 使用 Stack 布局，内容区在底层，悬浮 Tab 在顶层。
class EmojiStickerPanel extends StatefulWidget {
  /// 选中内置表情的回调
  final ValueChanged<Emoji> onEmojiSelected;

  /// 选中表情包的回调，参数为 Markdown 图片文本
  final ValueChanged<String> onStickerSelected;

  const EmojiStickerPanel({
    super.key,
    required this.onEmojiSelected,
    required this.onStickerSelected,
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
    final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
    final totalBottomPadding = floatingTabHeight + safeBottom;

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
            children: [
              EmojiPicker(
                onEmojiSelected: widget.onEmojiSelected,
                bottomPadding: totalBottomPadding,
              ),
              StickerPicker(
                onStickerSelected: widget.onStickerSelected,
                bottomPadding: totalBottomPadding,
              ),
            ],
          ),
        ),

        // 悬浮切换 Tab
        Positioned(
          left: 0,
          right: 0,
          bottom: safeBottom,
          child: Center(
            child: AnimatedSlide(
              offset: _tabVisible ? Offset.zero : const Offset(0, 2),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: _buildFloatingTab(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFloatingTab(BuildContext context) {
    final theme = Theme.of(context);
    const buttonWidth = 90.0;
    const gap = 4.0;

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
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
            height: 34,
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
                      icon: _currentPage == 0
                          ? PhosphorIcons.smileyBlank(PhosphorIconsStyle.fill)
                          : PhosphorIcons.smileyBlank(PhosphorIconsStyle.bold),
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
                      icon: _currentPage == 1
                          ? PhosphorIcons.smileyMelting(PhosphorIconsStyle.fill)
                          : PhosphorIcons.smileyMelting(PhosphorIconsStyle.bold),
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
    required IconData icon,
    required String label,
    required bool selected,
    required double width,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
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
