import 'dart:async';
import 'dart:math' as math;

import 'package:common_ui/common_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../../providers/preferences_provider.dart';
import '../../../l10n/s.dart';
import '../../../utils/time_utils.dart';
import '../../../widgets/common/emoji_text.dart';
import '../controllers/topic_position_info.dart';
import '../controllers/topic_jump_history.dart';
import 'progress_gesture_action_meta.dart';
import 'topic_bottom_bar.dart';
import 'topic_filter_controls.dart';
import 'topic_progress_track.dart';
import 'topic_timeline.dart';

/// 宽屏阅读栏：帖子列右侧留白里常驻的竖向时间线 + 阅读工具，宽屏下
/// 取代底栏（底部不再放任何东西）。
///
/// - 时间线直接拖动 / 点按定位，楼号和日期跟手，停稳后在轨道旁预览摘要，
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
    this.nextRootListenable,
    this.returnButton,
    this.jumpHistory,
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
  final ValueListenable<VoidCallback?>? nextRootListenable;
  final Widget? returnButton;
  final TopicJumpHistory? jumpHistory;

  @override
  State<TopicReadingRail> createState() => _TopicReadingRailState();
}

class _TopicReadingRailState extends State<TopicReadingRail> {
  /// 拖动 / 点按中的预览楼层；null 时跟随阅读位置
  final ValueNotifier<int?> _preview = ValueNotifier<int?>(null);

  final ValueNotifier<double?> _speed = ValueNotifier(null);

  @override
  void dispose() {
    _speed.dispose();
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

    final tools = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.returnButton != null && widget.jumpHistory != null)
          ListenableBuilder(
            listenable: widget.jumpHistory!,
            child: Align(
              alignment: Alignment.centerLeft,
              child: widget.returnButton,
            ),
            builder: (context, child) => Padding(
              padding: EdgeInsets.only(
                bottom: widget.jumpHistory!.target == null ? 0 : 16,
              ),
              child: child,
            ),
          ),
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
        if (widget.nextRootListenable != null)
          ValueListenableBuilder<VoidCallback?>(
            valueListenable: widget.nextRootListenable!,
            builder: (context, nextRoot, _) => nextRoot == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      onPressed: nextRoot,
                      tooltip: context.l10n.nested_nextRoot,
                      icon: const Icon(Symbols.skip_next_rounded),
                    ),
                  ),
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
    if (!showsProgress) return tools;
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 摘要浮在轨道旁，轨道与下方工具各自占用固定位置。
          SizedBox(
            height: math.min(420.0, constraints.maxHeight * .56),
            child: ListenableBuilder(
              listenable: Listenable.merge([
                widget.streamIndexListenable,
                _preview,
              ]),
              builder: (context, _) {
                final current = widget.streamIndexListenable.value;
                final selected = _preview.value ?? current;
                return TopicTimelineTrack(
                  width: TopicReadingRail.width,
                  mirrored: true,
                  totalCount: widget.totalCount,
                  selectedIndex: selected,
                  dragPreviewBuilder: (dragging, opacity) => _RailExcerpt(
                    index: selected,
                    total: widget.totalCount,
                    source: widget.infoSource,
                    dragging: dragging,
                    opacity: opacity,
                  ),
                  currentIndex: current,
                  lastReadIndex: widget.lastReadIndex,
                  dateAt: widget.infoSource.dateAt,
                  onChanged: (index) => _preview.value = index,
                  onSpeedChanged: (speed) => _speed.value = speed,
                  onChangeEnd: _commit,
                  onChangeCancel: (_) => _preview.value = null,
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              primary: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _PositionCard(
                    streamIndexListenable: widget.streamIndexListenable,
                    previewListenable: _preview,
                    speedListenable: _speed,
                    totalCount: widget.totalCount,
                    infoSource: widget.infoSource,
                  ),
                  const SizedBox(height: 16),
                  tools,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 固定的楼号和日期读数，拖动时在楼号旁显示当前倍率。
class _PositionCard extends StatelessWidget {
  const _PositionCard({
    required this.streamIndexListenable,
    required this.previewListenable,
    required this.speedListenable,
    required this.totalCount,
    required this.infoSource,
  });

  final ValueListenable<int> streamIndexListenable;
  final ValueListenable<int?> previewListenable;
  final ValueListenable<double?> speedListenable;
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
        speedListenable,
      ]),
      builder: (context, _) {
        final preview = previewListenable.value;
        final index = preview ?? streamIndexListenable.value;
        final date = infoSource.dateAt(index);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$index',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: preview != null
                                ? context.emphasis.selected
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (speedListenable.value case final speed?) ...[
                  const SizedBox(width: 8),
                  TopicTimelineSpeedLabel(speed: speed),
                ],
              ],
            ),
            // 日期缺失时也保留行高，让下方工具位置稳定。
            Text(
              date == null ? '' : TimeUtils.formatSmartDate(date),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 快速掠过时只移动读数。停在一层后才读取摘要，晚到的数据只匹配当下的楼层。
class _RailExcerpt extends StatefulWidget {
  const _RailExcerpt({
    required this.index,
    required this.total,
    required this.source,
    required this.dragging,
    required this.opacity,
  });

  final bool dragging;
  final double opacity;

  final int index, total;
  final TopicPositionInfoSource source;

  @override
  State<_RailExcerpt> createState() => _RailExcerptState();
}

class _RailExcerptState extends State<_RailExcerpt> {
  final _portal = OverlayPortalController()..show();
  Timer? _timer;
  bool _settled = false;

  @override
  void initState() {
    super.initState();
    _waitForFloor();
  }

  @override
  void didUpdateWidget(_RailExcerpt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index ||
        oldWidget.source != widget.source ||
        oldWidget.dragging != widget.dragging) {
      _waitForFloor();
    }
  }

  void _waitForFloor() {
    _timer?.cancel();
    _settled = false;
    if (!widget.dragging) return;
    _timer = Timer(const Duration(milliseconds: 160), () {
      // 每次停稳只请求一次，后续重绘只读缓存。
      widget.source.infoAt(widget.index);
      setState(() => _settled = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _portal,
    child: const SizedBox.expand(),
    overlayChildBuilder: (context, layout) {
      final rail = MatrixUtils.transformRect(
        layout.childPaintTransform,
        Offset.zero & layout.childSize,
      );
      final screen = Offset.zero & layout.overlaySize;
      final safe = MediaQuery.paddingOf(context).deflateRect(screen);
      if (!rail.overlaps(safe)) return const SizedBox.shrink();
      final top = math.max(rail.top, safe.top),
          bottom = math.min(rail.bottom, safe.bottom);
      final leftRoom = rail.left - safe.left;
      final rightRoom = safe.right - rail.right;
      const width = 304.0;
      final left = leftRoom >= width || leftRoom >= rightRoom;
      final extent = math.min(width, left ? leftRoom : rightRoom);
      if (extent <= 0 || bottom <= top) return const SizedBox.shrink();
      final reduceMotion =
          MediaQuery.disableAnimationsOf(context) ||
          MediaQuery.reduceMotionOf(context);
      return Positioned(
        top: top,
        height: bottom - top,
        left: left ? rail.left - extent : rail.right,
        width: extent,
        child: IgnorePointer(
          child: Opacity(
            opacity: widget.opacity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RepaintBoundary(child: _buildGradient(context, left)),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    left ? extent * .25 : 16,
                    18,
                    left ? 16 : extent * .25,
                    18,
                  ),
                  child: _buildPreviewText(left, reduceMotion),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _buildPreviewText(bool left, bool reduceMotion) => ListenableBuilder(
    listenable: widget.source,
    builder: (context, _) {
      final info = _settled
          ? widget.source.infoAt(widget.index, loadExcerpt: false)
          : null;
      final fraction = TopicProgressTrack.fraction(widget.index, widget.total);
      final hasContent =
          info != null && (info.username != null || info.excerpt != null);
      return AnimatedSwitcher(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 110),
        reverseDuration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 80),
        child: hasContent
            ? Align(
                key: ValueKey(widget.index),
                alignment: Alignment(left ? 1 : -1, 2 * fraction - 1),
                child: _buildExcerpt(context, info),
              )
            : null,
      );
    },
  );

  Widget _buildGradient(BuildContext context, bool left) {
    final surface = Theme.of(context).colorScheme.surface;
    final tint = TopicProgressGradient.tintOf(context);
    // 色带一直连到轨道。快扫、等待加载和摘要换行只更新文字。
    return TopicProgressGradient(
      axis: Axis.vertical,
      startFeather: TopicTimelineTrack.endFeather,
      endFeather: TopicTimelineTrack.endFeather,
      gradient: LinearGradient(
        begin: left ? Alignment.centerRight : Alignment.centerLeft,
        end: left ? Alignment.centerLeft : Alignment.centerRight,
        colors: [
          tint,
          Color.lerp(tint, surface, .54)!,
          surface.withValues(alpha: .96),
          surface.withValues(alpha: .65),
          surface.withValues(alpha: .24),
          surface.withValues(alpha: 0),
        ],
        stops: const [0, .30, .62, .78, .90, 1],
      ),
    );
  }

  Widget _buildExcerpt(BuildContext context, TopicPositionInfo info) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );
    final author = info.username, text = info.excerpt;
    return Material(
      type: MaterialType.transparency,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '#${widget.index}${author == null ? '' : '  $author'}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (text != null) ...[
              const TextSpan(text: '\n'),
              ...EmojiText.buildEmojiSpans(context, text, style, inline: true),
            ],
          ],
        ),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}
