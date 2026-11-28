part of 'metaverse_widget_library.dart';

/// 页面级组件沿用公共页面外壳，数据与操作由插件传入。
Map<String, LocalWidgetBuilder> _pageWidgets() => {
  'TimelinePage': (context, source) => _PluginTimelinePage(
    identity: source.v<String>(['identity']) ?? '',
    items: source.childList(['items']),
    itemKeys: [for (var i = 0; i < source.length(['itemKeys']); i++)
      source.v<String>(['itemKeys', i]) ?? ''],
    loading: source.v<bool>(['loading']) == true,
    loadingMore: source.v<bool>(['loadingMore']) == true,
    hasMore: source.v<bool>(['hasMore']) == true,
    error: source.v<String>(['error']) ?? '',
    endRevision: source.v<int>(['endRevision']) ?? 0,
    shortContentAtStart: source.v<String>(['shortContentAlignment']) == 'start',
    header: source.optionalChild(['header']),
    footer: source.optionalChild(['footer']),
    loadingPlaceholder: source.optionalChild(['loadingPlaceholder']),
    emptyTitle: source.v<String>(['emptyTitle']),
    moreLabel: source.v<String>(['moreLabel']),
    onLoadMore: source.voidHandler(['onLoadMore']),
    onRetry: source.voidHandler(['onRetry']),
  ),
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
  'ListPage': (context, source) => _PluginListPage(
    items: source.childList(['items']),
    loading: source.v<bool>(['loading']) == true,
    loadingMore: source.v<bool>(['loadingMore']) == true,
    hasMore: source.v<bool>(['hasMore']) == true,
    error: source.v<String>(['error']) ?? '',
    emptyTitle: source.v<String>(['emptyTitle']),
    moreLabel: source.v<String>(['moreLabel']),
    toolbar: source.optionalChild(['toolbar']),
    search: source.optionalChild(['search']),
    header: source.optionalChild(['header']),
    footer: source.optionalChild(['actions']),
    empty: source.optionalChild(['empty']),
    loadingPlaceholder: source.optionalChild(['loadingPlaceholder']),
    onRefresh: source.voidHandler(['onRefresh']),
    onRetry: source.voidHandler(['onRetry']),
    onLoadMore: source.voidHandler(['onLoadMore']),
  ),
  'DetailPage': (context, source) {
    final content = source.childList(['sections']);
    final header = source.optionalChild(['header']);
    final loading = source.v<bool>(['loading']) == true;
    final error = source.v<String>(['error']) ?? '';
    return _PluginPageLayout(
      toolbar: source.optionalChild(['toolbar']),
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
