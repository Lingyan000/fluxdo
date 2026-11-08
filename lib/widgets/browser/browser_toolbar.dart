import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';

import '../../l10n/s.dart';
import '../../services/browser_navigation.dart';
import 'browser_layout.dart';

class BrowserToolbar extends StatelessWidget implements PreferredSizeWidget {
  const BrowserToolbar({
    super.key,
    required this.title,
    required this.url,
    required this.editing,
    required this.addressController,
    required this.addressFocus,
    required this.onAddressTap,
    required this.onCancelEdit,
    required this.onSubmit,
    required this.onClose,
    required this.onMinimize,
    required this.onMenu,
    required this.loading,
    required this.progress,
    required this.bookmarked,
  });
  final String title;
  final String url;
  final bool editing;
  final TextEditingController addressController;
  final FocusNode addressFocus;
  final VoidCallback onAddressTap;
  final VoidCallback onCancelEdit;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClose;
  final VoidCallback? onMinimize;
  final ValueChanged<String> onMenu;
  final bool loading;
  final double progress;
  final bool bookmarked;

  @override
  Size get preferredSize => const Size.fromHeight(66);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    final host = browserDisplayHost(url);
    final secure = Uri.tryParse(url)?.scheme == 'https';
    final showHost = MediaQuery.textScalerOf(context).scale(13) <= 18;
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= browserWideToolbarWidth;
                  return Row(
                    children: [
                      IconButton(
                        key: const ValueKey('browser-leading'),
                        tooltip: editing
                            ? l10n.common_cancel
                            : l10n.common_close,
                        onPressed: editing ? onCancelEdit : onClose,
                        icon: AnimatedSwitcher(
                          duration: duration,
                          child: Icon(
                            editing
                                ? Symbols.arrow_back_rounded
                                : Symbols.close_rounded,
                            key: ValueKey(editing),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: wide
                                  ? browserAddressMaxWidth -
                                        browserAddressGutter * 2
                                  : double.infinity,
                            ),
                            child: AnimatedContainer(
                              key: const ValueKey('browser-address-capsule'),
                              duration: duration,
                              curve: Curves.easeOutCubic,
                              height: 48,
                              decoration: BoxDecoration(
                                color: editing
                                    ? theme.colorScheme.surfaceContainerHighest
                                    : theme.colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(
                                  editing ? 24 : 16,
                                ),
                              ),
                              child: AnimatedSwitcher(
                                duration: duration,
                                child: editing
                                    ? TextField(
                                        key: const ValueKey(
                                          'browser-address-input',
                                        ),
                                        controller: addressController,
                                        focusNode: addressFocus,
                                        maxLines: 1,
                                        textInputAction: TextInputAction.go,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        textAlignVertical:
                                            TextAlignVertical.center,
                                        style: theme.textTheme.bodyLarge,
                                        decoration: InputDecoration(
                                          hintText: l10n.webview_addressHint,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          contentPadding: const EdgeInsets.only(
                                            left: 16,
                                          ),
                                          suffixIcon: IconButton(
                                            tooltip: l10n.common_clear,
                                            icon: const Icon(
                                              Symbols.close_rounded,
                                              size: 18,
                                            ),
                                            onPressed: addressController.clear,
                                          ),
                                        ),
                                        onSubmitted: onSubmit,
                                      )
                                    : Semantics(
                                        key: const ValueKey(
                                          'browser-address-display',
                                        ),
                                        button: true,
                                        label: l10n.webview_editAddress,
                                        child: InkWell(
                                          onTap: onAddressTap,
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  url.isEmpty
                                                      ? Symbols.search_rounded
                                                      : secure
                                                      ? Symbols.lock_rounded
                                                      : Symbols.info_rounded,
                                                  size: 16,
                                                  color: theme
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        title.isNotEmpty
                                                            ? title
                                                            : host.isNotEmpty
                                                            ? host
                                                            : l10n.webview_addressHint,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: theme
                                                            .textTheme
                                                            .labelLarge,
                                                      ),
                                                      if (showHost &&
                                                          host.isNotEmpty &&
                                                          title.isNotEmpty)
                                                        Text(
                                                          host,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: theme
                                                              .textTheme
                                                              .labelSmall
                                                              ?.copyWith(
                                                                color: theme
                                                                    .colorScheme
                                                                    .onSurfaceVariant,
                                                              ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      BrowserAnimatedSize(
                        child: editing
                            ? SizedBox(width: wide ? 48 : 8)
                            : Row(
                                children: [
                                  IconButton(
                                    tooltip: l10n.webview_minimize,
                                    icon: const Icon(
                                      Symbols.keyboard_arrow_down_rounded,
                                    ),
                                    onPressed: onMinimize,
                                  ),
                                  SwipeDismissiblePopupMenuButton<String>(
                                    tooltip: l10n.common_more,
                                    onSelected: onMenu,
                                    itemBuilder: (context) => [
                                      _item(
                                        'find',
                                        Symbols.search_rounded,
                                        l10n.webview_findInPage,
                                        enabled: url.isNotEmpty,
                                      ),
                                      _item(
                                        'toggle_bookmark',
                                        Symbols.star_rounded,
                                        bookmarked
                                            ? l10n.webview_removeBookmark
                                            : l10n.webview_addBookmark,
                                        enabled: url.isNotEmpty,
                                      ),
                                      _item(
                                        'copy_url',
                                        Symbols.content_copy_rounded,
                                        l10n.common_copyLink,
                                        enabled: url.isNotEmpty,
                                      ),
                                      _item(
                                        'share',
                                        Symbols.share_rounded,
                                        l10n.common_share,
                                        enabled: url.isNotEmpty,
                                      ),
                                      _item(
                                        'open_external',
                                        Symbols.open_in_browser_rounded,
                                        l10n.webview_openExternal,
                                        enabled: url.isNotEmpty,
                                      ),
                                      _item(
                                        'library',
                                        Symbols.bookmarks_rounded,
                                        l10n.myBrowser_title,
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
            SizedBox(
              height: 2,
              child: AnimatedOpacity(
                duration: duration,
                opacity: loading && !editing ? 1 : 0,
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 2,
                  backgroundColor: theme.colorScheme.surfaceContainerLow,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<String> _item(
    String value,
    IconData icon,
    String text, {
    bool enabled = true,
  }) => PopupMenuItem(
    value: value,
    enabled: enabled,
    child: Row(
      children: [
        Icon(icon, size: 22),
        const SizedBox(width: 12),
        Flexible(child: Text(text)),
      ],
    ),
  );
}

/// 减少动画时直接布局，避免零时长 AnimatedSize 在 layout 中重入。
class BrowserAnimatedSize extends StatelessWidget {
  const BrowserAnimatedSize({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? child
      : AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          child: child,
        );
}

class BrowserBottomToolbar extends StatelessWidget {
  const BrowserBottomToolbar({
    super.key,
    required this.canGoBack,
    required this.canGoForward,
    required this.loading,
    required this.hasUrl,
    required this.bookmarked,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onBookmark,
    required this.onShare,
  });
  final bool canGoBack, canGoForward, loading, hasUrl, bookmarked;
  final VoidCallback onBack, onForward, onReload, onBookmark, onShare;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SizedBox(
            height: 56,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                IconButton(
                  tooltip: context.l10n.webview_goBack,
                  onPressed: canGoBack ? onBack : null,
                  icon: const Icon(Symbols.chevron_left_rounded),
                ),
                IconButton(
                  tooltip: context.l10n.webview_goForward,
                  onPressed: canGoForward ? onForward : null,
                  icon: const Icon(Symbols.chevron_right_rounded),
                ),
                IconButton(
                  tooltip: loading
                      ? context.l10n.webview_stopLoading
                      : context.l10n.common_refresh,
                  onPressed: hasUrl ? onReload : null,
                  icon: Icon(
                    loading ? Symbols.close_rounded : Symbols.refresh_rounded,
                  ),
                ),
                IconButton(
                  tooltip: bookmarked
                      ? context.l10n.webview_removeBookmark
                      : context.l10n.webview_addBookmark,
                  onPressed: hasUrl ? onBookmark : null,
                  icon: Icon(Symbols.star_rounded, fill: bookmarked ? 1 : 0),
                ),
                IconButton(
                  tooltip: context.l10n.common_share,
                  onPressed: hasUrl ? onShare : null,
                  icon: const Icon(Symbols.ios_share_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
