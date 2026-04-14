import 'dart:async';

import 'package:flutter/material.dart';
import 'package:popover/popover.dart';

import '../../../models/topic.dart';
import '../../../utils/emoji_shortcodes.dart';
import 'boost_bubble.dart';
import 'boost_content.dart';

/// Boost 气泡列表
class BoostList extends StatefulWidget {
  final List<Boost> boosts;
  final bool canBoost;
  final VoidCallback? onAddBoost;
  final void Function(Boost boost)? onBoostTap;
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
      widget.onBoostTap?.call(group.boosts.first);
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
            onBoostTap: (boost) {
              Navigator.of(popoverContext).pop();
              widget.onBoostTap?.call(boost);
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

  _WrapEntry _buildGroupEntry(BuildContext context, BoostGroup group) {
    final isHighlighted = _groupContainsHighlight(group);

    if (group.count == 1) {
      final boost = group.boosts.first;
      Widget bubble = BoostBubble(
        boost: boost,
        onTap: widget.onBoostTap == null ? null : () => widget.onBoostTap!(boost),
        onLongPress: widget.onBoostTap == null ? null : () => widget.onBoostTap!(boost),
      );
      if (isHighlighted) {
        bubble = _wrapHighlight(bubble);
      }
      return _WrapEntry(
        width: _estimateSingleBubbleWidth(context, group.displayText),
        child: bubble,
      );
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
    return _WrapEntry(
      width: _estimateGroupedBubbleWidth(context, group),
      child: bubble,
    );
  }

  _WrapEntry _buildToggleEntry(BuildContext context, bool expanded) {
    return _WrapEntry(
      width: _estimateControlChipWidth(),
      child: _InlineControlChip(
        icon: expanded ? Icons.chevron_left : Icons.chevron_right,
        onTap: _toggleRows,
      ),
    );
  }

  _WrapEntry _buildAddEntry(BuildContext context) {
    final theme = Theme.of(context);
    return _WrapEntry(
      width: 30,
      child: Tooltip(
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
              Icons.rocket_launch_outlined,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  int _computeWrapLineCount(List<double> widths, double maxWidth) {
    if (widths.isEmpty) {
      return 0;
    }

    var lines = 1;
    var currentLineWidth = 0.0;

    for (final rawWidth in widths) {
      final width = rawWidth.clamp(0.0, maxWidth);
      final nextLineWidth =
          currentLineWidth == 0 ? width : currentLineWidth + _chipSpacing + width;

      if (nextLineWidth <= maxWidth + 0.1) {
        currentLineWidth = nextLineWidth;
      } else {
        lines += 1;
        currentLineWidth = width;
      }
    }

    return lines;
  }

  int _maxPrefixThatFits(
    List<_WrapEntry> entries,
    List<_WrapEntry> trailingEntries,
    double maxWidth,
  ) {
    var low = 0;
    var high = entries.length;

    while (low < high) {
      final mid = (low + high + 1) >> 1;
      final widths = [
        ...entries.take(mid).map((entry) => entry.width),
        ...trailingEntries.map((entry) => entry.width),
      ];
      final lines = _computeWrapLineCount(widths, maxWidth);
      if (lines <= _collapsedMaxLines) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }

    return low;
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
    final labelStyle = theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700);
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

  double _estimateControlChipWidth() {
    return _controlChipWidth;
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
    final painter = TextPainter(
      text: TextSpan(text: text.isEmpty ? 'Boost' : text, style: style),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();

    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    final groups = groupBoostsByContent(widget.boosts);
    final groupEntries = groups.map((group) => _buildGroupEntry(context, group)).toList();
    final addEntry = widget.canBoost ? _buildAddEntry(context) : null;

    if (groupEntries.isEmpty && addEntry == null) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final baseEntries = [
          ...groupEntries,
          ...?(addEntry == null ? null : [addEntry]),
        ];
        final hasOverflow =
            _computeWrapLineCount(baseEntries.map((entry) => entry.width).toList(), maxWidth) >
                _collapsedMaxLines;

        final visibleEntries = <_WrapEntry>[];

        if (_showAllRows || !hasOverflow) {
          visibleEntries.addAll(groupEntries);
          if (hasOverflow) {
            visibleEntries.add(_buildToggleEntry(context, true));
          }
          if (addEntry != null) {
            visibleEntries.add(addEntry);
          }
        } else {
          final trailingEntries = <_WrapEntry>[
            _buildToggleEntry(context, false),
            ...?(addEntry == null ? null : [addEntry]),
          ];
          final prefix = _maxPrefixThatFits(groupEntries, trailingEntries, maxWidth);
          visibleEntries.addAll(groupEntries.take(prefix));
          visibleEntries.addAll(trailingEntries);
        }

        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: _chipSpacing,
            runSpacing: _chipSpacing,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: visibleEntries.map((entry) => entry.child).toList(growable: false),
          ),
        );
      },
    );
  }
}

class _WrapEntry {
  final Widget child;
  final double width;

  const _WrapEntry({
    required this.child,
    required this.width,
  });
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
      label: icon == Icons.chevron_left ? '收起' : '展开',
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
  final void Function(Boost boost)? onBoostTap;

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
                  onTap: onBoostTap == null ? null : () => onBoostTap!(boost),
                  onLongPress: onBoostTap == null ? null : () => onBoostTap!(boost),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
