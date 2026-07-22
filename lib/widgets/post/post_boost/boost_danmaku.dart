import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../models/topic.dart';
import '../../../utils/url_helper.dart';
import '../../common/emoji_text.dart';
import '../../common/smart_avatar.dart';
import 'boost_content.dart';

typedef BoostDanmakuTapCallback = void Function(Boost boost, Rect? anchorRect);

Rect? _globalRectOf(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return null;
  }
  final topLeft = renderObject.localToGlobal(Offset.zero);
  return topLeft & renderObject.size;
}

/// Boost 弹幕：多轨道，从右往左飘，视频弹幕样式（透明背景 + 白字描边）。
///
/// 用法：作为 Stack 内的子级叠加到帖子内容上方。
/// 仅当帖子进入可视区域时才驱动动画。
class BoostDanmaku extends StatefulWidget {
  final Object? visibilityKey;
  final List<Boost> boosts;
  final BoostDanmakuTapCallback? onBoostTap;

  /// 滚动速度（px/秒）
  final double pixelsPerSecond;

  /// 单条之间发射间隔（秒）
  final double launchIntervalSeconds;

  /// 单条之间发射间隔抖动（秒）
  final double launchIntervalJitterSeconds;

  /// 最大轨道数（实际轨道数会按可用高度自动收缩，至少 1 条）
  final int maxTrackCount;

  /// 轨道高度
  final double trackHeight;

  /// 高亮指定用户名的 boost
  final String? highlightUsername;

  const BoostDanmaku({
    super.key,
    required this.visibilityKey,
    required this.boosts,
    this.onBoostTap,
    this.pixelsPerSecond = 60,
    this.launchIntervalSeconds = 1.4,
    this.launchIntervalJitterSeconds = 0.7,
    this.maxTrackCount = 3,
    this.trackHeight = 36,
    this.highlightUsername,
  });

  @override
  State<BoostDanmaku> createState() => _BoostDanmakuState();
}

class _BoostDanmakuState extends State<BoostDanmaku>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;

  final List<_FlyingDanmaku> _flying = [];

  /// 待发射队列(groupingKey,FIFO)。此前是 _nextGroupIndex 单调指针,
  /// 隐含"组只会追加"假设 —— 新 boost 内容与已放完的组相同时组数不变、
  /// 指针已到末尾,永远不再发射。改为队列后按"含未见过的 boost"补队。
  final List<String> _pendingKeys = [];

  /// 已进过队的 boost id:didUpdateWidget 时凭差集识别新到的 boost,
  /// 把它所在的组(含合入已有组的情况)重新补进发射队列。
  final Set<int> _seenBoostIds = {};

  double _secondsUntilNextLaunch = 0;
  late List<double> _trackLastRightEdge;
  double _viewportWidth = 0;
  int _trackCount = 1;

  /// 初值 false:等 VisibilityDetector 首报可见才启动 Ticker。
  /// 此前 initState 即 start、dispose 才停,_visible 只让回调早退 ——
  /// Ticker 常驻 = 只要弹幕帖挂载(含 cacheExtent 预取区)整个 app 就
  /// 永不空闲;且全部放完后(发完即止)每帧 setState 空转永不停。
  bool _visible = false;

  final math.Random _rng = math.Random();

  late List<BoostGroup> _groups;
  Map<String, BoostGroup> _groupsByKey = const {};

  @override
  void initState() {
    super.initState();
    _rebuildGroups();
    _pendingKeys.addAll(_groups.map((g) => g.groupingKey));
    _trackCount = widget.maxTrackCount.clamp(1, widget.maxTrackCount);
    _trackLastRightEdge = List.filled(_trackCount, -double.infinity);
    _ticker = Ticker(_onTick);
  }

  void _rebuildGroups() {
    _groups = groupBoostsByContent(widget.boosts);
    _groupsByKey = {for (final g in _groups) g.groupingKey: g};
    _seenBoostIds.addAll(widget.boosts.map((b) => b.id));
  }

  @override
  void didUpdateWidget(covariant BoostDanmaku oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.boosts != widget.boosts) {
      final newIds = widget.boosts
          .map((b) => b.id)
          .where((id) => !_seenBoostIds.contains(id))
          .toSet();
      _rebuildGroups();
      // 组已消失(boost 被删)的排队项出队
      _pendingKeys.removeWhere((key) => !_groupsByKey.containsKey(key));
      // 含新 boost 的组补进队列:全新组、和"新 boost 合入已放完的组"
      // 都会重飞一次(展示最新 ×count)
      for (final group in _groups) {
        if (_pendingKeys.contains(group.groupingKey)) continue;
        if (group.boosts.any((b) => newIds.contains(b.id))) {
          _pendingKeys.add(group.groupingKey);
        }
      }
      _ensureTicker(); // 新 boost 到达:停表状态下重新起飞
    }
  }

  /// Ticker 生命周期唯一裁决点:可见 且 还有活(飞行中/待发射)才跑。
  void _ensureTicker() {
    final hasWork = _flying.isNotEmpty || _pendingKeys.isNotEmpty;
    final shouldRun = _visible && _groups.isNotEmpty && hasWork;
    if (shouldRun && !_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final delta = elapsed - _lastElapsed;
    _lastElapsed = elapsed;
    if (!_visible || _groups.isEmpty || _viewportWidth <= 0) {
      return;
    }
    final dt = delta.inMicroseconds / Duration.microsecondsPerSecond;
    if (dt <= 0) return;

    setState(() {
      for (final item in _flying) {
        item.x -= widget.pixelsPerSecond * dt;
      }
      _flying.removeWhere((item) => item.x + item.width < -8);

      for (var t = 0; t < _trackCount; t++) {
        _trackLastRightEdge[t] = -double.infinity;
      }
      for (final item in _flying) {
        if (item.track >= _trackCount) continue;
        final right = item.x + item.width;
        if (right > _trackLastRightEdge[item.track]) {
          _trackLastRightEdge[item.track] = right;
        }
      }

      // 队列非空才安排下一次发射；发完即止，不循环。
      if (_pendingKeys.isNotEmpty) {
        _secondsUntilNextLaunch -= dt;
        if (_secondsUntilNextLaunch <= 0) {
          _tryLaunchNext();
          final jitter =
              (_rng.nextDouble() * 2 - 1) * widget.launchIntervalJitterSeconds;
          _secondsUntilNextLaunch = math.max(
            0.3,
            widget.launchIntervalSeconds + jitter,
          );
        }
      }
    });

    // 全部放完且飞尽:停表。此前这里每帧 setState 空转到 dispose;
    // 重新可见(重置一轮)或新 boost 到达时由 _ensureTicker 再启。
    if (_flying.isEmpty && _pendingKeys.isEmpty) {
      _ticker.stop();
    }
  }

  void _tryLaunchNext() {
    if (_pendingKeys.isEmpty) return;
    var bestTrack = -1;
    var bestRight = double.infinity;
    for (var i = 0; i < _trackCount; i++) {
      if (_trackLastRightEdge[i] < bestRight) {
        bestRight = _trackLastRightEdge[i];
        bestTrack = i;
      }
    }
    if (bestTrack == -1) return;
    if (bestRight > _viewportWidth - 24) return;

    final group = _groupsByKey[_pendingKeys.removeAt(0)];
    if (group == null) return;
    final isHighlighted =
        widget.highlightUsername != null &&
        group.boosts.any((b) => b.user.username == widget.highlightUsername);

    _flying.add(
      _FlyingDanmaku(
        group: group,
        track: bestTrack,
        x: _viewportWidth,
        width: 0,
        isHighlighted: isHighlighted,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_groups.isEmpty) {
      return const SizedBox.shrink();
    }

    return VisibilityDetector(
      key: ValueKey('boost_danmaku_${widget.visibilityKey}'),
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0;
        if (visible != _visible) {
          _visible = visible;
          // 从不可见 → 可见且当前没有飞行中的弹幕时，重置一轮
          if (visible && _flying.isEmpty) {
            _pendingKeys
              ..clear()
              ..addAll(_groups.map((g) => g.groupingKey));
            _secondsUntilNextLaunch = 0;
          }
          _ensureTicker();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          _viewportWidth = constraints.maxWidth;
          // 按可用高度自适应轨道数（至少 1 条，不超过 maxTrackCount）
          final maxByHeight = constraints.maxHeight.isFinite
              ? (constraints.maxHeight / widget.trackHeight).floor()
              : widget.maxTrackCount;
          final newTrackCount = maxByHeight
              .clamp(1, widget.maxTrackCount)
              .toInt();
          if (newTrackCount != _trackCount) {
            _trackCount = newTrackCount;
            _trackLastRightEdge = List.filled(_trackCount, -double.infinity);
          }
          final height = widget.trackHeight * _trackCount;
          return Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: _viewportWidth,
              height: height,
              // RepaintBoundary 隔离 Ticker 每帧 setState 触发的重绘,
              // 避免弹幕飞行连累整个 post item 重绘。
              child: RepaintBoundary(
                child: ClipRect(
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      for (final item in _flying)
                        Positioned(
                          key: ObjectKey(item),
                          left: item.x,
                          top: item.track * widget.trackHeight,
                          // 不设固定 height —— 让弹幕条按内容自适应，避免阴影/头像被裁
                          child: _DanmakuItem(
                            item: item,
                            trackHeight: widget.trackHeight,
                            onTap: widget.onBoostTap == null
                                ? null
                                : (itemContext) => widget.onBoostTap!(
                                    item.group.boosts.first,
                                    _globalRectOf(itemContext),
                                  ),
                            onSize: (size) {
                              if ((size.width - item.width).abs() > 0.5) {
                                item.width = size.width;
                              }
                            },
                          ),
                        ),
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

class _FlyingDanmaku {
  final BoostGroup group;
  final int track;
  double x;
  double width;
  final bool isHighlighted;

  _FlyingDanmaku({
    required this.group,
    required this.track,
    required this.x,
    required this.width,
    required this.isHighlighted,
  });
}

class _DanmakuItem extends StatefulWidget {
  final _FlyingDanmaku item;
  final double trackHeight;
  final ValueChanged<BuildContext>? onTap;
  final ValueChanged<Size> onSize;

  const _DanmakuItem({
    required this.item,
    required this.trackHeight,
    required this.onTap,
    required this.onSize,
  });

  @override
  State<_DanmakuItem> createState() => _DanmakuItemState();
}

class _DanmakuItemState extends State<_DanmakuItem> {
  final GlobalKey _key = GlobalKey();

  void _report(_) {
    final ctx = _key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    widget.onSize(box.size);
  }

  void _handleTap() {
    final itemContext = _key.currentContext ?? context;
    widget.onTap?.call(itemContext);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(_report);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final group = widget.item.group;
    final parsed = BoostContentParser.parse(group.boosts.first.cooked);
    final displayText =
        (group.displayText.isNotEmpty ? group.displayText : parsed.displayText)
            .trim();
    final fallbackText = displayText.isEmpty ? 'Boost' : displayText;

    // 视频弹幕风格：白字 + 深色描边 / 暗色模式 = 浅描边
    final textColor = isDark ? Colors.white : Colors.white;
    final strokeColor = isDark
        ? Colors.black.withValues(alpha: 0.85)
        : Colors.black.withValues(alpha: 0.7);
    final highlightColor = theme.colorScheme.primary;

    final baseStyle = TextStyle(
      fontSize: 14,
      height: 1.0,
      fontWeight: FontWeight.w600,
      color: widget.item.isHighlighted ? highlightColor : textColor,
      shadows: [
        // 四向 0.8px 描边 + 一层轻投影，保证在亮色背景也清晰可读
        Shadow(
          color: strokeColor,
          blurRadius: 0,
          offset: const Offset(-0.8, 0),
        ),
        Shadow(color: strokeColor, blurRadius: 0, offset: const Offset(0.8, 0)),
        Shadow(
          color: strokeColor,
          blurRadius: 0,
          offset: const Offset(0, -0.8),
        ),
        Shadow(color: strokeColor, blurRadius: 0, offset: const Offset(0, 0.8)),
        Shadow(color: strokeColor, blurRadius: 1.5),
      ],
    );

    final users = _uniqueUsers(group.boosts);
    final showCount = group.count > 1;

    return SizedBox(
      height: widget.trackHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: KeyedSubtree(
          key: _key,
          child: GestureDetector(
            onTap: widget.onTap == null ? null : _handleTap,
            onLongPress: widget.onTap == null ? null : _handleTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _AvatarStrip(
                    users: users,
                    isHighlighted: widget.item.isHighlighted,
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: EmojiText(
                      fallbackText,
                      style: baseStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (showCount) ...[
                    const SizedBox(width: 4),
                    Text(
                      '×${group.count}',
                      style: baseStyle.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: widget.item.isHighlighted
                            ? highlightColor
                            : Colors.amber.shade300,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<BoostUser> _uniqueUsers(List<Boost> boosts) {
    final byId = <int, BoostUser>{};
    for (final b in boosts) {
      byId.putIfAbsent(b.user.id, () => b.user);
    }
    return byId.values.toList(growable: false);
  }
}

/// 头像条：单个 boost 显示单头像；多人 group 显示堆叠两/三头像。
class _AvatarStrip extends StatelessWidget {
  final List<BoostUser> users;
  final bool isHighlighted;

  const _AvatarStrip({required this.users, required this.isHighlighted});

  @override
  Widget build(BuildContext context) {
    final visible = users.take(3).toList(growable: false);
    final theme = Theme.of(context);
    const size = 18.0;
    const overlap = 10.0;
    final totalWidth = visible.isEmpty
        ? 0.0
        : size + (visible.length - 1) * overlap;

    final borderColor = isHighlighted
        ? theme.colorScheme.primary
        : Colors.white.withValues(alpha: 0.9);

    return SizedBox(
      width: totalWidth,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < visible.length; i++)
            Positioned(
              left: i * overlap,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: borderColor, width: 1.2),
                  boxShadow: const [
                    BoxShadow(color: Color(0x66000000), blurRadius: 2),
                  ],
                ),
                child: SmartAvatar(
                  imageUrl: visible[i].avatarTemplate.isNotEmpty
                      ? UrlHelper.resolveUrlWithCdn(
                          visible[i].avatarTemplate.replaceAll('{size}', '48'),
                        )
                      : null,
                  radius: size / 2,
                  fallbackText: visible[i].username,
                  backgroundColor: const Color(0x33FFFFFF),
                  foregroundColor: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 弹幕图标（Material Icons 没有合适的弹幕图形，自绘）。
/// [off] 为 true 时叠加一条关闭斜杠。
class DanmakuIcon extends StatelessWidget {
  final Color color;
  final bool off;
  final double size;

  const DanmakuIcon({
    super.key,
    required this.color,
    this.off = false,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DanmakuIconPainter(color: color, off: off),
      ),
    );
  }
}

class _DanmakuIconPainter extends CustomPainter {
  final Color color;
  final bool off;
  _DanmakuIconPainter({required this.color, required this.off});

  @override
  void paint(Canvas canvas, Size size) {
    // 居中绘制一个 18x18 的弹幕屏图标
    const double iconSize = 18;
    final dx = (size.width - iconSize) / 2;
    final dy = (size.height - iconSize) / 2;
    canvas.save();
    canvas.translate(dx, dy);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 弹幕屏外框
    final rrect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(1.2, 3.6, iconSize - 2.4, iconSize - 7.2),
      const Radius.circular(3.2),
    );
    canvas.drawRRect(rrect, stroke);

    // 两条弹幕线
    canvas.drawLine(const Offset(3.6, 7.6), const Offset(11.2, 7.6), stroke);
    canvas.drawLine(const Offset(5.2, 11.0), const Offset(13.0, 11.0), stroke);

    if (off) {
      // 关闭斜杠（左下→右上）
      canvas.drawLine(
        const Offset(1.5, iconSize - 1.5),
        const Offset(iconSize - 1.5, 1.5),
        stroke,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DanmakuIconPainter old) =>
      old.color != color || old.off != off;
}
