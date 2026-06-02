import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/profile_stats_config.dart';
import '../models/user.dart';
import '../models/connect_stats.dart';
import '../providers/core_providers.dart';
import '../providers/directory_providers.dart';
import '../providers/profile_stats_provider.dart';
import '../utils/number_utils.dart';
import '../l10n/s.dart';
import 'common/loading_spinner.dart';

/// 统计卡片渲染组件（个人页使用）
///
/// [statsCardKey] 可选，外部传入 GlobalKey 用于引导高亮定位。
class ProfileStatsCard extends ConsumerWidget {
  final VoidCallback? onEdit;
  final GlobalKey? statsCardKey;

  const ProfileStatsCard({super.key, this.onEdit, this.statsCardKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(profileStatsConfigProvider);
    final theme = Theme.of(context);

    // 空状态：显示占位卡片，引导用户添加
    if (config.enabledStats.isEmpty) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          onTap: onEdit,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.add_chart_rounded,
                  size: 20,
                  color: theme.colorScheme.primary.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 8),
                Text(
                  S.current.profileStats_addItems,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary.withValues(alpha: 0.8),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return KeyedSubtree(
      key: statsCardKey,
      child: _StatsCardContent(
        config: config,
        onEdit: onEdit,
      ),
    );
  }
}

/// 预览用（不读取 provider 配置，直接传入数据）
/// [onReorder] 非空时启用拖拽排序
/// [scrollController] 非空时启用拖拽边缘自动滚动
class ProfileStatsCardPreview extends StatelessWidget {
  final ProfileStatsConfig config;
  final Map<ProfileStatType, int> values;
  final VoidCallback? onTap;
  final void Function(int oldIndex, int newIndex)? onReorder;
  final ScrollController? scrollController;

  const ProfileStatsCardPreview({
    super.key,
    required this.config,
    required this.values,
    this.onTap,
    this.onReorder,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    if (config.enabledStats.isEmpty) {
      return SizedBox(
        width: double.infinity,
        child: Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  S.current.profileStats_noItemsSelected,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            child: _buildLayout(context),
          ),
        ),
      ),
    );
  }

  Widget _buildLayout(BuildContext context) {
    final items = config.enabledStats.asMap().entries.map((e) {
      final stat = e.value;
      final value = values[stat] ?? 0;
      return _StatItemData(
        index: e.key,
        stat: stat,
        value: _formatValue(stat, value),
        label: getStatLabel(stat),
        rawValue: value,
        isTimeValue: stat == ProfileStatType.timeRead ||
            stat == ProfileStatType.recentTimeRead,
      );
    }).toList();

    if (config.layoutMode == StatsLayoutMode.scroll) {
      return _buildScrollLayout(context, items);
    }
    return _buildGridLayout(context, items);
  }

  Widget _buildGridLayout(BuildContext context, List<_StatItemData> items) {
    final columns = config.columnsPerRow;

    final List<List<_StatItemData>> rows = [];
    for (int i = 0; i < items.length; i += columns) {
      rows.add(items.sublist(i, (i + columns).clamp(0, items.length)));
    }

    return Column(
      children: [
        for (int r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 14),
          Row(
            children: [
              for (int c = 0; c < rows[r].length; c++)
                Expanded(child: _wrapDraggable(
                  context,
                  rows[r][c],
                  _buildStatItem(Theme.of(context), rows[r][c]),
                )),
              for (int c = rows[r].length; c < columns; c++)
                const Expanded(child: SizedBox()),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildScrollLayout(BuildContext context, List<_StatItemData> items) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < items.length; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 20),
              child: _wrapDraggable(
                context,
                items[i],
                _buildStatItem(theme, items[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _wrapDraggable(
    BuildContext context,
    _StatItemData item,
    Widget child,
  ) {
    if (onReorder == null) return child;
    return _DraggableStatItem(
      index: item.index,
      onReorder: onReorder!,
      scrollController: scrollController,
      child: child,
    );
  }

  Widget _buildStatItem(ThemeData theme, _StatItemData item) {
    return Tooltip(
      message: item.isTimeValue
          ? NumberUtils.formatDurationLong(item.rawValue)
          : '${item.rawValue}',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item.isTimeValue
                ? item.value
                : NumberUtils.formatCount(item.rawValue),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
            maxLines: 1,
          ),
          const SizedBox(height: 3),
          Text(
            item.label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  String _formatValue(ProfileStatType stat, int value) {
    if (stat == ProfileStatType.timeRead ||
        stat == ProfileStatType.recentTimeRead) {
      return NumberUtils.formatDuration(value);
    }
    return NumberUtils.formatCount(value);
  }
}

/// 内部：从 providers 获取数据的卡片内容
class _StatsCardContent extends ConsumerWidget {
  final ProfileStatsConfig config;
  final VoidCallback? onEdit;

  const _StatsCardContent({
    required this.config,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resolved = _resolve(ref);

    return Stack(
      children: [
        ProfileStatsCardPreview(
          config: config,
          values: resolved.values,
          onTap: onEdit,
        ),
        if (resolved.isLoading)
          const Positioned(
            right: 12,
            bottom: 8,
            child: LoadingSpinner(size: 16),
          ),
        if (resolved.hasError)
          Positioned(
            right: 8,
            bottom: 6,
            child: Tooltip(
              message: S.current.profileStats_loadError,
              child: Icon(
                Icons.error_outline_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.error.withValues(alpha: 0.6),
              ),
            ),
          ),
      ],
    );
  }

  /// 按需从不同数据源获取数据
  _ResolvedData _resolve(WidgetRef ref) {
    switch (config.dataSource) {
      case StatsDataSource.summary:
        final state = ref.watch(userSummaryProvider);
        return _ResolvedData(
          values: _fromSummary(state.value),
          isLoading: state.isLoading && !state.hasValue,
        );
      case StatsDataSource.connect:
        final state = ref.watch(connectStatsProvider);
        if (state.value != null) {
          return _ResolvedData(values: _fromConnect(state.value!));
        }
        if (state.isLoading) {
          return const _ResolvedData(isLoading: true);
        }
        if (state.hasError) {
          return _ResolvedData(
            values: _fromSummary(ref.watch(userSummaryProvider).value),
            hasError: true,
          );
        }
        return _ResolvedData(values: _fromSummary(ref.watch(userSummaryProvider).value));
    }
  }

  Map<ProfileStatType, int> _fromSummary(UserSummary? s) {
    if (s == null) return {};
    return {
      ProfileStatType.daysVisited: s.daysVisited,
      ProfileStatType.postsReadCount: s.postsReadCount,
      ProfileStatType.likesReceived: s.likesReceived,
      ProfileStatType.likesGiven: s.likesGiven,
      ProfileStatType.topicCount: s.topicCount,
      ProfileStatType.postCount: s.postCount,
      ProfileStatType.timeRead: s.timeRead,
      ProfileStatType.recentTimeRead: s.recentTimeRead,
      ProfileStatType.bookmarkCount: s.bookmarkCount,
      ProfileStatType.topicsEntered: s.topicsEntered,
    };
  }

  Map<ProfileStatType, int> _fromConnect(ConnectStats c) {
    return {
      ProfileStatType.daysVisited: c.daysVisited,
      ProfileStatType.postsReadCount: c.postsRead,
      ProfileStatType.likesReceived: c.likesReceived,
      ProfileStatType.likesGiven: c.likesGiven,
      ProfileStatType.topicsEntered: c.topicsViewed,
      ProfileStatType.topicsRepliedTo: c.topicsRepliedTo,
      ProfileStatType.likesReceivedDays: c.likesReceivedDays,
      ProfileStatType.likesReceivedUsers: c.likesReceivedUsers,
    };
  }
}

class _StatItemData {
  final int index;
  final ProfileStatType stat;
  final String value;
  final String label;
  final int rawValue;
  final bool isTimeValue;

  const _StatItemData({
    required this.index,
    required this.stat,
    required this.value,
    required this.label,
    required this.rawValue,
    this.isTimeValue = false,
  });
}

class _ResolvedData {
  final Map<ProfileStatType, int> values;
  final bool isLoading;
  final bool hasError;

  const _ResolvedData({
    this.values = const {},
    this.isLoading = false,
    this.hasError = false,
  });
}

/// 获取统计项的显示标签
String getStatLabel(ProfileStatType stat) {
  switch (stat) {
    case ProfileStatType.daysVisited:
      return S.current.profileStats_daysVisited;
    case ProfileStatType.postsReadCount:
      return S.current.profileStats_postsRead;
    case ProfileStatType.likesReceived:
      return S.current.profileStats_likesReceived;
    case ProfileStatType.likesGiven:
      return S.current.profileStats_likesGiven;
    case ProfileStatType.topicCount:
      return S.current.profileStats_topicCount;
    case ProfileStatType.postCount:
      return S.current.profileStats_postCount;
    case ProfileStatType.timeRead:
      return S.current.profileStats_timeRead;
    case ProfileStatType.recentTimeRead:
      return S.current.profileStats_recentTimeRead;
    case ProfileStatType.bookmarkCount:
      return S.current.profileStats_bookmarkCount;
    case ProfileStatType.topicsEntered:
      return S.current.profileStats_topicsEntered;
    case ProfileStatType.topicsRepliedTo:
      return S.current.profileStats_topicsRepliedTo;
    case ProfileStatType.likesReceivedDays:
      return S.current.profileStats_likesReceivedDays;
    case ProfileStatType.likesReceivedUsers:
      return S.current.profileStats_likesReceivedUsers;
  }
}

/// 获取数据源的显示标签
String getDataSourceLabel(StatsDataSource source) {
  switch (source) {
    case StatsDataSource.summary:
      return S.current.profileStats_sourceSummary;
    case StatsDataSource.connect:
      return S.current.profileStats_sourceConnect;
  }
}

/// 可拖拽的统计项（带边缘自动滚动）
class _DraggableStatItem extends StatefulWidget {
  final int index;
  final void Function(int oldIndex, int newIndex) onReorder;
  final ScrollController? scrollController;
  final Widget child;

  const _DraggableStatItem({
    required this.index,
    required this.onReorder,
    this.scrollController,
    required this.child,
  });

  @override
  State<_DraggableStatItem> createState() => _DraggableStatItemState();
}

class _DraggableStatItemState extends State<_DraggableStatItem> {
  Timer? _autoScrollTimer;
  double _scrollSpeed = 0;
  bool _isDragging = false;

  @override
  void dispose() {
    _stopAutoScroll();
    super.dispose();
  }

  ScrollableState? _nearestScrollable;

  void _onDragUpdate(DragUpdateDetails details) {
    // 找最近的 Scrollable（横向 SingleChildScrollView 或纵向 ListView）
    _nearestScrollable ??= Scrollable.maybeOf(context);
    final scrollable = _nearestScrollable;
    if (scrollable == null) return;

    final position = scrollable.position;
    final renderObj = scrollable.context.findRenderObject() as RenderBox?;
    if (renderObj == null || !renderObj.hasSize) return;

    final isHorizontal = scrollable.axisDirection == AxisDirection.left ||
        scrollable.axisDirection == AxisDirection.right;

    final viewportOrigin = renderObj.localToGlobal(Offset.zero);
    final dragPos = isHorizontal
        ? details.globalPosition.dx
        : details.globalPosition.dy;
    final viewportStart = isHorizontal ? viewportOrigin.dx : viewportOrigin.dy;
    final viewportSize = isHorizontal ? renderObj.size.width : renderObj.size.height;
    final viewportEnd = viewportStart + viewportSize;

    const edgeZone = 60.0;
    const maxSpeed = 10.0;

    if (dragPos < viewportStart + edgeZone) {
      final dist = (dragPos - viewportStart).clamp(0.0, edgeZone);
      _scrollSpeed = -maxSpeed * (1 - dist / edgeZone);
    } else if (dragPos > viewportEnd - edgeZone) {
      final dist = (viewportEnd - dragPos).clamp(0.0, edgeZone);
      _scrollSpeed = maxSpeed * (1 - dist / edgeZone);
    } else {
      _scrollSpeed = 0;
      _stopAutoScroll();
      return;
    }

    _autoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_scrollSpeed == 0) return;
      final newOffset = (position.pixels + _scrollSpeed)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      position.jumpTo(newOffset);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _scrollSpeed = 0;
    _nearestScrollable = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != widget.index,
      onAcceptWithDetails: (d) => widget.onReorder(d.data, widget.index),
      builder: (context, candidateData, _) {
        final isHovered = candidateData.isNotEmpty;

        return LongPressDraggable<int>(
          data: widget.index,
          delay: const Duration(milliseconds: 150),
          hapticFeedbackOnStart: true,
          onDragStarted: () => setState(() => _isDragging = true),
          onDragUpdate: _onDragUpdate,
          onDragEnd: (_) {
            _stopAutoScroll();
            setState(() => _isDragging = false);
          },
          onDraggableCanceled: (_, _) {
            _stopAutoScroll();
            setState(() => _isDragging = false);
          },
          feedback: Transform.scale(
            scale: 1.05,
            child: Material(
              elevation: 8,
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: DefaultTextStyle(
                style: theme.textTheme.bodyMedium!,
                child: widget.child,
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.15, child: widget.child),
          // 用固定尺寸的 decoration 避免抖动：始终有 border，hover 时变色
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: isHovered
                  ? theme.colorScheme.primary.withValues(alpha: 0.08)
                  : Colors.transparent,
            ),
            child: Opacity(
              opacity: _isDragging ? 0.15 : 1.0,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
