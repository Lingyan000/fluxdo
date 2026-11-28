part of 'metaverse_widget_library.dart';

/// 长网格按可见区域构建，等高按行测量，瀑布流按列复用 sliver 缓存。
Widget _buildGridPage(BuildContext context, DataSource source) {
  final items = source.childList(['items']);
  final loading = source.v<bool>(['loading']) == true;
  final loadingMore = source.v<bool>(['loadingMore']) == true;
  final hasMore = source.v<bool>(['hasMore']) == true;
  final error = source.v<String>(['error']) ?? '';
  final loadMore = source.voidHandler(['onLoadMore']);
  final retry = source.voidHandler(['onRetry']);
  final layout = ArgumentDecoders.enumValue(
    MetaverseTileGridLayout.values, source, ['layout'],
  ) ?? MetaverseTileGridLayout.natural;
  final settings = (
    layout: layout,
    columns: source.v<int>(['columns']) ?? 0,
    minTileWidth: _gridDimension(source, 'minTileWidth', 0),
    spacing: _gridDimension(source, 'spacing', 12),
    runSpacing: _gridDimension(source, 'runSpacing', 12),
    direction: Directionality.of(context),
  );
  return _PluginPageLayout(
    toolbar: source.optionalChild(['toolbar']),
    itemCount: items.length,
    loading: loading,
    loadingMore: loadingMore,
    hasMore: hasMore,
    loadMoreError: error,
    onLoadMore: items.isEmpty ? null : loadMore,
    onRefresh: source.voidHandler(['onRefresh']),
    footer: source.optionalChild(['actions']),
    slivers: [
      if (source.optionalChild(['header']) case final header?)
        SliverToBoxAdapter(child: _PluginOptionalPadding(
          padding: const EdgeInsets.only(bottom: 16), child: header,
        )),
      if (items.isEmpty)
        SliverToBoxAdapter(child: (loading ? source.optionalChild(['loadingPlaceholder']) : null) ?? _PluginPageStatus(
          loading: loading, error: error,
          emptyTitle: source.v<String>(['emptyTitle']), onRetry: retry,
        ))
      else
        SliverLayoutBuilder(builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final gap = settings.spacing.clamp(0.0, width);
          final columns = _gridColumns(settings, width, gap);
          if (layout == MetaverseTileGridLayout.masonry) {
            return SliverMasonryGrid.count(
              crossAxisCount: columns, crossAxisSpacing: gap,
              mainAxisSpacing: settings.runSpacing,
              childCount: items.length,
              itemBuilder: (_, index) => items[index],
            );
          }
          final rows = (items.length / columns).ceil();
          return SliverList.builder(
            itemCount: rows,
            itemBuilder: (_, row) => Padding(
              padding: EdgeInsets.only(bottom: row == rows - 1 ? 0 : settings.runSpacing),
              child: _PluginTileGrid(
                settings: (layout: layout, columns: columns,
                  minTileWidth: 0.0, spacing: gap, runSpacing: 0.0,
                  direction: settings.direction),
                children: items.sublist(row * columns, math.min((row + 1) * columns, items.length)),
              ),
            ),
          );
        }),
      if (items.isNotEmpty && error.isNotEmpty)
        SliverToBoxAdapter(child: _PluginPageStatus(error: error, onRetry: retry)),
      if (items.isNotEmpty && loadMore != null && error.isEmpty)
        SliverToBoxAdapter(child: hasMore && !loadingMore
          ? Padding(padding: const EdgeInsets.only(top: 12), child: Center(
              child: OutlinedButton(onPressed: loading ? null : loadMore,
                child: Text(source.v<String>(['moreLabel']) ?? context.l10n.common_more)),
            ))
          : PagedListFooter(hasMore: hasMore, isLoadingMore: loadingMore,
              isLoadMoreFailed: false, onRetry: loadMore)),
    ],
    children: const [],
  );
}
