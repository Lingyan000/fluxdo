import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ai_model_manager/ai_model_manager.dart'
    show SwipeActionCell, SwipeAction, SwipeActionScope;
import 'package:open_filex/open_filex.dart';
import 'package:cross_file/cross_file.dart';

import '../models/download_item.dart';
import '../utils/share_utils.dart';
import '../providers/download_provider.dart';
import '../services/local_notification_service.dart';
import '../services/toast_service.dart';
import '../utils/time_utils.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';

/// 下载管理页面
class DownloadListPage extends ConsumerStatefulWidget {
  final String? highlightItemId;

  const DownloadListPage({super.key, this.highlightItemId});

  /// 全局导航到下载列表页面
  static void navigateTo({String? highlightItemId}) {
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => DownloadListPage(highlightItemId: highlightItemId),
      ),
    );
  }

  @override
  ConsumerState<DownloadListPage> createState() => _DownloadListPageState();
}

class _DownloadListPageState extends ConsumerState<DownloadListPage> {
  final _scrollController = ScrollController();
  String? _highlightingId;

  @override
  void initState() {
    super.initState();
    if (widget.highlightItemId != null) {
      _highlightingId = widget.highlightItemId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToItem(widget.highlightItemId!);
        // 2 秒后淡出高亮
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _highlightingId = null);
        });
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToItem(String id) {
    final downloads = ref.read(downloadProvider);
    final index = downloads.indexWhere((e) => e.id == id);
    if (index < 0) return;
    // 每项约 80px 高 + 12px 间距
    final offset = (index * 92.0).clamp(0.0, _scrollController.position.maxScrollExtent);
    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloads = ref.watch(downloadProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.myBrowser_downloads),
        actions: [
          if (downloads.any((e) => e.status == DownloadItemStatus.completed))
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: context.l10n.myBrowser_clearCompleted,
              onPressed: () => _confirmClear(context),
            ),
        ],
      ),
      body: downloads.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.download_rounded,
                      size: 64,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.4)),
                  const SizedBox(height: 16),
                  Text(
                    context.l10n.myBrowser_downloadEmpty,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : SwipeActionScope(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: downloads.length,
                itemBuilder: (context, index) {
                  final item = downloads[index];
                  final isHighlighted = item.id == _highlightingId;

                  return Padding(
                    padding: EdgeInsets.only(
                        bottom: index < downloads.length - 1 ? 12 : 0),
                    child: SwipeActionCell(
                      key: ValueKey(item.id),
                      trailingActions: [
                        if (item.status == DownloadItemStatus.completed)
                          SwipeAction(
                            icon: Icons.share_rounded,
                            color: Colors.blue,
                            label: S.current.common_share,
                            onPressed: () => _shareFile(item),
                          ),
                        SwipeAction(
                          icon: Icons.delete_outline,
                          color: Colors.red,
                          label: S.current.myBrowser_delete,
                          onPressed: () => ref
                              .read(downloadProvider.notifier)
                              .removeById(item.id),
                        ),
                      ],
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 800),
                        decoration: BoxDecoration(
                          color: isHighlighted
                              ? theme.colorScheme.primary
                                  .withValues(alpha: 0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _DownloadCard(
                          item: item,
                          onTap: () => _handleTap(item),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }

  void _handleTap(DownloadItem item) {
    switch (item.status) {
      case DownloadItemStatus.completed:
        _openFile(item);
        break;
      case DownloadItemStatus.failed:
        ref.read(downloadProvider.notifier).retry(item);
        break;
      case DownloadItemStatus.downloading:
        ref.read(downloadProvider.notifier).cancel(item.id);
        break;
    }
  }

  /// 用系统默认应用打开文件
  Future<void> _openFile(DownloadItem item) async {
    final file = File(item.savePath);
    if (!file.existsSync()) {
      ToastService.showError(S.current.myBrowser_fileNotFound);
      return;
    }
    final result = await OpenFilex.open(item.savePath, type: item.mimeType);
    if (result.type != ResultType.done && mounted) {
      // 打开失败时回退到分享/保存
      ShareUtils.shareOrSaveFile(XFile(item.savePath));
    }
  }

  void _shareFile(DownloadItem item) {
    final file = File(item.savePath);
    if (!file.existsSync()) {
      ToastService.showError(S.current.myBrowser_fileNotFound);
      return;
    }
    ShareUtils.shareOrSaveFile(XFile(item.savePath));
  }

  void _confirmClear(BuildContext context) {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.myBrowser_clearCompleted),
        content: Text(S.current.myBrowser_clearCompletedConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              ref.read(downloadProvider.notifier).clearCompleted();
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(S.current.myBrowser_clearCompleted),
          ),
        ],
      ),
    );
  }
}

/// 下载卡片
class _DownloadCard extends StatelessWidget {
  final DownloadItem item;
  final VoidCallback onTap;

  const _DownloadCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_statusIcon, color: _statusColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.fileName,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (item.fileSize > 0) ...[
                        Text(
                          _formatSize(item.fileSize),
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        TimeUtils.formatRelativeTime(item.createdAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 11),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _statusText(context),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _statusColor,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  if (item.status == DownloadItemStatus.downloading) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: item.progress > 0 ? item.progress : null,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              _trailingIcon,
              color: theme.colorScheme.outline.withValues(alpha: 0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Color get _statusColor {
    switch (item.status) {
      case DownloadItemStatus.downloading:
        return Colors.blue;
      case DownloadItemStatus.completed:
        return Colors.teal;
      case DownloadItemStatus.failed:
        return Colors.red;
    }
  }

  IconData get _statusIcon {
    switch (item.status) {
      case DownloadItemStatus.downloading:
        return Icons.downloading_rounded;
      case DownloadItemStatus.completed:
        return Icons.download_done_rounded;
      case DownloadItemStatus.failed:
        return Icons.error_outline_rounded;
    }
  }

  IconData get _trailingIcon {
    switch (item.status) {
      case DownloadItemStatus.downloading:
        return Icons.close_rounded;
      case DownloadItemStatus.completed:
        return Icons.open_in_new_rounded;
      case DownloadItemStatus.failed:
        return Icons.refresh_rounded;
    }
  }

  String _statusText(BuildContext context) {
    switch (item.status) {
      case DownloadItemStatus.downloading:
        return context.l10n.myBrowser_downloading;
      case DownloadItemStatus.completed:
        return context.l10n.myBrowser_downloadComplete;
      case DownloadItemStatus.failed:
        return context.l10n.myBrowser_downloadFailed;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
