import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ai_model_manager/ai_model_manager.dart'
    show SwipeActionCell, SwipeAction, SwipeActionScope;
import '../models/web_bookmark.dart';
import '../models/web_history_item.dart';
import '../providers/web_bookmark_provider.dart';
import '../providers/web_history_provider.dart';
import '../utils/time_utils.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import 'webview_page.dart';
import 'download_list_page.dart';

// ---------------------------------------------------------------------------
// 内置浏览器主页 — 地址栏 + 功能入口
// ---------------------------------------------------------------------------

class MyBrowserPage extends ConsumerWidget {
  const MyBrowserPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bookmarkCount = ref.watch(
      webBookmarkProvider.select((list) => list.length),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.myBrowser_title),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 地址栏
          _AddressBar(
            onSubmit: (url) => _openUrl(context, url),
          ),
          const SizedBox(height: 24),
          // 功能入口
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _EntryTile(
                  icon: Icons.star_rounded,
                  iconColor: Colors.amber,
                  title: context.l10n.myBrowser_bookmarks,
                  subtitle: context.l10n.myBrowser_bookmarkCount(bookmarkCount),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const _BookmarkListPage()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 60),
                  child: Divider(
                    height: 1,
                    thickness: 0.5,
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                  ),
                ),
                _EntryTile(
                  icon: Icons.history_rounded,
                  iconColor: Colors.purple,
                  title: context.l10n.myBrowser_history,
                  subtitle: context.l10n.myBrowser_historyDesc,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const _WebHistoryPage()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 60),
                  child: Divider(
                    height: 1,
                    thickness: 0.5,
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                  ),
                ),
                _EntryTile(
                  icon: Icons.download_rounded,
                  iconColor: Colors.teal,
                  title: context.l10n.myBrowser_downloads,
                  subtitle: context.l10n.myBrowser_downloadsDesc,
                  showDivider: false,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const DownloadListPage()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openUrl(BuildContext context, String input) {
    var url = input.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    WebViewPage.open(context, url);
  }
}

/// 地址输入栏
class _AddressBar extends StatefulWidget {
  final ValueChanged<String> onSubmit;

  const _AddressBar({required this.onSubmit});

  @override
  State<_AddressBar> createState() => _AddressBarState();
}

class _AddressBarState extends State<_AddressBar> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TextField(
      controller: _controller,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      decoration: InputDecoration(
        hintText: context.l10n.myBrowser_inputUrl,
        prefixIcon: const Icon(Icons.language_rounded),
        suffixIcon: IconButton(
          icon: const Icon(Icons.arrow_forward_rounded),
          onPressed: () => _submit(),
        ),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
      onSubmitted: (_) => _submit(),
    );
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSubmit(text);
  }
}

/// 功能入口行
class _EntryTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool showDivider;

  const _EntryTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: theme.colorScheme.outline.withValues(alpha: 0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 收藏列表页（二级页面）
// ---------------------------------------------------------------------------

class _BookmarkListPage extends ConsumerWidget {
  const _BookmarkListPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookmarks = ref.watch(webBookmarkProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.myBrowser_bookmarks),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: context.l10n.myBrowser_addManually,
            onPressed: () => _showAddDialog(context, ref),
          ),
        ],
      ),
      body: bookmarks.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.star_outline_rounded,
                      size: 64,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.4)),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.myBrowser_empty,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : SwipeActionScope(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: bookmarks.length,
                itemBuilder: (context, index) {
                  final item = bookmarks[index];
                  return Padding(
                    padding: EdgeInsets.only(
                        bottom: index < bookmarks.length - 1 ? 12 : 0),
                    child: SwipeActionCell(
                      key: ValueKey(item.url),
                      trailingActions: [
                        SwipeAction(
                          icon: Icons.edit_outlined,
                          color: Colors.blue,
                          label: S.current.myBrowser_edit,
                          onPressed: () =>
                              _showEditDialog(context, ref, item),
                        ),
                        SwipeAction(
                          icon: Icons.delete_outline,
                          color: Colors.red,
                          label: S.current.myBrowser_delete,
                          onPressed: () =>
                              _confirmDelete(context, ref, item),
                        ),
                      ],
                      child: _BookmarkCard(
                        item: item,
                        onTap: () => WebViewPage.open(context, item.url,
                            title: item.title),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }

  void _showAddDialog(BuildContext context, WidgetRef ref) {
    final urlController = TextEditingController();
    final titleController = TextEditingController();

    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.myBrowser_addManually),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: S.current.myBrowser_inputUrl,
                hintText: 'https://',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                labelText: S.current.myBrowser_inputTitle,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              var url = urlController.text.trim();
              if (url.isEmpty) return;
              if (!url.startsWith('http://') &&
                  !url.startsWith('https://')) {
                url = 'https://$url';
              }
              ref.read(webBookmarkProvider.notifier).add(
                    WebBookmark(
                      url: url,
                      title: titleController.text.trim(),
                      createdAt: DateTime.now(),
                    ),
                  );
              Navigator.pop(ctx);
            },
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(
      BuildContext context, WidgetRef ref, WebBookmark item) {
    final titleController = TextEditingController(text: item.title);

    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.myBrowser_editTitle),
        content: TextField(
          controller: titleController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: S.current.myBrowser_inputTitle,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              final notifier = ref.read(webBookmarkProvider.notifier);
              notifier.removeByUrl(item.url);
              notifier.add(WebBookmark(
                url: item.url,
                title: titleController.text.trim(),
                createdAt: item.createdAt,
              ));
              Navigator.pop(ctx);
            },
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(
      BuildContext context, WidgetRef ref, WebBookmark item) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.myBrowser_delete),
        content: Text(S.current.myBrowser_confirmDelete),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              ref
                  .read(webBookmarkProvider.notifier)
                  .removeByUrl(item.url);
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(S.current.myBrowser_delete),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 浏览历史页（二级页面）
// ---------------------------------------------------------------------------

class _WebHistoryPage extends ConsumerWidget {
  const _WebHistoryPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(webHistoryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.myBrowser_history),
        actions: [
          if (history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: context.l10n.myBrowser_clearHistory,
              onPressed: () => _confirmClear(context, ref),
            ),
        ],
      ),
      body: history.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history_rounded,
                      size: 64,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.4)),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.myBrowser_historyEmpty,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : SwipeActionScope(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: history.length,
                itemBuilder: (context, index) {
                  final item = history[index];
                  return Padding(
                    padding: EdgeInsets.only(
                        bottom: index < history.length - 1 ? 12 : 0),
                    child: SwipeActionCell(
                      key: ValueKey('${item.url}_${item.visitedAt.millisecondsSinceEpoch}'),
                      trailingActions: [
                        SwipeAction(
                          icon: Icons.delete_outline,
                          color: Colors.red,
                          label: S.current.myBrowser_delete,
                          onPressed: () => ref
                              .read(webHistoryProvider.notifier)
                              .removeByUrl(item.url),
                        ),
                      ],
                      child: _HistoryCard(
                        item: item,
                        onTap: () => WebViewPage.open(context, item.url,
                            title: item.title),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }

  void _confirmClear(BuildContext context, WidgetRef ref) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.myBrowser_clearHistory),
        content: Text(S.current.myBrowser_clearHistoryConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              ref.read(webHistoryProvider.notifier).clearAll();
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(S.current.myBrowser_clearHistory),
          ),
        ],
      ),
    );
  }
}

/// 历史卡片
class _HistoryCard extends StatelessWidget {
  final WebHistoryItem item;
  final VoidCallback onTap;

  const _HistoryCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uri = Uri.tryParse(item.url);
    final host = uri?.host ?? '';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.history_rounded,
                color: Colors.purple,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title.isNotEmpty ? item.title : item.url,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          host.isNotEmpty ? host : item.url,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        TimeUtils.formatRelativeTime(item.visitedAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: theme.colorScheme.outline.withValues(alpha: 0.4),
                size: 20),
          ],
        ),
      ),
    );
  }
}

/// 收藏卡片 — 不包 Card，由外层 SwipeActionCell 提供容器
class _BookmarkCard extends StatelessWidget {
  final WebBookmark item;
  final VoidCallback onTap;

  const _BookmarkCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uri = Uri.tryParse(item.url);
    final host = uri?.host ?? '';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.language_rounded,
                color: theme.colorScheme.primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title.isNotEmpty ? item.title : item.url,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          host.isNotEmpty ? host : item.url,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        TimeUtils.formatRelativeTime(item.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: theme.colorScheme.outline.withValues(alpha: 0.4),
                size: 20),
          ],
        ),
      ),
    );
  }
}
