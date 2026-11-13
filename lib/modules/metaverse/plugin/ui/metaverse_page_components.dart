part of 'metaverse_widget_library.dart';

/// 页面级组件沿用公共页面外壳，数据与操作由插件传入。
Map<String, LocalWidgetBuilder> _pageWidgets() => {
  'FormPage': (context, source) {
    final fields = _readFormFields(source);
    if (fields == null) {
      return _PluginPageStatus(error: context.l10n.metaverse_formInvalidFields);
    }
    return _PluginFormPage(
      fields: fields,
      resetKey: source.v<String>(['resetKey']) ?? '',
      loading: source.v<bool>(['loading']) == true,
      submitLabel:
          source.v<String>(['submitLabel']) ??
          context.l10n.metaverse_formSubmit,
      header: source.optionalChild(['header']),
      actions: source.childList(['actions']),
      onChanged: source.handler(
        ['onChanged'],
        (trigger) =>
            (String field, Object? value) =>
                trigger({'field': field, 'value': value}),
      ),
      onSubmit: source.handler(
        ['onSubmit'],
        (trigger) =>
            (Map<String, Object?> values) => trigger({'values': values}),
      ),
    );
  },
  'ActionBar': (context, source) => OverflowBar(
    alignment: MainAxisAlignment.end,
    overflowAlignment: OverflowBarAlignment.end,
    spacing: 12,
    overflowSpacing: 8,
    children: source.childList(['actions']),
  ),
  'ListPage': (context, source) {
    final items = source.childList(['items']);
    final loading = source.v<bool>(['loading']) == true;
    final error = source.v<String>(['error']) ?? '';
    final loadMore = source.voidHandler(['onLoadMore']);
    final loadingMore = source.v<bool>(['loadingMore']) == true;
    final hasMore = source.v<bool>(['hasMore']) == true;
    return _PluginPageLayout(
      lazy: true,
      loading: loading,
      onRefresh: source.voidHandler(['onRefresh']),
      footer: source.optionalChild(['actions']),
      children: [
        if (source.optionalChild(['search']) case final search?) ...[
          search,
          const SizedBox(height: 16),
        ],
        if (source.optionalChild(['header']) case final header?) ...[
          header,
          const SizedBox(height: 16),
        ],
        if (items.isEmpty)
          _PluginPageStatus(
            loading: loading,
            error: error,
            emptyTitle: source.v<String>(['emptyTitle']),
            onRetry: source.voidHandler(['onRetry']),
          ),
        for (var index = 0; index < items.length; index++)
          SegmentedCardItem(
            index: index,
            count: items.length,
            gap: 3,
            color: PageBackgroundScope.contentColor(context,
                Theme.of(context).colorScheme.surfaceContainerLow),
            child: items[index],
          ),
        if (items.isNotEmpty && error.isNotEmpty)
          _PluginPageStatus(
            error: error,
            onRetry: source.voidHandler(['onRetry']),
          ),
        if (items.isNotEmpty && loadMore != null) ...[
          if (hasMore && !loadingMore)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton(
                onPressed: loading ? null : loadMore,
                child: Text(
                  source.v<String>(['moreLabel']) ?? context.l10n.common_more,
                ),
              ),
            )
          else
            PagedListFooter(
              hasMore: hasMore,
              isLoadingMore: loadingMore,
              isLoadMoreFailed: false,
              onRetry: loadMore,
            ),
        ],
      ],
    );
  },
  'DetailPage': (context, source) {
    final content = source.childList(['sections']);
    final header = source.optionalChild(['header']);
    final loading = source.v<bool>(['loading']) == true;
    final error = source.v<String>(['error']) ?? '';
    return _PluginPageLayout(
      loading: loading,
      onRefresh: source.voidHandler(['onRefresh']),
      footer: source.optionalChild(['actions']),
      children: [
        if (header != null) ...[header, const SizedBox(height: 20)],
        if (error.isNotEmpty ||
            (content.isEmpty && (loading || header == null)))
          _PluginPageStatus(
            loading: loading && content.isEmpty,
            error: error,
            emptyTitle: source.v<String>(['emptyTitle']),
            onRetry: source.voidHandler(['onRetry']),
          ),
        for (var index = 0; index < content.length; index++) ...[
          if (index > 0) const SizedBox(height: 16),
          content[index],
        ],
      ],
    );
  },
};

class _PluginPageStatus extends StatelessWidget {
  const _PluginPageStatus({
    this.loading = false,
    this.error = '',
    this.emptyTitle,
    this.onRetry,
  });
  final bool loading;
  final String error;
  final String? emptyTitle;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: loading
        ? const Center(child: LoadingSpinner())
        : AppEmptyState(
            icon: Icon(
              error.isEmpty
                  ? Symbols.inbox_rounded
                  : Symbols.error_outline_rounded,
            ),
            title: error.isEmpty
                ? emptyTitle ?? context.l10n.common_noData
                : error,
            action: error.isNotEmpty && onRetry != null
                ? OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Symbols.refresh_rounded),
                    label: Text(context.l10n.common_retry),
                  )
                : null,
          ),
  );
}
