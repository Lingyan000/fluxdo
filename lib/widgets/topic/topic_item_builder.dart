import 'package:flutter/material.dart';
import '../../models/topic.dart';
import '../../utils/responsive.dart';
import 'topic_card.dart';
import 'topic_preview_dialog.dart';

/// 话题卡片渲染公共函数
///
/// 处理 pinned/normal 卡片选择、长按预览、响应式宽度包装。
Widget buildTopicItem({
  required BuildContext context,
  required Topic topic,
  required bool isSelected,
  required VoidCallback onTap,
  VoidCallback? onMiddleClick,
  required bool enableLongPress,
  Color? highlightColor,
  Widget? topWidget,
  Widget? bottomWidget,
  List<PreviewAction>? previewActions,
  WidgetBuilder? previewCustomActionPanelBuilder,
}) {
  Widget child;

  if (topic.pinned) {
    child = CompactTopicCard(
      topic: topic,
      onTap: onTap,
      onMiddleClick: onMiddleClick,
      onLongPress: enableLongPress
          ? () => TopicPreviewDialog.show(
              context,
              topic: topic,
              onOpen: onTap,
              actions: previewActions,
              customActionPanelBuilder: previewCustomActionPanelBuilder,
            )
          : null,
      isSelected: isSelected,
      highlightColor: highlightColor,
    );
  } else {
    child = TopicCard(
      topic: topic,
      onTap: onTap,
      onMiddleClick: onMiddleClick,
      onLongPress: enableLongPress
          ? () => TopicPreviewDialog.show(
              context,
              topic: topic,
              onOpen: onTap,
              actions: previewActions,
              customActionPanelBuilder: previewCustomActionPanelBuilder,
            )
          : null,
      isSelected: isSelected,
      highlightColor: highlightColor,
      topWidget: topWidget,
      bottomWidget: bottomWidget,
    );
  }

  if (!Responsive.isMobile(context)) {
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
