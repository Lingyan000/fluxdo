import 'dart:io';

import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ai_model_manager/ai_model_manager.dart'
    show SwipeActionCell, SwipeAction, SwipeActionScope;
import 'package:m3e_ui/m3e_ui.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:cross_file/cross_file.dart';

import '../models/download_item.dart';
import '../utils/share_utils.dart';
import '../providers/download_provider.dart';
import '../services/local_notification_service.dart';
import '../services/toast_service.dart';
import '../utils/time_utils.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import '../services/public_file_channel.dart';
import '../utils/platform_utils.dart';
import '../widgets/common/app_bottom_sheet.dart';

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
              icon: const Icon(Symbols.delete_sweep_rounded),
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
                  Icon(Symbols.download_rounded,
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
                        // Linux 上 share_plus 不支持分享文件,隐藏该动作
                        if (item.status == DownloadItemStatus.completed &&
                            ShareUtils.canShareFiles)
                          SwipeAction(
                            icon: Symbols.share_rounded,
                            color: Colors.blue,
                            label: S.current.common_share,
                            onPressed: () => _shareFile(item),
                          ),
                        SwipeAction(
                          icon: Symbols.delete_rounded,
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
                          onLongPress: () => _showItemActions(item),
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

  /// 长按菜单：把下载好的文件交出去。
  ///
  /// 下载本身仍落在应用目录（进度、断点、重下都靠它），这里提供「保存到系统
  /// 下载目录 / 另存为」让用户按需把副本放到自己能找到的地方 —— 与导出文章
  /// 的去向选择同一套语义。
  Future<void> _showItemActions(DownloadItem item) async {
    if (item.status != DownloadItemStatus.completed) return;
    if (!File(item.savePath).existsSync()) {
      ToastService.showError(S.current.myBrowser_fileNotFound);
      return;
    }

    final actions = <(String, IconData, String)>[
      ('open', Symbols.file_open_rounded, S.current.exportHistory_openFile),
      // 桌面端「保存」本身就是另存为对话框，不重复给两行
      if (PlatformUtils.isDesktop || PublicFileChannel.hasPublicDownloads)
        ('save', Symbols.save_alt_rounded, S.current.export_deliverSave),
      if (!PlatformUtils.isDesktop)
        (
          'saveAs',
          Symbols.drive_folder_upload_rounded,
          S.current.export_deliverSaveAs,
        ),
      if (ShareUtils.canShareFiles)
        ('share', Symbols.share_rounded, S.current.common_share),
      ('delete', Symbols.delete_rounded, S.current.myBrowser_delete),
    ];

    await AppBottomSheet.show<void>(
      context: context,
      title: item.fileName,
      contentPadding: EdgeInsets.zero,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (id, icon, label) in actions)
            ListTile(
              leading: Icon(
                icon,
                color: id == 'delete' ? Theme.of(ctx).colorScheme.error : null,
              ),
              title: Text(
                label,
                style: id == 'delete'
                    ? TextStyle(color: Theme.of(ctx).colorScheme.error)
                    : null,
              ),
              onTap: () {
                Navigator.pop(ctx);
                _runItemAction(id, item);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _runItemAction(String id, DownloadItem item) async {
    switch (id) {
      case 'open':
        await _openFile(item);
      case 'save':
        await _saveCopy(item, asNew: false);
      case 'saveAs':
        await _saveCopy(item, asNew: true);
      case 'share':
        _shareFile(item);
      case 'delete':
        ref.read(downloadProvider.notifier).removeById(item.id);
    }
  }

  /// 把下载好的文件另存一份到用户能找到的位置（原文件留在应用目录）。
  Future<void> _saveCopy(DownloadItem item, {required bool asNew}) async {
    final file = XFile(item.savePath, mimeType: item.mimeType);
    final outcome = asNew
        ? await ShareUtils.saveFileAs(file)
        : await ShareUtils.saveFile(file);
    if (!outcome.shared || !mounted) return;
    final name = outcome.displayName?.isNotEmpty == true
        ? outcome.displayName!
        : p.basename(item.savePath);
    ToastService.showSuccess(S.current.export_savedAs(name));
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
      // 打开失败就说打不开:原先回退成「另存为对话框」,用户想打开却被要求
      // 再存一份,语义不通
      ToastService.showError(S.current.exportHistory_openFailed);
    }
  }

  void _shareFile(DownloadItem item) {
    final file = File(item.savePath);
    if (!file.existsSync()) {
      ToastService.showError(S.current.myBrowser_fileNotFound);
      return;
    }
    ShareUtils.shareFile(XFile(item.savePath));
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
  final VoidCallback onLongPress;

  const _DownloadCard({
    required this.item,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
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
                        ?.copyWith(fontWeight: FontWeight.w500),
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
                    M3eLinearProgress(
                      value: item.progress > 0 ? item.progress : null,
                      trackColor: theme.colorScheme.surfaceContainerHighest,
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
        return Symbols.downloading_rounded;
      case DownloadItemStatus.completed:
        return Symbols.download_done_rounded;
      case DownloadItemStatus.failed:
        return Symbols.error_rounded;
    }
  }

  IconData get _trailingIcon {
    switch (item.status) {
      case DownloadItemStatus.downloading:
        return Symbols.close_rounded;
      case DownloadItemStatus.completed:
        return Symbols.open_in_new_rounded;
      case DownloadItemStatus.failed:
        return Symbols.refresh_rounded;
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
