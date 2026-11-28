part of 'metaverse_widget_library.dart';

class _PluginListPage extends StatefulWidget {
  const _PluginListPage({
    required this.items,
    required this.loading,
    required this.loadingMore,
    required this.hasMore,
    required this.error,
    this.emptyTitle,
    this.moreLabel,
    this.toolbar,
    this.search,
    this.header,
    this.footer,
    this.empty,
    this.loadingPlaceholder,
    this.onRefresh,
    this.onRetry,
    this.onLoadMore,
  });

  final List<Widget> items;
  final bool loading, loadingMore, hasMore;
  final String error;
  final String? emptyTitle, moreLabel;
  final Widget? toolbar, search, header, footer, empty, loadingPlaceholder;
  final VoidCallback? onRefresh, onRetry, onLoadMore;

  @override
  State<_PluginListPage> createState() => _PluginListPageState();
}

class _PluginListPageState extends State<_PluginListPage> {
  // RFW 的条件节点本身不是 SizedBox，必须按实际内容高度判断。
  // 保留隐藏节点的订阅，数据改变时它仍能重新显示；离屏条目继续懒加载。
  final _hidden = <int>{};

  @override
  void didUpdateWidget(_PluginListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _hidden.removeWhere((index) => index >= widget.items.length);
  }

  void _visibility(int index, bool visible) {
    if (!mounted ||
        index >= widget.items.length ||
        visible != _hidden.contains(index)) {
      return;
    }
    setState(() {
      if (visible) {
        _hidden.remove(index);
      } else {
        _hidden.add(index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.items.length - _hidden.length;
    var visibleIndex = 0;
    final rows = <Widget>[
      for (var index = 0; index < widget.items.length; index++)
        ClipRect(
          key: ValueKey(index),
          child: SegmentedCardItem(
            index: _hidden.contains(index) ? 0 : visibleIndex++,
            count: math.max(1, count),
            gap: _hidden.contains(index) ? 0 : 3,
            color: PageBackgroundScope.contentColor(
              context,
              Theme.of(context).colorScheme.surfaceContainerLow,
            ),
            child: _PluginOptionalPadding(
              padding: EdgeInsets.zero,
              onVisibility: (visible) => _visibility(index, visible),
              child: widget.items[index],
            ),
          ),
        ),
    ];
    return _PluginPageLayout(
      toolbar: widget.toolbar,
      footer: widget.footer,
      lazy: true,
      itemCount: count,
      loading: widget.loading,
      loadingMore: widget.loadingMore,
      hasMore: widget.hasMore,
      loadMoreError: widget.error,
      onLoadMore: count == 0 ? null : widget.onLoadMore,
      onRefresh: widget.onRefresh,
      children: [
        if (widget.search case final search?) ...[
          search,
          const SizedBox(height: 16),
        ],
        if (widget.header case final header?)
          _PluginOptionalPadding(
            padding: const EdgeInsets.only(bottom: 16),
            child: header,
          ),
        if (count == 0)
          (widget.loading
                  ? widget.loadingPlaceholder
                  : widget.error.isNotEmpty
                  ? null
                  : widget.empty) ??
              _PluginPageStatus(
                loading: widget.loading,
                error: widget.error,
                emptyTitle: widget.emptyTitle,
                onRetry: widget.onRetry,
              ),
        ...rows,
        if (count > 0 && widget.error.isNotEmpty)
          _PluginPageStatus(error: widget.error, onRetry: widget.onRetry),
        if (count > 0 && widget.onLoadMore != null)
          if (widget.hasMore && !widget.loadingMore)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton(
                onPressed: widget.loading ? null : widget.onLoadMore,
                child: Text(widget.moreLabel ?? context.l10n.common_more),
              ),
            )
          else
            PagedListFooter(
              hasMore: widget.hasMore,
              isLoadingMore: widget.loadingMore,
              isLoadMoreFailed: false,
              onRetry: widget.onLoadMore!,
            ),
      ],
    );
  }
}
