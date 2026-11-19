import 'package:common_ui/common_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/services.dart';

import '../../../l10n/s.dart';
import '../../../utils/time_utils.dart';
import '../../../utils/dialog_utils.dart';
import '../../../widgets/common/emoji_text.dart';
import '../controllers/topic_position_info.dart';
import 'topic_progress_track.dart';
import 'topic_scrub_mapping.dart';

/// 竖向时间线轨道：两端标起止日期，中段按查找表标日期刻度，标出当前
/// 位置与上次阅读位置；拖动手柄选择楼层（stream 索引，1 起）。
///
/// 长话题的精度：拖动是相对位移，手指横向离轨道越远速度越慢
/// （×1 → ×1/4 → ×1/16），轨道再短也能逐楼定位；点按轨道直接跳到该处。
class TopicTimelineTrack extends StatefulWidget {
  const TopicTimelineTrack({
    super.key,
    required this.totalCount,
    required this.selectedIndex,
    required this.onChanged,
    this.currentIndex,
    this.lastReadIndex,
    this.dateAt,
    this.onSpeedChanged,
    this.onChangeEnd,
    this.onChangeCancel,
    this.dragPreviewBuilder,
    this.mirrored = false,
    this.width = 120,
  });

  final int totalCount;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// 阅读中的当前位置（空心环标记）
  final int? currentIndex;

  /// 上次阅读位置（实心点标记）
  final int? lastReadIndex;
  final DateTime? Function(int index)? dateAt;

  /// 拖动速度倍率变化（拖动结束回调 null）
  final ValueChanged<double?>? onSpeedChanged;

  /// 拖动松手或点按轨道后回调最终楼层（常驻轨道据此才真正跳转）
  final ValueChanged<int>? onChangeEnd;
  final ValueChanged<int>? onChangeCancel;

  /// 拖动时以轨道区域为锚点展示浮层，宿主提供内容。
  final Widget Function(bool dragging, double opacity)? dragPreviewBuilder;

  /// 首末楼的留白。渐变在两端留出更长的过渡。
  static const double _endPadding = 26;
  static const double endFeather = _endPadding * 2;

  /// 镜像：轨道靠左、标签在右（放在内容右侧时用），默认轨道靠右
  final bool mirrored;
  final double width;

  @override
  State<TopicTimelineTrack> createState() => _TopicTimelineTrackState();
}

class _TopicTimelineTrackState extends State<TopicTimelineTrack>
    with SingleTickerProviderStateMixin {
  static const double _trackInset = 22;
  static const double _labelOffset = _trackInset + 16;

  /// 相邻标签的最小纵向间距
  static const double _labelMinGap = 18;

  /// 手指离轨道的横向距离分档 → 速度倍率
  static const List<(double, double)> _speedSteps = [
    (56, 1),
    (128, 1 / 4),
    (double.infinity, 1 / 16),
  ];

  bool _dragging = false;
  bool _hovering = false;
  int _startIndex = 1;
  double _position = 1;
  double _anchorFloor = 1;
  double _anchorY = 0;
  double _speed = 1;
  int? _lastEmitted;
  late final _thumbMotion = TopicThumbMotion(this);

  @override
  void dispose() {
    _thumbMotion.dispose();
    super.dispose();
  }

  int get _total => widget.totalCount;

  double _fraction(int index) =>
      _total > 1 ? ((index - 1) / (_total - 1)).clamp(0.0, 1.0) : 0.0;

  double _trackHeight(double height) =>
      (height - TopicTimelineTrack._endPadding * 2).clamp(1.0, double.infinity);

  double _yFor(int index, double height) =>
      TopicTimelineTrack._endPadding + _fraction(index) * _trackHeight(height);

  int _indexAt(double y, double height) {
    final fraction =
        ((y - TopicTimelineTrack._endPadding) / _trackHeight(height)).clamp(
          0.0,
          1.0,
        );
    return (fraction * (_total - 1) + 1).round().clamp(1, _total);
  }

  void _emit(int index) {
    if (index == (_lastEmitted ?? widget.selectedIndex)) return;
    _lastEmitted = index;
    HapticFeedback.selectionClick();
    widget.onChanged(index);
  }

  void _handleTap(double y, double height) {
    final index = _indexAt(y, height);
    _emit(index);
    widget.onChangeEnd?.call(index);
    _lastEmitted = null;
  }

  void _anchorDrag(double localY) {
    _anchorY = localY - TopicTimelineTrack._endPadding;
    _anchorFloor = _position;
  }

  void _handleDragStart(DragStartDetails details) {
    _thumbMotion.reset();
    _startIndex = widget.selectedIndex;
    _position = _startIndex.toDouble();
    _anchorDrag(details.localPosition.dy);
    setState(() => _dragging = true);
    _updateSpeed(details.localPosition.dx);
  }

  void _handleDragUpdate(
    DragUpdateDetails details,
    double height,
    bool reduceMotion,
  ) {
    final extent = _trackHeight(height);
    final unitsPerPx = (_total - 1) / extent;
    if (unitsPerPx <= 0) return;
    final oldSpeed = _speed;
    _updateSpeed(details.localPosition.dx);
    final y = details.localPosition.dy;
    if (oldSpeed != _speed) _anchorDrag(y - details.delta.dy);
    final previous = _position;
    final pointer = y - TopicTimelineTrack._endPadding;
    if (_speed == 1) {
      final at = relativeScrubPosition(
        startPosition: (_anchorFloor - 1) / (_total - 1) * extent,
        pointerStart: _anchorY,
        pointer: pointer,
        extent: extent,
      );
      _position = 1 + at / extent * (_total - 1);
    } else {
      _position = (_anchorFloor + (pointer - _anchorY) * unitsPerPx * _speed)
          .clamp(1.0, _total.toDouble());
    }
    if ((_position == 1 && details.delta.dy < 0) ||
        (_position == _total && details.delta.dy > 0)) {
      _anchorDrag(y);
    }
    if (!reduceMotion) {
      _thumbMotion.moveBy((_position - previous) / unitsPerPx);
    }
    _emit(_position.round());
  }

  void _handleDragEnd({bool canceled = false}) {
    if (!_dragging) return;
    setState(() => _dragging = false);
    _speed = 1;
    widget.onSpeedChanged?.call(null);
    final last = _lastEmitted;
    if (canceled) {
      (widget.onChangeCancel ?? widget.onChanged)(_startIndex);
    } else if (last != null) {
      widget.onChangeEnd?.call(last);
    }
    _lastEmitted = null;
  }

  /// 按轨道所在一侧摆放（[end] 是到轨道一侧外沿的距离）
  Widget _place({
    required double end,
    double? top,
    double? bottom,
    double? width,
    required Widget child,
  }) {
    return widget.mirrored
        ? Positioned(
            left: end,
            top: top,
            bottom: bottom,
            width: width,
            child: child,
          )
        : Positioned(
            right: end,
            top: top,
            bottom: bottom,
            width: width,
            child: child,
          );
  }

  void _updateSpeed(double localX) {
    final trackX = widget.mirrored ? _trackInset : widget.width - _trackInset;
    final distance = (localX - trackX).abs();
    final speed = _speedSteps.firstWhere((s) => distance < s.$1).$2;
    if (speed != _speed) {
      _speed = speed;
      HapticFeedback.lightImpact();
    }
    widget.onSpeedChanged?.call(_speed);
  }

  /// 中段日期刻度：在 1/4、1/2、3/4 处取查找表日期，与相邻标签重复的不画
  List<(int, String)> _ticks() {
    final dateAt = widget.dateAt;
    if (dateAt == null || _total < 8) return const [];
    final labels = <(int, String)>[];
    String? previous = _label(dateAt(1));
    final end = _label(dateAt(_total));
    for (final f in const [0.25, 0.5, 0.75]) {
      final index = (f * (_total - 1) + 1).round();
      final label = _label(dateAt(index));
      if (label == null || label == previous || label == end) continue;
      labels.add((index, label));
      previous = label;
    }
    return labels;
  }

  String? _label(DateTime? date) =>
      date == null ? null : TimeUtils.formatSmartDate(date);

  Widget _buildTrack(bool reduceMotion) {
    final surface = widget.mirrored
        ? TopicProgressSurface.sidebar
        : TopicProgressSurface.sheet;
    final current = widget.currentIndex;
    final lastRead = widget.lastReadIndex;
    final hover = widget.mirrored && _total > 1 && _hovering;
    final expansion = _dragging ? 1.0 : (hover ? .35 : 0.0);
    final duration = _dragging
        ? TopicProgressTrack.openDuration
        : TopicProgressTrack.closeDuration;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: expansion),
      duration: reduceMotion ? Duration.zero : duration,
      curve: TopicProgressTrack.curve,
      builder: (context, opening, _) => TweenAnimationBuilder<double>(
        // 点按日期或输入楼层时，填充和握柄一起滑到目标；拖动时直接跟手。
        tween: Tween(end: _fraction(widget.selectedIndex)),
        duration: _dragging || reduceMotion
            ? Duration.zero
            : TopicProgressTrack.closeDuration,
        curve: Curves.easeOutCubic,
        builder: (context, progress, _) => TopicProgressTrack(
          surface: surface,
          thumbTravel: reduceMotion
              ? kAlwaysDismissedAnimation
              : _thumbMotion.travel,
          startInset: TopicTimelineTrack._endPadding,
          endInset: TopicTimelineTrack._endPadding,
          progress: progress,
          current: current == null || current == widget.selectedIndex
              ? null
              : _fraction(current),
          lastRead: lastRead != null && lastRead > 1 && lastRead < _total
              ? _fraction(lastRead)
              : null,
          expansion: opening,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.reduceMotionOf(context);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SizedBox(
      width: widget.width,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          final startDate = _label(widget.dateAt?.call(1));
          final endDate = _label(widget.dateAt?.call(_total));
          final lastRead = widget.lastReadIndex;

          // 所有标签都放在轨道侧边，与轨道中线隔开手柄半径以上：手柄停在
          // 任何位置都不会盖住标签
          Widget sideLabel(double y, String text, {TextStyle? style}) {
            return _place(
              end: _labelOffset,
              top: y,
              width: (constraints.maxWidth - _labelOffset).clamp(
                0.0,
                constraints.maxWidth,
              ),
              child: FractionalTranslation(
                translation: const Offset(0, -0.5),
                child: Text(
                  text,
                  style: style ?? labelStyle,
                  maxLines: 1,
                  textAlign: widget.mirrored ? TextAlign.left : TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          }

          // 按优先级放置，彼此太近的后者让位：起止日期 > 上次阅读 > 刻度
          final labelHeight =
              MediaQuery.textScalerOf(context)
                  .scale(labelStyle?.fontSize ?? 11) *
              (labelStyle?.height ?? 1.4);
          final minGap = labelHeight < _labelMinGap
              ? _labelMinGap
              : labelHeight + 2;
          final occupied = <double>[];
          final labels = <Widget>[];
          void tryAdd(int index, String? text, {TextStyle? style}) {
            if (text == null) return;
            final y = _yFor(index, height);
            if (occupied.any((o) => (o - y).abs() < minGap)) return;
            occupied.add(y);
            labels.add(sideLabel(y, text, style: style));
          }

          tryAdd(1, startDate);
          // 起止同一天（如当天的话题）只标一次
          if (endDate != startDate) tryAdd(_total, endDate);
          if (lastRead != null && lastRead > 1 && lastRead < _total) {
            tryAdd(
              lastRead,
              context.l10n.topic_timelineLastRead,
              style: labelStyle?.copyWith(
                color: context.emphasis.selected,
                fontWeight: FontWeight.w600,
              ),
            );
          }
          for (final (index, text) in _ticks()) {
            tryAdd(index, text);
          }

          final interactive = _total > 1;
          final showHover = widget.mirrored && interactive;
          final preview = widget.dragPreviewBuilder;
          final tint = TopicProgressGradient.tintOf(context);
          final axis = constraints.maxWidth > _trackInset
              ? _trackInset / constraints.maxWidth
              : 1.0;
          final clear = tint.withValues(alpha: 0);
          // 宽屏左侧预览和轨道在阅读栏边缘相接，两侧共用颜色、羽化和逐帧透明度。
          final backdrop = RepaintBoundary(
            child: TopicProgressGradient(
              axis: Axis.vertical,
              startFeather: TopicTimelineTrack.endFeather,
              endFeather: TopicTimelineTrack.endFeather,
              gradient: LinearGradient(
                begin: widget.mirrored
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                end: widget.mirrored
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                colors: [
                  preview == null ? clear : tint,
                  tint,
                  tint.withValues(alpha: .48),
                  clear,
                ],
                stops: [0, axis, axis + (1 - axis) * .48, 1],
              ),
            ),
          );
          return MouseRegion(
            cursor: interactive
                ? (_dragging
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab)
                : MouseCursor.defer,
            onEnter: showHover ? (_) => setState(() => _hovering = true) : null,
            onExit: showHover ? (_) => setState(() => _hovering = false) : null,
            child: Listener(
              onPointerCancel: (_) => _handleDragEnd(canceled: true),
              child: GestureDetector(
                dragStartBehavior: DragStartBehavior.down,
                behavior: HitTestBehavior.opaque,
                onTapUp: interactive
                    ? (d) => _handleTap(d.localPosition.dy, height)
                    : null,
                onVerticalDragStart: interactive ? _handleDragStart : null,
                onVerticalDragUpdate: interactive
                    ? (d) => _handleDragUpdate(d, height, reduceMotion)
                    : null,
                onVerticalDragEnd: (_) => _handleDragEnd(),
                onVerticalDragCancel: () => _handleDragEnd(canceled: true),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: _dragging ? 1 : 0),
                  duration: reduceMotion
                      ? Duration.zero
                      : TopicProgressTrack.closeDuration,
                  curve: TopicProgressTrack.curve,
                  child: Stack(
                    children: [
                      _place(
                        end: _trackInset - 12,
                        top: 0,
                        bottom: 0,
                        width: 24,
                        child: _buildTrack(reduceMotion),
                      ),
                      ...labels,
                    ],
                  ),
                  builder: (context, opacity, content) => Stack(
                    fit: StackFit.expand,
                    children: [
                      IgnorePointer(
                        child: Opacity(opacity: opacity, child: backdrop),
                      ),
                      content!,
                      if (preview != null && (_dragging || opacity > 0))
                        IgnorePointer(child: preview(_dragging, opacity)),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 横向离开竖轨后，当前拖动倍率显示在预览楼号旁。
class TopicTimelineSpeedLabel extends StatelessWidget {
  const TopicTimelineSpeedLabel({super.key, required this.speed});

  final double speed;

  @override
  Widget build(BuildContext context) {
    final accent = context.emphasis.selected;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .10),
        borderRadius: context.shapes.borderRadius(UiShapes.fullThreshold),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Text(
          speed == 1 ? '×1' : '×1/${(1 / speed).round()}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: accent,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// 时间线弹窗：左侧选中楼层的信息（楼层号、日期、作者与摘要、快捷跳转），
/// 右侧 [TopicTimelineTrack]
class TopicTimelineSheet extends StatefulWidget {
  const TopicTimelineSheet({
    super.key,
    required this.infoSource,
    required this.currentIndex,
    required this.onJumpToIndex,
    required this.topPadding,
    this.title,
  });

  final TopicPositionInfoSource infoSource;

  /// 当前 stream 索引（1 起）
  final int currentIndex;

  /// 确认跳转，参数是 stream 索引
  final ValueChanged<int> onJumpToIndex;

  /// 状态栏高度（从父 context 传入，弹层内部 padding.top 会被清零）
  final double topPadding;
  final String? title;

  @override
  State<TopicTimelineSheet> createState() => _TopicTimelineSheetState();
}

class _TopicTimelineSheetState extends State<TopicTimelineSheet> {
  late int _selectedIndex;
  bool _isEditing = false;
  double? _dragSpeed;
  late final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  int get _total => widget.infoSource.totalCount;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.currentIndex.clamp(1, _total < 1 ? 1 : _total);
    widget.infoSource.addListener(_onInfoChanged);
  }

  @override
  void dispose() {
    widget.infoSource.removeListener(_onInfoChanged);
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onInfoChanged() {
    if (mounted) setState(() {});
  }

  void _select(int index) {
    final clamped = index.clamp(1, _total);
    if (clamped == _selectedIndex) return;
    setState(() => _selectedIndex = clamped);
  }

  void _step(int delta) {
    HapticFeedback.selectionClick();
    _select(_selectedIndex + delta);
  }

  void _enterEditMode() {
    setState(() {
      _isEditing = true;
      _textController.text = '$_selectedIndex';
      _textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textController.text.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  void _commitEdit() {
    final value = int.tryParse(_textController.text);
    if (value != null && value >= 1 && value <= _total) {
      _select(value);
    }
    setState(() => _isEditing = false);
    _focusNode.unfocus();
  }

  void _commitJump() {
    widget.onJumpToIndex(_selectedIndex);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final screenHeight = mediaQuery.size.height;
    final contentHeight = (screenHeight * 0.7).clamp(
      0.0,
      screenHeight - widget.topPadding - bottomInset,
    );
    final info = widget.infoSource.infoAt(_selectedIndex);
    final lastRead = widget.infoSource.lastReadIndex;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: contentHeight,
        decoration: ShapeDecoration(
          color: theme.colorScheme.surface,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.vertical(top: context.shapes.radius(28)),
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: ShapeDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.2,
                  ),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: context.shapes.borderRadius(2),
                  ),
                ),
              ),
              if (widget.title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: EmojiText(
                    widget.title!,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 20, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _buildInfoPanel(context, theme, info, lastRead),
                      ),
                      const SizedBox(width: 12),
                      TopicTimelineTrack(
                        // 窄屏让出宽度给左侧信息，但留够侧边日期标签
                        width: (MediaQuery.sizeOf(context).width * 0.3).clamp(
                          112.0,
                          148.0,
                        ),
                        totalCount: _total,
                        selectedIndex: _selectedIndex,
                        currentIndex: widget.currentIndex,
                        lastReadIndex: lastRead,
                        dateAt: widget.infoSource.dateAt,
                        onChanged: _select,
                        onSpeedChanged: (speed) {
                          if (speed != _dragSpeed) {
                            setState(() => _dragSpeed = speed);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text(context.l10n.common_cancel),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton(
                        onPressed: _commitJump,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedSuperellipseBorder(
                            borderRadius: context.shapes.borderRadius(16),
                          ),
                        ),
                        child: Text(
                          context.l10n.topic_jump,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoPanel(
    BuildContext context,
    ThemeData theme,
    TopicPositionInfo info,
    int? lastRead,
  ) {
    final l10n = context.l10n;
    final speed = _dragSpeed;
    final meta = [
      if (info.date != null) TimeUtils.formatSmartDate(info.date),
      ?info.username,
    ].join(' · ');
    final excerpt = info.excerpt;
    final muted = theme.colorScheme.onSurfaceVariant;

    return LayoutBuilder(
      builder: (context, constraints) {
        // 楼数多于轨道像素时逐楼定位才需要精细调节，此时才给提示
        final needsFineHint = _total > constraints.maxHeight;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 主：楼层号独占一行，空间不够时整体等比缩小而不是截断
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(child: _buildNumber(theme)),
                if (speed != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: TopicTimelineSpeedLabel(speed: speed),
                  ),
              ],
            ),
            // 「日期 · 作者」与步进按钮同一行
            Row(
              children: [
                Expanded(
                  child: Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
                const SizedBox(width: 8),
                _buildStepper(context, theme),
              ],
            ),
            const SizedBox(height: 16),
            // 次：该楼摘要。摘要区占满中间、卡片在区内顶部对齐，摘要长短
            // 变化时下方的快捷跳转不跟着移动
            Expanded(
              child: excerpt == null
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: Alignment.topLeft,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          shape: RoundedSuperellipseBorder(
                            borderRadius: context.shapes.borderRadius(12),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          // 摘要由 cooked 还原，短代码已是 cook 判定过的表情
                          child: EmojiText(
                            excerpt,
                            inline: true,
                            maxLines: 6,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            // 弱：快捷跳转与提示
            Wrap(
              spacing: 4,
              children: [
                _jumpButton(
                  theme,
                  Symbols.vertical_align_top_rounded,
                  l10n.topic_timelineTop,
                  () => _select(1),
                ),
                if (lastRead != null && lastRead < _total)
                  _jumpButton(
                    theme,
                    Symbols.bookmark_flag_rounded,
                    l10n.topic_timelineLastRead,
                    () => _select(lastRead),
                  ),
                _jumpButton(
                  theme,
                  Symbols.vertical_align_bottom_rounded,
                  l10n.topic_timelineLatest,
                  () => _select(_total),
                ),
              ],
            ),
            if (needsFineHint)
              Opacity(
                opacity: speed == null ? 1 : 0,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text(
                    l10n.topic_timelineFineHint,
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 上下步进：一组紧凑的按钮，逐楼微调
  Widget _buildStepper(BuildContext context, ThemeData theme) {
    final l10n = context.l10n;
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.all(context.shapes.radius(9999)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: _selectedIndex > 1 ? () => _step(-1) : null,
            tooltip: l10n.progressGesture_action_previousPost,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.keyboard_arrow_up_rounded),
          ),
          IconButton(
            onPressed: _selectedIndex < _total ? () => _step(1) : null,
            tooltip: l10n.progressGesture_action_nextPost,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.keyboard_arrow_down_rounded),
          ),
        ],
      ),
    );
  }

  Widget _jumpButton(
    ThemeData theme,
    IconData icon,
    String label,
    VoidCallback onPressed,
  ) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: theme.textTheme.labelMedium,
      ),
    );
  }

  Widget _buildNumber(ThemeData theme) {
    const tabular = [FontFeature.tabularFigures()];
    final numberStyle = theme.textTheme.displaySmall?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w800,
      fontFeatures: tabular,
    );
    final totalStyle = theme.textTheme.titleMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      fontFeatures: tabular,
    );
    if (_isEditing) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: TextField(
              controller: _textController,
              focusNode: _focusNode,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: numberStyle,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 4),
              ),
              onSubmitted: (_) => _commitEdit(),
              onTapOutside: (_) => _commitEdit(),
            ),
          ),
          Text(' / $_total', style: totalStyle),
        ],
      );
    }
    return GestureDetector(
      onTap: _enterEditMode,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$_selectedIndex', style: numberStyle),
              TextSpan(text: ' / $_total', style: totalStyle),
            ],
          ),
          maxLines: 1,
        ),
      ),
    );
  }
}

/// 显示时间线弹窗
Future<void> showTopicTimelineSheet({
  required BuildContext context,
  required TopicPositionInfoSource infoSource,
  required int currentIndex,
  required ValueChanged<int> onJumpToIndex,
  String? title,
}) {
  // 在弹层外部取状态栏高度：弹层内部会清零 padding.top
  final topPadding = MediaQuery.of(context).padding.top;
  return showAppBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => TopicTimelineSheet(
      infoSource: infoSource,
      currentIndex: currentIndex,
      onJumpToIndex: onJumpToIndex,
      title: title,
      topPadding: topPadding,
    ),
  );
}
