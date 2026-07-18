import 'package:flutter/material.dart';
import '../../models/category.dart';
import '../../models/topic.dart';
import '../../utils/responsive.dart';
import 'painted_topic_card.dart';
import 'topic_card.dart';
import 'topic_card_layout.dart';
import 'topic_preview_dialog.dart';

/// 话题卡自绘路径总开关:false 一键回退 widget 版 TopicCard
/// (验收期保险丝;稳定后与 widget 分支一并清理)
const bool kUsePaintedTopicCard = true;

/// 话题卡片渲染公共函数
///
/// 处理 pinned/normal 卡片选择、自绘/widget 路由、长按预览、响应式
/// 宽度包装。普通/私信话题卡默认走自绘(单渲染对象,挂载帧纯绘制,
/// 见 [TopicCardLayout]);带自定义 topWidget/middleWidget 的调用方
/// (书签有专用自绘接线)与置顶卡走 widget 版。
Widget buildTopicItem({
  required BuildContext context,
  required Topic topic,
  required bool isSelected,
  required VoidCallback onTap,
  VoidCallback? onMiddleClick,
  required bool enableLongPress,
  Color? highlightColor,
  Widget? topWidget,
  Widget? middleWidget,
  bool messageStyle = false,
  Map<int, Category>? categoryMap,
  double? statsAvailableWidth,
  List<PreviewAction>? previewActions,
  WidgetBuilder? previewCustomActionPanelBuilder,
}) {
  Widget child;

  VoidCallback? longPress() => enableLongPress
      ? () => TopicPreviewDialog.show(
          context,
          topic: topic,
          onOpen: onTap,
          actions: previewActions,
          customActionPanelBuilder: previewCustomActionPanelBuilder,
        )
      : null;

  final isMobile = Responsive.isMobile(context);

  if (topic.pinned) {
    child = CompactTopicCard(
      topic: topic,
      onTap: onTap,
      onMiddleClick: onMiddleClick,
      onLongPress: longPress(),
      isSelected: isSelected,
      highlightColor: highlightColor,
      categoryMap: categoryMap,
    );
  } else if (kUsePaintedTopicCard && topWidget == null && middleWidget == null) {
    // 自绘路径:排版全局缓存 + 单渲染对象。宽度 = 视口(或桌面列宽
    // 上限)- 页边距 24;分类表由调用方传入(未传时不查,分类行缺分
    // 类名 —— 各列表页均已传)
    final viewportWidth = MediaQuery.sizeOf(context).width - 24;
    final cardWidth = isMobile
        ? viewportWidth
        : (viewportWidth > Breakpoints.maxContentWidth
            ? Breakpoints.maxContentWidth
            : viewportWidth);
    final categoryId = int.tryParse(topic.categoryId);
    final layout = TopicCardLayout.obtain(
      identity: 'topic:${topic.id}',
      topic: topic,
      width: cardWidth,
      theme: Theme.of(context),
      category: categoryMap?[categoryId],
      emojiUrlOf: topicCardEmojiUrlResolver,
      statsAvailableWidth: statsAvailableWidth ?? (cardWidth - 64),
      messageStyle: messageStyle,
    );
    child = PaintedTopicCard(
      layout: layout,
      onTap: onTap,
      onMiddleClick: onMiddleClick,
      onLongPress: longPress(),
      isSelected: isSelected,
      highlightColor: highlightColor,
    );
  } else {
    child = TopicCard(
      topic: topic,
      onTap: onTap,
      onMiddleClick: onMiddleClick,
      onLongPress: longPress(),
      isSelected: isSelected,
      highlightColor: highlightColor,
      topWidget: topWidget,
      middleWidget: middleWidget,
      messageStyle: messageStyle,
      categoryMap: categoryMap,
      statsAvailableWidth: statsAvailableWidth,
    );
  }

  if (!isMobile) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: Breakpoints.maxContentWidth,
        ),
        child: child,
      ),
    );
  }
  return child;
}
