import 'package:common_ui/common_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../../providers/preferences_provider.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/emoji_text.dart';
import '../controllers/topic_position_info.dart';
import 'progress_gesture_action_meta.dart';
import 'topic_bottom_bar.dart';
import 'topic_filter_controls.dart';
import 'topic_timeline.dart';

/// 宽屏阅读栏：帖子列右侧留白里常驻的竖向时间线 + 阅读工具，宽屏下
/// 取代底栏（底部不再放任何东西）。
///
/// - 时间线直接拖动 / 点按定位，拖动中下方预览目标楼层的日期与摘要，
///   松手才跳转；轨道两端即顶部与最新，不需要回顶按钮
/// - 回复入口、筛选状态常驻可见
/// - 快捷按钮复用用户在手势设置里配置的长按菜单动作（一份配置两种
///   呈现），去掉本栏自身已提供的
class TopicReadingRail extends StatefulWidget {
  const TopicReadingRail({
    super.key,
    required this.streamIndexListenable,
    required this.totalCount,
    required this.infoSource,
    required this.onJumpToIndex,
    required this.replyEntryState,
    required this.onReplyEntryTap,
    required this.filter,
    required this.quickActions,
    required this.onAction,
    this.lastReadIndex,
    this.replyDraftListenable,
  });

  /// 栏宽（不含与帖子列的间距）
  static const double width = 220;

  /// 与帖子列之间的间距
  static const double gap = 24;

  /// 本栏自身已提供的能力，快捷按钮里不再重复
  static const Set<ProgressGestureAction> _builtIn = {
    ProgressGestureAction.none,
    ProgressGestureAction.openTimeline,
    ProgressGestureAction.scrollToTop,
    ProgressGestureAction.reply,
    ProgressGestureAction.filter,
  };

  final ValueListenable<int> streamIndexListenable;
  final int totalCount;
  final TopicPositionInfoSource infoSource;
  final ValueChanged<int> onJumpToIndex;
  final TopicReplyEntryState replyEntryState;
  final VoidCallback onReplyEntryTap;
  final TopicFilterControls filter;
  final List<ProgressGestureAction> quickActions;
  final ValueChanged<ProgressGestureAction> onAction;
  final int? lastReadIndex;
  final ValueListenable<String?>? replyDraftListenable;

  @override
  State<TopicReadingRail> createState() => _TopicReadingRailState();
}

class _TopicReadingRailState extends State<TopicReadingRail> {
  /// 拖动 / 点按中的预览楼层；null 时跟随阅读位置
  final ValueNotifier<int?> _preview = ValueNotifier<int?>(null);

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  void _commit(int index) {
    _preview.value = null;
    if (index != widget.streamIndexListenable.value) {
      widget.onJumpToIndex(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showsProgress = !widget.filter.isNestedMode && widget.totalCount > 1;
    final actions = [
      for (final action in widget.quickActions)
        if (!TopicReadingRail._builtIn.contains(action)) action,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showsProgress) ...[
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  widget.streamIndexListenable,
                  _preview,
                ]),
                builder: (context, _) {
                  final current = widget.streamIndexListenable.value;
                  return TopicTimelineTrack(
                    width: TopicReadingRail.width,
                    mirrored: true,
                    totalCount: widget.totalCount,
                    selectedIndex: _preview.value ?? current,
                    currentIndex: current,
                    lastReadIndex: widget.lastReadIndex,
                    dateAt: widget.infoSource.dateAt,
                    onChanged: (index) => _preview.value = index,
                    onChangeEnd: _commit,
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          _PositionCard(
            streamIndexListenable: widget.streamIndexListenable,
            previewListenable: _preview,
            totalCount: widget.totalCount,
            infoSource: widget.infoSource,
          ),
          const SizedBox(height: 16),
        ],
        TopicReplyEntry(
          state: widget.replyEntryState,
          draftListenable: widget.replyDraftListenable,
          onTap: widget.onReplyEntryTap,
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TopicFilterButton(controls: widget.filter, showLabel: true),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final action in actions)
                () {
                  final meta = progressGestureActionMeta(context, action);
                  return IconButton(
                    onPressed: () => widget.onAction(action),
                    tooltip: meta.label,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(meta.icon),
                    color: theme.colorScheme.onSurfaceVariant,
                  );
                }(),
            ],
          ),
        ],
      ],
    );
  }
}

/// 楼层号与该位置的日期；拖动预览时额外显示作者与摘要
class _PositionCard extends StatelessWidget {
  const _PositionCard({
    required this.streamIndexListenable,
    required this.previewListenable,
    required this.totalCount,
    required this.infoSource,
  });

  final ValueListenable<int> streamIndexListenable;
  final ValueListenable<int?> previewListenable;
  final int totalCount;
  final TopicPositionInfoSource infoSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const tabular = [FontFeature.tabularFigures()];
    return ListenableBuilder(
      listenable: Listenable.merge([
        streamIndexListenable,
        previewListenable,
        infoSource,
      ]),
      builder: (context, _) {
        final preview = previewListenable.value;
        final index = preview ?? streamIndexListenable.value;
        // 跟随阅读位置时不拉摘要：只有拖动预览才需要
        final info = infoSource.infoAt(index, loadExcerpt: preview != null);
        final excerptStyle = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          height: 1.4,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$index',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: preview != null
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                      fontFeatures: tabular,
                    ),
                  ),
                  TextSpan(
                    text: ' / $totalCount',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFeatures: tabular,
                    ),
                  ),
                ],
              ),
            ),
            if (info.date != null)
              Text(
                TimeUtils.formatSmartDate(info.date),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (preview != null &&
                (info.username != null || info.excerpt != null))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: context.shapes.borderRadius(12),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          if (info.username != null)
                            TextSpan(
                              text: info.excerpt == null
                                  ? info.username
                                  : '${info.username}  ',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          // 摘要由 cooked 还原，短代码已是 cook 判定过的表情
                          if (info.excerpt != null)
                            ...EmojiText.buildEmojiSpans(
                              context,
                              info.excerpt!,
                              excerptStyle,
                              inline: true,
                            ),
                        ],
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: excerptStyle,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
