import 'dart:async';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:popover/popover.dart';

import '../../../models/topic.dart';
import '../../../utils/emoji_shortcodes.dart';
import 'boost_bubble.dart';
import 'boost_content.dart';

typedef BoostTapCallback = void Function(Boost boost, Rect? anchorRect);

Rect? _globalRectOf(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return null;
  }
  final topLeft = renderObject.localToGlobal(Offset.zero);
  return topLeft & renderObject.size;
}

/// Boost 气泡列表
class BoostList extends StatefulWidget {
  final List<Boost> boosts;
  final bool canBoost;
  final VoidCallback? onAddBoost;
  final BoostTapCallback? onBoostTap;
  /// 高亮指定用户的 boost（自动展开并滚动到位）
  final String? highlightUsername;

  const BoostList({
    super.key,
    required this.boosts,
    required this.canBoost,
    this.onAddBoost,
    this.onBoostTap,
    this.highlightUsername,
  });

  @override
  State<BoostList> createState() => _BoostListState();
}

class _BoostListState extends State<BoostList> with SingleTickerProviderStateMixin {
  static const int _collapsedMaxLines = 2;
  static const double _chipSpacing = 6;
  static const double _controlChipWidth = 28;

  bool _showAllRows = false;
  String? _activeGroupKey;
  BuildContext? _activePopoverContext;
  late final AnimationController _highlightController;
  late final Animation<double> _highlightOpacity;
  final GlobalKey _highlightKey = GlobalKey();

  /// 文本宽度测量缓存:每个 chip 一次 TextPainter.layout 是 build 的
  /// 大头(热帖上百个 boost 单次 build 实测 22ms)。缓存键已含
  /// fontSize|fontWeight|text,主题/字号变化天然换键;唯一进入测量而
  /// 不进键的环境量是文字方向 —— 只在它变化时清。此前任何 inherited
  /// 变化(键盘弹出的 MediaQuery insets 等)都全清,清一次 = 重付一次。
  final Map<String, double> _textWidthCache = {};
  TextDirection? _measureDirection;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final direction = Directionality.of(context);
    if (direction != _measureDirection) {
      _measureDirection = direction;
      _textWidthCache.clear();
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.highlightUsername != null) {
      _showAllRows = true;
    }
    _highlightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _highlightOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _highlightController,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );
    if (widget.highlightUsername != null) {
      _highlightController.forward();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToHighlightedBoost();
      });
    }
  }

  void _scrollToHighlightedBoost() {
    final ctx = _highlightKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
  }

  @override
  void didUpdateWidget(covariant BoostList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activeGroupKey = _activeGroupKey;
    if (activeGroupKey == null) {
      return;
    }

    final oldGroup = _findGroupByKey(groupBoostsByContent(oldWidget.boosts), activeGroupKey);
    final newGroup = _findGroupByKey(groupBoostsByContent(widget.boosts), activeGroupKey);
    final shouldClosePopover = newGroup == null ||
        (oldGroup != null &&
            _groupSignature(oldGroup) != _groupSignature(newGroup));

    if (shouldClosePopover) {
      _closeActivePopover();
      _activeGroupKey = null;
    }
  }

  BoostGroup? _findGroupByKey(List<BoostGroup> groups, String groupingKey) {
    for (final group in groups) {
      if (group.groupingKey == groupingKey) {
        return group;
      }
    }
    return null;
  }

  String _groupSignature(BoostGroup group) {
    final ids = group.boosts.map((boost) => boost.id).join(',');
    return '${group.groupingKey}|$ids';
  }

  @override
  void dispose() {
    _highlightController.dispose();
    _activePopoverContext = null;
    super.dispose();
  }

  void _closeActivePopover() {
    final popoverContext = _activePopoverContext;
    if (popoverContext == null) {
      return;
    }

    _activePopoverContext = null;
    try {
      Navigator.of(popoverContext).pop();
    } catch (_) {}
  }

  void _toggleRows() {
    if (_showAllRows) {
      _closeActivePopover();
      setState(() {
        _showAllRows = false;
        _activeGroupKey = null;
      });
      return;
    }

    setState(() {
      _showAllRows = true;
    });
  }

  Future<void> _toggleGroupPopover(
    BuildContext anchorContext,
    BoostGroup group,
  ) async {
    if (group.count <= 1) {
      widget.onBoostTap?.call(group.boosts.first, _globalRectOf(anchorContext));
      return;
    }

    if (_activeGroupKey == group.groupingKey && _activePopoverContext != null) {
      _closeActivePopover();
      if (mounted) {
        setState(() => _activeGroupKey = null);
      }
      return;
    }

    _closeActivePopover();

    if (mounted) {
      setState(() {
        _activeGroupKey = group.groupingKey;
      });
    }

    final theme = Theme.of(anchorContext);

    try {
      await showPopover(
        context: anchorContext,
        bodyBuilder: (popoverContext) {
          _activePopoverContext = popoverContext;
          return _BoostPopoverContent(
            boosts: group.boosts,
            onBoostTap: (boost, anchorRect) {
              Navigator.of(popoverContext).pop();
              widget.onBoostTap?.call(boost, anchorRect);
            },
          );
        },
        direction: PopoverDirection.bottom,
        arrowHeight: 8,
        arrowWidth: 12,
        backgroundColor: theme.colorScheme.surface,
        barrierColor: Colors.transparent,
        radius: 8,
        shadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      );
    } finally {
      if (mounted) {
        setState(() {
          if (_activeGroupKey == group.groupingKey) {
            _activeGroupKey = null;
          }
          _activePopoverContext = null;
        });
      } else {
        _activePopoverContext = null;
      }
    }
  }

  bool _groupContainsHighlight(BoostGroup group) {
    final username = widget.highlightUsername;
    if (username == null) return false;
    return group.boosts.any((b) => b.user.username == username);
  }

  Widget _wrapHighlight(Widget child) {
    return AnimatedBuilder(
      animation: _highlightOpacity,
      builder: (context, child) {
        final theme = Theme.of(context);
        return DecoratedBox(
          key: _highlightKey,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.primary.withValues(
                  alpha: 0.5 * _highlightOpacity.value,
                ),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
          child: child,
        );
      },
      child: child,
    );
  }

  /// 计算 group chip 的估算宽度(纯测量,不构建 widget)
  double _groupWidth(BuildContext context, BoostGroup group) {
    return group.count == 1
        ? _estimateSingleBubbleWidth(context, group.displayText)
        : _estimateGroupedBubbleWidth(context, group);
  }

  /// 构建 group chip 的 bubble(纯构建,不测量)
  Widget _buildGroupBubble(BuildContext context, BoostGroup group) {
    final isHighlighted = _groupContainsHighlight(group);

    if (group.count == 1) {
      final boost = group.boosts.first;
      Widget bubble = BoostBubble(
        boost: boost,
        onTapWithContext: widget.onBoostTap == null
            ? null
            : (bubbleContext) =>
                widget.onBoostTap!(boost, _globalRectOf(bubbleContext)),
        onLongPressWithContext: widget.onBoostTap == null
            ? null
            : (bubbleContext) =>
                widget.onBoostTap!(boost, _globalRectOf(bubbleContext)),
      );
      if (isHighlighted) {
        bubble = _wrapHighlight(bubble);
      }
      return bubble;
    }

    Widget bubble = BoostBubble.group(
      group: group,
      expanded: _activeGroupKey == group.groupingKey,
      onTapWithContext: (anchorContext) {
        unawaited(_toggleGroupPopover(anchorContext, group));
      },
      onLongPressWithContext: (anchorContext) {
        unawaited(_toggleGroupPopover(anchorContext, group));
      },
    );
    if (isHighlighted) {
      bubble = _wrapHighlight(bubble);
    }
    return bubble;
  }

  Widget _buildToggleChip(bool expanded) {
    return _InlineControlChip(
      icon: expanded
          ? Symbols.chevron_left_rounded
          : Symbols.chevron_right_rounded,
      onTap: _toggleRows,
    );
  }

  Widget _buildAddButton(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: 'Boost',
      child: GestureDetector(
        onTap: widget.onAddBoost,
        child: Container(
          height: 28,
          width: 28,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Symbols.rocket_launch_rounded,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  double _estimateSingleBubbleWidth(BuildContext context, String displayText) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(height: 1.2);
    final textWidth = _measureDisplayTextWidth(
      context,
      displayText,
      style,
    ).clamp(0.0, 220.0);
    return 3 + 6 + 20 + 4 + textWidth;
  }

  double _estimateGroupedBubbleWidth(BuildContext context, BoostGroup group) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(height: 1.2);
    final labelStyle = theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600);
    final textWidth = _measureDisplayTextWidth(
      context,
      group.displayText,
      style,
    ).clamp(0.0, 180.0);
    final countWidth = _measureRawTextWidth(
      context,
      '${group.count}',
      labelStyle,
    );
    final avatarWidth = _estimateAvatarStackWidth(group);
    // 3+6 (bubble padding) + avatarWidth + 4 (avatar-text spacing) + textWidth 
    // + 6 (spacing) + countWidth + 12 (pill padding) + 4 (spacing) + 14 (arrow)
    return 3 + 6 + avatarWidth + 4 + textWidth + 6 + countWidth + 12 + 4 + 14;
  }

  double _estimateAvatarStackWidth(BoostGroup group) {
    final userCount = group.boosts.map((boost) => boost.user.id).toSet().length.clamp(1, 3);
    return userCount == 1 ? 20.0 : 20.0 + (userCount - 1) * 12.0;
  }

  double _measureDisplayTextWidth(
    BuildContext context,
    String text,
    TextStyle? style,
  ) {
    final measurementText = text.replaceAllMapped(emojiShortcodeRegex, (_) => '◯');
    return _measureRawTextWidth(context, measurementText, style);
  }

  double _measureRawTextWidth(
    BuildContext context,
    String text,
    TextStyle? style,
  ) {
    final key = '${style?.fontSize}|${style?.fontWeight}|$text';
    final cached = _textWidthCache[key];
    if (cached != null) return cached;
    // 容量兜底:换键积累的旧条目(字号调整等)不无限涨
    if (_textWidthCache.length > 1024) _textWidthCache.clear();

    final painter = TextPainter(
      text: TextSpan(text: text.isEmpty ? 'Boost' : text, style: style),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return _textWidthCache[key] = width;
  }

  @override
  Widget build(BuildContext context) {
    final groups = groupBoostsByContent(widget.boosts);

    if (groups.isEmpty && !widget.canBoost) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;

        // 宽度惰性计算:折叠态只测量到装满 2 行为止,不为看不见的
        // chip 付出 TextPainter.layout 成本(热帖上百个 boost 时,
        // 全量测量 + 全量构建曾把单次 build 顶到 22ms)。
        final widths = List<double?>.filled(groups.length, null);
        double widthAt(int i) => widths[i] ??= _groupWidth(context, groups[i]);
        final double? addWidth = widget.canBoost ? 30.0 : null;

        // Wrap 行数增量累计:state = (行数, 当前行已占宽)
        (int, double) push((int, double) state, double rawWidth) {
          final width = rawWidth.clamp(0.0, maxWidth);
          final (lines, cur) = state;
          final next = cur == 0 ? width : cur + _chipSpacing + width;
          if (next <= maxWidth + 0.1) return (lines, next);
          return (lines + 1, width);
        }

        // 是否超过折叠行数:线性扫,一旦超出立即停止(后续不再测量)
        var probe = (1, 0.0);
        var hasOverflow = false;
        for (var i = 0; i < groups.length && !hasOverflow; i++) {
          probe = push(probe, widthAt(i));
          if (probe.$1 > _collapsedMaxLines) hasOverflow = true;
        }
        if (!hasOverflow && addWidth != null) {
          probe = push(probe, addWidth);
          if (probe.$1 > _collapsedMaxLines) hasOverflow = true;
        }

        final children = <Widget>[];
        if (_showAllRows || !hasOverflow) {
          for (final group in groups) {
            children.add(_buildGroupBubble(context, group));
          }
          if (hasOverflow) {
            children.add(_buildToggleChip(true));
          }
          if (addWidth != null) {
            children.add(_buildAddButton(context));
          }
        } else {
          // 折叠:线性找最大 prefix,使 prefix + 尾部控件仍 ≤ 折叠行数;
          // 只为进入 prefix 的 chip 构建 widget。
          final trailing = <double>[
            _controlChipWidth,
            ?addWidth,
          ];
          var prefix = 0;
          var state = (1, 0.0);
          while (prefix < groups.length) {
            final withNext = push(state, widthAt(prefix));
            var trial = withNext;
            for (final w in trailing) {
              trial = push(trial, w);
            }
            if (trial.$1 > _collapsedMaxLines) break;
            state = withNext;
            prefix++;
          }
          for (var i = 0; i < prefix; i++) {
            children.add(_buildGroupBubble(context, groups[i]));
          }
          children.add(_buildToggleChip(false));
          if (addWidth != null) {
            children.add(_buildAddButton(context));
          }
        }

        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: _chipSpacing,
            runSpacing: _chipSpacing,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
        );
      },
    );
  }
}

class _InlineControlChip extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _InlineControlChip({
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: icon == Symbols.chevron_left_rounded ? '收起' : '展开',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: _BoostListState._controlChipWidth,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            icon,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _BoostPopoverContent extends StatelessWidget {
  final List<Boost> boosts;
  final BoostTapCallback? onBoostTap;

  const _BoostPopoverContent({
    required this.boosts,
    this.onBoostTap,
  });

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: screenHeight * 0.3,
          maxWidth: (screenWidth * 0.88).clamp(0.0, 420.0),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final boost in boosts)
                BoostBubble(
                  boost: boost,
                  onTapWithContext: onBoostTap == null
                      ? null
                      : (bubbleContext) =>
                          onBoostTap!(boost, _globalRectOf(bubbleContext)),
                  onLongPressWithContext: onBoostTap == null
                      ? null
                      : (bubbleContext) =>
                          onBoostTap!(boost, _globalRectOf(bubbleContext)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
