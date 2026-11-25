part of 'metaverse_widget_library.dart';

/// 最新条目在前的时间线，适用于消息、日志与持续追加的记录。
/// 设计依据: docs/plugins/components.md 的时间线约定。
class _PluginTimelinePage extends StatefulWidget {
  const _PluginTimelinePage({
    required this.identity,
    required this.items,
    required this.itemKeys,
    required this.loading,
    required this.loadingMore,
    required this.hasMore,
    required this.error,
    required this.endRevision,
    this.header,
    this.footer,
    this.loadingPlaceholder,
    this.emptyTitle,
    this.moreLabel,
    this.onLoadMore,
    this.onRetry,
  });
  final String identity;
  final List<Widget> items;
  final List<String> itemKeys;
  final bool loading, loadingMore, hasMore;
  final String error;
  final int endRevision;
  final Widget? header, footer, loadingPlaceholder;
  final String? emptyTitle, moreLabel;
  final VoidCallback? onLoadMore, onRetry;

  @override
  State<_PluginTimelinePage> createState() => _PluginTimelinePageState();
}

class _PluginTimelinePageState extends State<_PluginTimelinePage> {
  final _scroll = ScrollController(keepScrollOffset: false);
  final _viewport = GlobalKey();
  final _keys = <String, GlobalKey>{};
  bool _away = false;
  bool _requested = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onPosition);
  }

  void _onPosition() {
    if (!_scroll.hasClients) return;
    final away = _scroll.offset > 80;
    if (_away != away) setState(() => _away = away);
  }

  bool _onScroll(ScrollNotification event) {
    // 仅用户向历史方向滑动才请求；布局更新不能自动连翻历史。
    final delta = switch (event) {
      ScrollUpdateNotification() => event.scrollDelta ?? 0,
      OverscrollNotification() => event.overscroll,
      _ => 0.0,
    };
    if (event.depth == 0 && delta > 0 && event.metrics.extentAfter < 160) {
      _loadMore();
    }
    return false;
  }

  void _loadMore() {
    if (_requested ||
        widget.loading ||
        widget.loadingMore ||
        !widget.hasMore ||
        widget.error.isNotEmpty ||
        widget.onLoadMore == null) {
      return;
    }
    _requested = true;
    widget.onLoadMore!();
  }

  void _latest({bool animate = true}) {
    if (!_scroll.hasClients) return;
    if (!animate || MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(0);
    } else {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  void didUpdateWidget(_PluginTimelinePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged = oldWidget.identity != widget.identity;
    if (identityChanged || widget.items.isEmpty) _away = false;
    final keysChanged =
        oldWidget.itemKeys.length != widget.itemKeys.length ||
        Iterable<int>.generate(widget.itemKeys.length)
            .any((i) => oldWidget.itemKeys[i] != widget.itemKeys[i]);
    if (identityChanged ||
        keysChanged ||
        oldWidget.loadingMore && !widget.loadingMore ||
        widget.error.isNotEmpty) {
      _requested = false;
    }
    if (!identityChanged &&
        !keysChanged &&
        oldWidget.endRevision == widget.endRevision) {
      return;
    }
    final generation = ++_generation;
    final atEnd = !_scroll.hasClients || _scroll.offset <= 80;
    final follow =
        identityChanged || atEnd || oldWidget.endRevision != widget.endRevision;
    GlobalKey? anchor;
    double? previousY;
    final viewport = _viewport.currentContext?.findRenderObject();
    if (!follow && viewport is RenderBox) {
      final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
      for (final id in oldWidget.itemKeys) {
        if (!widget.itemKeys.contains(id)) continue;
        final key = _keys[id];
        final box = key?.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.hasSize) continue;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        if (rect.overlaps(bounds)) {
          anchor = key;
          previousY = rect.top;
          break;
        }
      }
    }
    if (identityChanged) _keys.clear();
    final active = widget.itemKeys.toSet();
    _keys.removeWhere((id, _) => !active.contains(id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation || !_scroll.hasClients) return;
      if (follow) {
        _latest(animate: false);
        return;
      }
      final box = anchor?.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && previousY != null) {
        final correction = previousY - box.localToGlobal(Offset.zero).dy;
        if (correction.abs() > .5) {
          _scroll.jumpTo(
            (_scroll.offset + correction).clamp(
              0,
              _scroll.position.maxScrollExtent,
            ),
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final validKeys =
        widget.itemKeys.length == widget.items.length &&
        widget.itemKeys.toSet().length == widget.items.length;
    final items = validKeys ? widget.items : const <Widget>[];
    return _PluginPageLayout(
      loading: widget.loading,
      toolbar: items.isNotEmpty && widget.error.isNotEmpty
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ?widget.header,
                Semantics(
                  liveRegion: true,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.error,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                        ),
                      ),
                      if (widget.onRetry != null)
                        TextButton(
                          onPressed: widget.onRetry,
                          child: Text(context.l10n.common_retry),
                        ),
                    ],
                  ),
                ),
              ],
            )
          : widget.header,
      footer: widget.footer,
      body: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: items.isEmpty && !widget.loading
                    ? SingleChildScrollView(
                        primary: false,
                        padding: const EdgeInsets.all(16),
                        child: _PluginPageStatus(
                          error: widget.error,
                          emptyTitle: widget.emptyTitle,
                          onRetry: widget.onRetry,
                        ),
                      )
                    : NotificationListener<ScrollNotification>(
                        onNotification: _onScroll,
                        child: ListView.builder(
                          key: _viewport,
                          controller: _scroll,
                          reverse: true,
                          padding: EdgeInsets.fromLTRB(
                            16,
                            16,
                            16,
                            16 +
                                (widget.footer == null
                                    ? MediaQuery.paddingOf(context).bottom
                                    : 0),
                          ),
                          physics: const AlwaysScrollableScrollPhysics(),
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: items.length + 1,
                          findChildIndexCallback: (key) {
                            if (key is! ValueKey<String>) return null;
                            final index = widget.itemKeys.indexOf(key.value);
                            return index < 0 ? null : index;
                          },
                          itemBuilder: (context, index) {
                            if (index < items.length) {
                              final id = widget.itemKeys[index];
                              return KeyedSubtree(
                                key: ValueKey(id),
                                child: KeyedSubtree(
                                  key: _keys.putIfAbsent(id, GlobalKey.new),
                                  child: items[index],
                                ),
                              );
                            }
                            if (items.isEmpty) {
                              return widget.loading &&
                                      widget.loadingPlaceholder != null
                                  ? widget.loadingPlaceholder!
                                  : _PluginPageStatus(
                                      loading: widget.loading,
                                      error: widget.error,
                                      emptyTitle: widget.emptyTitle,
                                      onRetry: widget.onRetry,
                                    );
                            }
                            if (widget.loadingMore) {
                              return const Padding(
                                padding: EdgeInsets.all(12),
                                child: Center(child: LoadingSpinner(size: 24)),
                              );
                            }
                            if (!widget.hasMore || widget.onLoadMore == null) {
                              return const SizedBox.shrink();
                            }
                            return Center(
                              child: TextButton(
                                onPressed:
                                    widget.loading || widget.error.isNotEmpty
                                    ? null
                                    : _loadMore,
                                child: Text(
                                  widget.moreLabel ?? context.l10n.common_more,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ),
          ),
          if (_away)
            PositionedDirectional(
              end: 16,
              bottom: 12,
              child: FilledButton.tonalIcon(
                onPressed: _latest,
                icon: const Icon(Symbols.arrow_downward_rounded, size: 18),
                label: Text(context.l10n.metaverse_timelineLatest),
              ),
            ),
        ],
      ),
      children: const [],
    );
  }
}
