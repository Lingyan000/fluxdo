import 'package:common_ui/common_ui.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../models/web_bookmark.dart';
import '../../models/web_history_item.dart';
import '../../services/browser_navigation.dart';
import 'browser_layout.dart';

/// 地址编辑时只匹配本地收藏和历史，不在输入期间发送网络请求。
class BrowserAddressPanel extends StatelessWidget {
  const BrowserAddressPanel({
    super.key,
    required this.query,
    required this.currentUrl,
    required this.currentTitle,
    required this.engine,
    required this.bookmarks,
    required this.history,
    required this.onNavigate,
    required this.onEdit,
    required this.onEngineChanged,
    required this.onCopyCurrent,
    required this.onReturnToPage,
  });

  final String query;
  final String currentUrl;
  final String currentTitle;
  final BrowserSearchEngine engine;
  final List<WebBookmark> bookmarks;
  final List<WebHistoryItem> history;
  final ValueChanged<String> onNavigate;
  final ValueChanged<String> onEdit;
  final ValueChanged<BrowserSearchEngine> onEngineChanged;
  final VoidCallback onCopyCurrent;
  final VoidCallback onReturnToPage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = query.trim();
    final showCurrent = currentUrl.isNotEmpty && text == currentUrl;
    final hasQuery = text.isNotEmpty && !showCurrent;
    final filter = showCurrent ? '' : text.toLowerCase();
    bool matches(String title, String url) =>
        filter.isEmpty || '$title $url'.toLowerCase().contains(filter);
    final favorites = bookmarks
        .where(
          (item) =>
              !(showCurrent && item.url == currentUrl) &&
              matches(item.title, item.url),
        )
        .take(5)
        .toList();
    final favoriteUrls = favorites.map((item) => item.url).toSet();
    final recent = history
        .where(
          (item) =>
              item.url != currentUrl &&
              !favoriteUrls.contains(item.url) &&
              matches(item.title, item.url),
        )
        .take(8)
        .toList();
    final target = BrowserNavigationTarget.parse(text, engine);
    final firstHeading = showCurrent
        ? l10n.webview_currentPage
        : hasQuery
        ? l10n.common_search
        : favorites.isNotEmpty
        ? l10n.myBrowser_bookmarks
        : recent.isNotEmpty
        ? l10n.myBrowser_history
        : l10n.webview_browser;

    return Material(
      color: theme.colorScheme.surface,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: browserAddressMaxWidth),
          child: ListView(
            key: const ValueKey('browser-address-suggestions'),
            padding: const EdgeInsets.fromLTRB(
              browserAddressGutter,
              4,
              browserAddressGutter,
              24,
            ),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        firstHeading,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    _engineMenu(context),
                  ],
                ),
              ),
              if (hasQuery)
                Card.filled(
                  key: const ValueKey('browser-navigation-suggestion'),
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: Icon(
                      target?.isSearch == true
                          ? Symbols.search_rounded
                          : Symbols.language_rounded,
                    ),
                    title: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      target == null
                          ? l10n.webview_invalidAddress
                          : target.isSearch
                          ? l10n.webview_searchWith(engine.label)
                          : l10n.webview_go,
                    ),
                    trailing: const Icon(Symbols.arrow_forward_rounded),
                    onTap: target == null ? null : () => onNavigate(text),
                  ),
                ),
              if (showCurrent)
                Card.filled(
                  key: const ValueKey('browser-current-page'),
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    minLeadingWidth: 24,
                    horizontalTitleGap: 12,
                    leading: const Icon(Symbols.link_rounded),
                    onTap: onReturnToPage,
                    title: Text(
                      currentTitle.isEmpty
                          ? browserDisplayHost(currentUrl)
                          : currentTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      browserDisplayHost(currentUrl),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: l10n.common_copyLink,
                      onPressed: onCopyCurrent,
                      icon: const Icon(Symbols.content_copy_rounded),
                    ),
                  ),
                ),
              if (favorites.isNotEmpty) ...[
                if (showCurrent || hasQuery)
                  _heading(context, l10n.myBrowser_bookmarks),
                for (final item in favorites)
                  _suggestion(
                    context,
                    item.title,
                    item.url,
                    Symbols.star_rounded,
                  ),
              ],
              if (recent.isNotEmpty) ...[
                if (showCurrent || hasQuery || favorites.isNotEmpty)
                  _heading(context, l10n.myBrowser_history),
                for (final item in recent)
                  _suggestion(
                    context,
                    item.title,
                    item.url,
                    Symbols.history_rounded,
                  ),
              ],
              if (favorites.isEmpty && recent.isEmpty && text.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 40,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Symbols.travel_explore_rounded,
                        size: 48,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        l10n.webview_addressHint,
                        style: theme.textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.webview_searchWith(engine.label),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _engineMenu(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<BrowserSearchEngine>(
      key: const ValueKey('browser-search-engine'),
      tooltip: context.l10n.webview_defaultSearchEngine,
      onSelected: onEngineChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        PopupMenuItem<BrowserSearchEngine>(
          enabled: false,
          child: Text(
            context.l10n.webview_defaultSearchEngine,
            style: theme.textTheme.labelMedium,
          ),
        ),
        for (final item in BrowserSearchEngine.values)
          CheckedPopupMenuItem(
            value: item,
            checked: item == engine,
            child: Text(item.label),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 180, minHeight: 48),
        child: Center(
          widthFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: context.shapes.borderRadius(20),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Symbols.search_rounded, size: 16),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      engine.label,
                      style: theme.textTheme.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Symbols.expand_more_rounded, size: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _heading(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );

  Widget _suggestion(
    BuildContext context,
    String title,
    String url,
    IconData icon,
  ) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    minLeadingWidth: 24,
    horizontalTitleGap: 12,
    shape: RoundedRectangleBorder(borderRadius: context.shapes.borderRadius(16)),
    leading: Icon(icon, size: 22),
    title: Text(
      title.isEmpty ? browserDisplayHost(url) : title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      url.replaceFirst(RegExp(r'^https?://'), ''),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: IconButton(
      tooltip: context.l10n.webview_editAddress,
      icon: const Icon(Symbols.north_west_rounded, size: 20),
      onPressed: () => onEdit(url),
    ),
    onTap: () => onNavigate(url),
  );
}
