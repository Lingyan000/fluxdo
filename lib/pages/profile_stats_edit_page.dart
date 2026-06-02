import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/profile_stats_config.dart';
import '../models/user.dart';
import '../models/connect_stats.dart';
import '../providers/core_providers.dart';
import '../providers/directory_providers.dart';
import '../providers/profile_stats_provider.dart';
import '../widgets/profile_stats_card.dart';
import '../widgets/common/loading_spinner.dart';
import '../l10n/s.dart';

/// 统计卡片编辑页
class ProfileStatsEditPage extends ConsumerStatefulWidget {
  const ProfileStatsEditPage({super.key});

  @override
  ConsumerState<ProfileStatsEditPage> createState() => _ProfileStatsEditPageState();
}

class _ProfileStatsEditPageState extends ConsumerState<ProfileStatsEditPage> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(profileStatsConfigProvider);
    final notifier = ref.read(profileStatsConfigProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(S.current.profileStats_editTitle),
        actions: [
          TextButton(
            onPressed: () => notifier.update(const ProfileStatsConfig()),
            child: Text(S.current.common_reset),
          ),
        ],
      ),
      body: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
        children: [
          // 预览（可拖拽排序）
          _PreviewSection(
            config: config,
            onReorder: notifier.reorderStats,
            scrollController: _scrollController,
          ),
          const SizedBox(height: 24),

          // 数据源
          _SectionHeader(title: S.current.profileStats_dataSource),
          const SizedBox(height: 8),
          _DataSourceSelector(config: config),
          const SizedBox(height: 24),

          // 统计项选择
          _SectionHeader(
            title: S.current.profileStats_selectItems,
            trailing: Text(
              '${config.enabledStats.length}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(height: 8),
          _StatChipGrid(config: config),
          const SizedBox(height: 24),

          // 布局设置
          _SectionHeader(title: S.current.profileStats_layoutSettings),
          const SizedBox(height: 8),
          _LayoutSettings(config: config),
        ],
      ),
    );
  }
}

/// 区块标题
class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const _SectionHeader({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          )),
          if (trailing != null) ...[const Spacer(), trailing!],
        ],
      ),
    );
  }
}

/// 预览区域（带防抖 + 拖拽排序支持）
class _PreviewSection extends ConsumerStatefulWidget {
  final ProfileStatsConfig config;
  final void Function(int oldIndex, int newIndex)? onReorder;
  final ScrollController? scrollController;
  const _PreviewSection({required this.config, this.onReorder, this.scrollController});

  @override
  ConsumerState<_PreviewSection> createState() => _PreviewSectionState();
}

class _PreviewSectionState extends ConsumerState<_PreviewSection> {
  late StatsDataSource _effectiveSource;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _effectiveSource = widget.config.dataSource;
  }

  @override
  void didUpdateWidget(_PreviewSection old) {
    super.didUpdateWidget(old);
    if (old.config.dataSource != widget.config.dataSource) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _effectiveSource = widget.config.dataSource);
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayConfig = widget.config.copyWith(dataSource: _effectiveSource);
    final providerState = _watchSourceState(ref);
    final isLoading = providerState.isLoading && !providerState.hasValue;
    final hasError = providerState.hasError && !providerState.hasValue;

    return Stack(
      children: [
        ProfileStatsCardPreview(
          config: widget.config,
          values: _resolveValues(ref, displayConfig),
          onReorder: widget.onReorder,
          scrollController: widget.scrollController,
        ),
        if (isLoading)
          const Positioned(right: 12, bottom: 8, child: LoadingSpinner(size: 16)),
        if (hasError)
          Positioned(
            right: 8, bottom: 6,
            child: Tooltip(
              message: S.current.profileStats_loadError,
              child: Icon(Icons.error_outline_rounded, size: 16,
                color: Theme.of(context).colorScheme.error.withValues(alpha: 0.6)),
            ),
          ),
      ],
    );
  }

  AsyncValue _watchSourceState(WidgetRef ref) {
    switch (_effectiveSource) {
      case StatsDataSource.summary:
        return ref.watch(userSummaryProvider);
      case StatsDataSource.connect:
        return ref.watch(connectStatsProvider);
    }
  }

  Map<ProfileStatType, int> _resolveValues(WidgetRef ref, ProfileStatsConfig config) {
    switch (config.dataSource) {
      case StatsDataSource.summary:
        return _fromSummary(ref.watch(userSummaryProvider).value);
      case StatsDataSource.connect:
        final c = ref.watch(connectStatsProvider).value;
        if (c != null) return _fromConnect(c);
        return _fromSummary(ref.watch(userSummaryProvider).value);
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

/// 数据源选择
class _DataSourceSelector extends ConsumerWidget {
  final ProfileStatsConfig config;
  const _DataSourceSelector({required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(profileStatsConfigProvider.notifier);
    return Row(
      children: [
        for (final source in StatsDataSource.values)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(getDataSourceLabel(source)),
              selected: config.dataSource == source,
              onSelected: (_) => notifier.setDataSource(source),
            ),
          ),
      ],
    );
  }
}

/// 统计项 Chip 网格（点击切换选中/取消，排序通过预览卡片拖拽）
class _StatChipGrid extends ConsumerWidget {
  final ProfileStatsConfig config;
  const _StatChipGrid({required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(profileStatsConfigProvider.notifier);
    final selected = config.enabledStats;
    final unselected = ProfileStatType.values
        .where((s) => !selected.contains(s))
        .toList();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final stat in selected)
          FilterChip(
            label: Text(getStatLabel(stat)),
            selected: true,
            onSelected: (_) => notifier.removeStat(stat),
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        for (final stat in unselected)
          FilterChip(
            label: Text(getStatLabel(stat)),
            selected: false,
            onSelected: !isStatCompatible(stat, config.dataSource)
                ? null
                : (_) => notifier.addStat(stat),
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            tooltip: !isStatCompatible(stat, config.dataSource)
                ? S.current.profileStats_incompatibleSource
                : null,
          ),
      ],
    );
  }
}

/// 布局设置
class _LayoutSettings extends ConsumerWidget {
  final ProfileStatsConfig config;
  const _LayoutSettings({required this.config});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(profileStatsConfigProvider.notifier);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _SettingRow(
              label: S.current.profileStats_layoutMode,
              child: SegmentedButton<StatsLayoutMode>(
                segments: [
                  ButtonSegment(
                    value: StatsLayoutMode.grid,
                    icon: const Icon(Icons.grid_view_rounded, size: 18),
                    label: Text(S.current.profileStats_layoutGrid),
                  ),
                  ButtonSegment(
                    value: StatsLayoutMode.scroll,
                    icon: const Icon(Icons.view_column_rounded, size: 18),
                    label: Text(S.current.profileStats_layoutScroll),
                  ),
                ],
                selected: {config.layoutMode},
                onSelectionChanged: (set) => notifier.setLayoutMode(set.first),
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelMedium,
                ),
              ),
            ),
            if (config.layoutMode == StatsLayoutMode.grid) ...[
              Divider(height: 24, thickness: 0.5,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3)),
              _SettingRow(
                label: S.current.profileStats_columnsPerRow,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 3, label: Text('3')),
                    ButtonSegment(value: 4, label: Text('4')),
                  ],
                  selected: {config.columnsPerRow},
                  onSelectionChanged: (set) => notifier.setColumnsPerRow(set.first),
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    textStyle: theme.textTheme.labelMedium,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final String label;
  final Widget child;
  const _SettingRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ))),
        child,
      ],
    );
  }
}
