import 'package:flutter/material.dart';
import '../../models/category.dart';
import '../../models/topic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/discourse_providers.dart';
import '../../services/topic_preview_preloader.dart';
import '../../utils/responsive.dart';
import 'painted_topic_card.dart';
import 'topic_card.dart';
import 'topic_card_layout.dart';
import 'topic_preview_dialog.dart';

/// 话题卡排版宽:与 [buildTopicItem] 的壳层约束同源(移动 = 视口宽
/// - 页边距 24;桌面 = 同口径再封顶 [Breakpoints.maxContentWidth])。
/// 预热层([TopicCardPrewarmer])必须用同一口径取宽,否则挂载帧
/// ensureWidth 纠偏重排,预热白做。
double topicCardWidthFor(BuildContext context) {
  final viewportWidth = MediaQuery.sizeOf(context).width - 24;
  if (Responsive.isMobile(context)) return viewportWidth;
  return viewportWidth > Breakpoints.maxContentWidth
      ? Breakpoints.maxContentWidth
      : viewportWidth;
}

/// 话题卡自绘路径总开关:false 一键回退 widget 版 TopicCard
/// (验收期保险丝;稳定后与 widget 分支一并清理)
const bool kUsePaintedTopicCard = true;

/// 普通/私信话题卡的排版取用单一入口:[buildTopicItem] 挂载路径与
/// [TopicCardPrewarmer] 空闲预热路径共用,保证 identity/宽度/theme/
/// category/statsAvailableWidth 全部同源 —— 预热建的缓存挂载帧必命中
/// (任一参数口径不一致,stamp 对不上就是白热)。
TopicCardLayout obtainTopicItemLayout({
  required BuildContext context,
  required Topic topic,
  Map<int, Category>? categoryMap,
  double? statsAvailableWidth,
  bool messageStyle = false,
}) {
  final cardWidth = topicCardWidthFor(context);
  final categoryId = int.tryParse(topic.categoryId);
  return TopicCardLayout.obtain(
    identity: 'topic:${topic.id}',
    topic: topic,
    width: cardWidth,
    theme: Theme.of(context),
    category: categoryMap?[categoryId],
    emojiUrlOf: topicCardEmojiUrlResolver,
    statsAvailableWidth: statsAvailableWidth ?? (cardWidth - 64),
    messageStyle: messageStyle,
  );
}

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
  final isMobile = Responsive.isMobile(context);

  // 一镜到底锚点底色:与各分支卡片外壳底色一致(置顶紧凑卡是半透明
  // surfaceContainerLow,普通卡是 cardTheme.color;落地高亮瞬时值优先)
  final theme = Theme.of(context);
  final anchorColor =
      highlightColor ??
      (topic.pinned
          ? theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5)
          : theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow);

  // Builder 紧贴卡片构造:longPress 需要卡片自身的 context 取屏幕
  // rect 作一镜到底起点(外层 context 的 RenderObject 在桌面端居中
  // 约束下是满宽,不是卡身)。bottomGap 裁掉卡片外壳底部间距。
  VoidCallback? longPressFor(BuildContext cardContext) => enableLongPress
      ? () => TopicPreviewDialog.show(
          context,
          topic: topic,
          onOpen: onTap,
          actions: previewActions,
          customActionPanelBuilder: previewCustomActionPanelBuilder,
          anchorRect: topicCardAnchorRect(
            cardContext,
            bottomGap: topic.pinned ? 6 : 8,
          ),
          anchorColor: anchorColor,
        )
      : null;

  // 长按意图预加载(正文):移动端按住不动 250ms / 桌面右键按下即触发,
  // 弹窗打开时正文多已在路上。chat 类场景没有话题 id 的不适用(调用
  // 方会自带 firstPostLoader,不受预加载影响)
  final previewIntent = enableLongPress
      ? () => TopicPreviewPreloader.preload(
          ProviderScope.containerOf(
            context,
            listen: false,
          ).read(discourseServiceProvider),
          topic.id,
        )
      : null;

  // 自绘路径的排版在 Builder 外先取好:入参(context/theme/宽度)与
  // Builder 内一致,避免逐分支重复。
  final usePainted =
      kUsePaintedTopicCard && topWidget == null && middleWidget == null;
  final paintedLayout = usePainted && !topic.pinned
      ? obtainTopicItemLayout(
          context: context,
          topic: topic,
          categoryMap: categoryMap,
          statsAvailableWidth: statsAvailableWidth,
          messageStyle: messageStyle,
        )
      : null;

  // 自绘路径:排版全局缓存 + 单渲染对象。宽度口径见
  // [topicCardWidthFor];分类表由调用方传入(未传时不查,分类行缺分
  // 类名 —— 各列表页均已传)
  final Widget child = Builder(
    builder: (cardContext) {
      if (topic.pinned) {
        return CompactTopicCard(
          topic: topic,
          onTap: onTap,
          onMiddleClick: onMiddleClick,
          onLongPress: longPressFor(cardContext),
          onPreviewIntent: previewIntent,
          isSelected: isSelected,
          highlightColor: highlightColor,
          categoryMap: categoryMap,
        );
      }
      if (paintedLayout != null) {
        return PaintedTopicCard(
          layout: paintedLayout,
          onTap: onTap,
          onMiddleClick: onMiddleClick,
          onLongPress: longPressFor(cardContext),
          onPreviewIntent: previewIntent,
          isSelected: isSelected,
          highlightColor: highlightColor,
        );
      }
      return TopicCard(
        topic: topic,
        onTap: onTap,
        onMiddleClick: onMiddleClick,
        onLongPress: longPressFor(cardContext),
        onPreviewIntent: previewIntent,
        isSelected: isSelected,
        highlightColor: highlightColor,
        topWidget: topWidget,
        middleWidget: middleWidget,
        messageStyle: messageStyle,
        categoryMap: categoryMap,
        statsAvailableWidth: statsAvailableWidth,
      );
    },
  );

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
