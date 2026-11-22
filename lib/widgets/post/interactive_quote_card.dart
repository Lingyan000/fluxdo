import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:dio/dio.dart';
import 'package:fluxdo_render/fluxdo_render.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/s.dart';
import '../../models/topic.dart';
import '../../utils/blocked_user_filter.dart';
import '../../utils/color_utils.dart';
import '../../utils/fluxdo_render_callbacks.dart';
import '../../utils/quote_excerpt_highlight.dart';
import 'quote_navigation_scope.dart';

class InteractiveQuoteCard extends StatefulWidget {
  const InteractiveQuoteCard({
    super.key,
    required this.quote,
    required this.layout,
    required this.topicId,
    required this.loadPost,
    required this.openTopic,
    required this.blockedUsernames,
    this.currentTopicId,
    this.bodyStyle,
  });

  final QuoteCardNode quote;
  final QuoteCardLayout layout;
  final int? topicId;
  final int? currentTopicId;
  final Future<Post> Function(int topicId, int postNumber) loadPost;
  final void Function(BuildContext context, int topicId, int postNumber)
  openTopic;
  final Set<String> blockedUsernames;
  final TextStyle? bodyStyle;

  @override
  State<InteractiveQuoteCard> createState() => _InteractiveQuoteCardState();
}

class _InteractiveQuoteCardState extends State<InteractiveQuoteCard> {
  bool _expanded = false;
  Future<Post>? _request;

  @override
  Widget build(BuildContext context) {
    final quote = widget.quote;
    final topicId = widget.topicId;
    final number = quote.postNumber;
    final hasSource =
        topicId != null && topicId > 0 && number != null && number > 0;
    final isCrossTopic =
        hasSource &&
        ((widget.currentTopicId != null && topicId != widget.currentTopicId) ||
            (widget.currentTopicId == null &&
                quote.topicId != null &&
                QuoteNavigationScope.jumpFor(context, topicId) == null));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.l10n;
    final categoryColor = ColorUtils.category(
      quote.categoryColor,
      theme,
      fallback: scheme.outline,
    );
    return FutureBuilder<Post>(
      future: _request,
      builder: (context, snapshot) {
        final loaded = snapshot.data;
        final blocked =
            BlockedUserFilter.isBlockedUsername(
              quote.username,
              widget.blockedUsernames,
            ) ||
            BlockedUserFilter.isBlockedUsername(
              loaded?.username,
              widget.blockedUsernames,
            );
        if (blocked) {
          return widget.layout(
            disableSource: true,
            isCrossTopic: isCrossTopic,
            categoryColor: categoryColor,
            body: Text(
              strings.post_quoteBlocked,
              style: (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final error = snapshot.error;
        final status = error is DioException
            ? error.response?.statusCode
            : null;
        final missing =
            quote.sourceMissing ||
            loaded?.isDeleted == true ||
            status == 404 ||
            status == 410;
        final forbidden = status == 401 || status == 403;
        final canOpen = !missing && !forbidden;
        Future<Post> load() =>
            Future.sync(() => widget.loadPost(topicId!, number!));
        void retry() {
          final next = load();
          setState(() {
            _request = next;
          });
        }

        void toggle() => setState(() {
          _expanded = !_expanded;
          if (_expanded) _request ??= load();
        });
        final loading =
            _expanded && snapshot.connectionState == ConnectionState.waiting;
        final showToggle = hasSource && !quote.full && (canOpen || _expanded);
        Widget? body;
        Widget? footer;
        if (_expanded && !loading) {
          if (error != null || missing) {
            final statusStyle = (theme.textTheme.labelSmall ?? const TextStyle())
                .copyWith(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                );
            footer = Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Semantics(
                liveRegion: true,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      forbidden
                          ? strings.error_forbiddenAccess
                          : missing
                          ? strings.error_notFoundOrDeleted
                          : strings.error_loadFailed,
                      style: statusStyle,
                    ),
                    if (canOpen)
                      Semantics(
                        button: true,
                        child: InkWell(
                          onTap: retry,
                          borderRadius: context.shapes.borderRadius(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            child: Text(
                              strings.common_retry,
                              style: statusStyle.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          } else if (loaded != null) {
            body = _QuoteSourceBody(
              post: loaded,
              topicId: topicId!,
              excerpt: quote.excerptText,
              bodyStyle: widget.bodyStyle,
            );
          }
        }
        final toggleLabel = _expanded
            ? strings.post_quoteCollapse
            : strings.post_quoteExpand;
        return widget.layout(
          categoryColor: categoryColor,
          body: body,
          footer: footer,
          disableSource: !canOpen,
          isCrossTopic: isCrossTopic,
          floorLabel: hasSource && canOpen
              ? strings.post_quoteGoToFloor(number)
              : null,
          onOpen: hasSource && canOpen
              ? () {
                  final jump = QuoteNavigationScope.jumpFor(context, topicId);
                  if (jump != null) {
                    jump(number);
                  } else {
                    widget.openTopic(context, topicId, number);
                  }
                }
              : null,
          trailing: showToggle
              ? Semantics(
                  button: true,
                  expanded: _expanded,
                  label: toggleLabel,
                  child: Tooltip(
                    message: toggleLabel,
                    child: InkWell(
                      onTap: toggle,
                      borderRadius: context.shapes.borderRadius(6),
                      child: SizedBox(
                        width: 26,
                        height: 22,
                        child: Center(
                          child: loading
                              ? const LoadingSpinner(size: 13)
                              : Icon(
                                  _expanded
                                      ? Symbols.expand_less_rounded
                                      : Symbols.expand_more_rounded,
                                  size: 17,
                                  color: scheme.onSurfaceVariant,
                                ),
                        ),
                      ),
                    ),
                  ),
                )
              : null,
        );
      },
    );
  }
}

class _QuoteSourceBody extends StatefulWidget {
  const _QuoteSourceBody({
    required this.post,
    required this.topicId,
    required this.excerpt,
    this.bodyStyle,
  });
  final Post post;
  final int topicId;
  final String excerpt;
  final TextStyle? bodyStyle;

  @override
  State<_QuoteSourceBody> createState() => _QuoteSourceBodyState();
}

class _QuoteSourceBodyState extends State<_QuoteSourceBody> {
  static int _nextId = 0;
  late final _namespace = 'expanded_quote_${_nextId++}';
  (Post, int, String, Color, Color)? _signature;
  late String _cooked;
  late FluxdoRenderCallbacks _callbacks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final signature = (
      widget.post,
      widget.topicId,
      widget.excerpt,
      scheme.secondaryContainer,
      scheme.onSecondaryContainer,
    );
    if (_signature != signature) {
      _signature = signature;
      _cooked = highlightQuoteExcerpt(
        FluxdoRenderCallbacks.preprocessCookedForRender(widget.post),
        widget.excerpt,
        background: scheme.secondaryContainer,
        foreground: scheme.onSecondaryContainer,
      );
      _callbacks = FluxdoRenderCallbacks.forPost(
        post: widget.post,
        topicId: widget.topicId,
        heroTagNamespace: _namespace,
        preprocessedCooked: _cooked,
      );
    }
    return _callbacks.render(
      cookedHtml: _cooked,
      compact: true,
      baseTextStyle: widget.bodyStyle,
    );
  }
}
