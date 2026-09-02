import 'dart:io';

import 'package:ai_model_manager/ai_model_manager.dart'
    show SwipeActionCell, SwipeAction, SwipeActionScope;
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/s.dart';
import '../providers/export_history_provider.dart';
import '../services/public_file_channel.dart';
import '../services/toast_service.dart';
import 'package:common_ui/common_ui.dart';
import '../storage/export_history_dao.dart';
import '../utils/dialog_utils.dart';
import '../utils/platform_utils.dart';
import '../utils/share_utils.dart';
import '../utils/time_utils.dart';
import '../widgets/common/app_bottom_sheet.dart';

/// 导出历史页面：列出当前账号所有导出/同步记录。
class ExportHistoryPage extends ConsumerStatefulWidget {
  const ExportHistoryPage({super.key});

  @override
  ConsumerState<ExportHistoryPage> createState() => _ExportHistoryPageState();
}

class _ExportHistoryPageState extends ConsumerState<ExportHistoryPage> {
  ExportHistoryFormat? _filter; // null = 全部

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(exportHistoryProvider);
    final entries = _filter == null
        ? all
        : all.where((e) => e.format == _filter).toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.exportHistory_title),
        actions: [
          if (all.isNotEmpty) ...[
            _FilterMenu(
              current: _filter,
              onChange: (v) => setState(() => _filter = v),
            ),
            IconButton(
              icon: const Icon(Symbols.delete_sweep_rounded),
              tooltip: context.l10n.exportHistory_clearAll,
              onPressed: _confirmClear,
            ),
          ],
        ],
      ),
      body: entries.isEmpty
          ? const _EmptyState()
          : SwipeActionScope(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return SwipeActionCell(
                    key: ValueKey(entry.id),
                    trailingActions: [
                      SwipeAction(
                        icon: Symbols.delete_rounded,
                        color: Colors.red,
                        label: context.l10n.exportHistory_deleteRecord,
                        onPressed: () => ref
                            .read(exportHistoryProvider.notifier)
                            .remove(entry.id),
                      ),
                    ],
                    child: _ExportEntryCard(
                      entry: entry,
                      onTap: () => _handleTap(entry),
                      onLongPress: () => _showEntryActions(entry),
                    ),
                  );
                },
              ),
            ),
    );
  }

  /// 长按菜单：动作按条目自身能力派生，不写死平台/类型清单。
  ///
  /// - Notion 条目 → 在浏览器打开
  /// - 本地文件 → 打开文件；桌面还能定位到所在文件夹；能拿到真实路径时可再次
  ///   分享（Android 公共目录/另存为拿到的是 content uri，share_plus 分享不了，
  ///   所以那种条目没有这一项）
  /// - 分享出去的条目 → 没有本地副本，只有删除
  Future<void> _showEntryActions(ExportHistoryEntry entry) async {
    final isNotion = entry.targetType == ExportHistoryTarget.notion;
    final ref0 = entry.targetRef;
    final isUri = ref0.startsWith('content://');
    final hasLocalFile =
        entry.targetType == ExportHistoryTarget.localFile && ref0.isNotEmpty;
    final fileExists = hasLocalFile && (isUri || File(ref0).existsSync());

    final actions = <(String, IconData, String)>[
      if (isNotion && ref0.isNotEmpty)
        ('open', Symbols.public_rounded, S.current.exportHistory_openInBrowser),
      if (fileExists)
        ('open', Symbols.file_open_rounded, S.current.exportHistory_openFile),
      if (fileExists && !isUri && PlatformUtils.isDesktop)
        (
          'reveal',
          Symbols.folder_open_rounded,
          S.current.exportHistory_revealInFolder,
        ),
      // content uri 走原生 ACTION_SEND，本地路径走 share_plus
      if (fileExists && (isUri || ShareUtils.canShareFiles))
        ('share', Symbols.share_rounded, S.current.exportHistory_shareAgain),
      (
        'delete',
        Symbols.delete_rounded,
        S.current.exportHistory_deleteRecord,
      ),
    ];

    await AppBottomSheet.show<void>(
      context: context,
      contentPadding: EdgeInsets.zero,
      title: entry.sourceTitle.isEmpty
          ? '#${entry.sourceTopicId}'
          : entry.sourceTitle,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (id, icon, label) in actions)
            ListTile(
              leading: Icon(
                icon,
                color: id == 'delete'
                    ? Theme.of(ctx).colorScheme.error
                    : null,
              ),
              title: Text(
                label,
                style: id == 'delete'
                    ? TextStyle(color: Theme.of(ctx).colorScheme.error)
                    : null,
              ),
              onTap: () {
                Navigator.pop(ctx);
                _runEntryAction(id, entry);
              },
            ),
        ],
      ),
    );
  }

  Future<void> _runEntryAction(String id, ExportHistoryEntry entry) async {
    switch (id) {
      case 'open':
        await _handleTap(entry);
      case 'reveal':
        await _revealInFolder(entry.targetRef);
      case 'share':
        if (PublicFileChannel.isContentUri(entry.targetRef)) {
          await PublicFileChannel.shareUri(entry.targetRef);
        } else {
          await ShareUtils.shareFile(XFile(entry.targetRef));
        }
      case 'delete':
        ref.read(exportHistoryProvider.notifier).remove(entry.id);
    }
  }

  Future<void> _handleTap(ExportHistoryEntry entry) async {
    switch (entry.targetType) {
      case ExportHistoryTarget.notion:
        final uri = Uri.tryParse(entry.targetRef);
        if (uri == null) return;
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        break;
      case ExportHistoryTarget.localFile:
        await _handleLocalFile(entry);
        break;
      case ExportHistoryTarget.shared:
        // 分享出去的没有本地副本可打开，说清楚而不是报「文件已不存在」
        ToastService.showInfo(S.current.exportHistory_sharedNoFile);
        break;
    }
  }

  Future<void> _handleLocalFile(ExportHistoryEntry entry) async {
    final path = entry.targetRef;
    if (path.isEmpty) {
      ToastService.showError(S.current.exportHistory_fileNotFound);
      return;
    }
    // Android 落公共目录 / SAF 另存为拿到的是 content uri，不能用 File 判断
    // 存在性，也不能交给 OpenFilex，只能让系统按 uri 授权打开。
    if (path.startsWith('content://')) {
      // 落盘时没写 MIME_TYPE（避免 MediaStore 改扩展名），这里按格式补一个
      // 系统认得的类型，否则 ACTION_VIEW 匹配不到任何应用。
      final mime = entry.format == ExportHistoryFormat.html
          ? 'text/html'
          : 'text/plain';
      final opened = await PublicFileChannel.openUri(path, mimeType: mime);
      if (!opened && mounted) {
        ToastService.showError(S.current.exportHistory_openFailed);
      }
      return;
    }
    if (!File(path).existsSync()) {
      ToastService.showError(S.current.exportHistory_fileNotFound);
      return;
    }
    if (PlatformUtils.isDesktop) {
      await _revealInFolder(path);
      return;
    }
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && mounted) {
      ToastService.showError(S.current.exportHistory_openFailed);
    }
  }

  Future<void> _revealInFolder(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', ['-R', path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', path]);
      } else if (Platform.isLinux) {
        // xdg-open 不能定位单文件，降级到打开父目录。
        await Process.run('xdg-open', [p.dirname(path)]);
      }
    } catch (_) {
      ToastService.showError(S.current.share_saveFailed);
    }
  }

  void _confirmClear() {
    showAppDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.exportHistory_clearAll),
        content: Text(S.current.exportHistory_clearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () {
              ref.read(exportHistoryProvider.notifier).clear();
              Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(S.current.exportHistory_clearAll),
          ),
        ],
      ),
    );
  }
}

/// 顶部右上的过滤菜单。激活态在图标上叠加一个小圆点。
///
/// Flutter 的 [PopupMenuButton] 在 `PopupMenuItem.value` 为 null 时会被
/// 当作"取消选择"，导致"全部"这一项点了不触发回调。这里用 String sentinel
/// 当作 value，回调时再翻译成 `ExportHistoryFormat?`。
class _FilterMenu extends StatelessWidget {
  const _FilterMenu({required this.current, required this.onChange});

  final ExportHistoryFormat? current;
  final ValueChanged<ExportHistoryFormat?> onChange;

  static const String _allKey = '__all__';

  String _keyFor(ExportHistoryFormat? f) => f?.code ?? _allKey;
  ExportHistoryFormat? _formatFor(String key) =>
      key == _allKey ? null : ExportHistoryFormat.fromCode(key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = current != null;
    final items = <(ExportHistoryFormat?, String)>[
      (null, context.l10n.exportHistory_filterAll),
      (ExportHistoryFormat.markdown, 'Markdown'),
      (ExportHistoryFormat.html, 'HTML'),
      (ExportHistoryFormat.notion, 'Notion'),
    ];
    return SwipeDismissiblePopupMenuButton<String>(
      tooltip: context.l10n.exportHistory_filterAll,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Symbols.filter_list_rounded),
          if (active)
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 1.2,
                  ),
                ),
              ),
            ),
        ],
      ),
      onSelected: (key) => onChange(_formatFor(key)),
      itemBuilder: (context) => [
        for (final (value, label) in items)
          PopupMenuItem(
            value: _keyFor(value),
            child: Row(
              children: [
                Icon(
                  current == value
                      ? Symbols.check_rounded
                      : Symbols.circle_rounded,
                  size: 16,
                  color: current == value
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline.withValues(alpha: 0.3),
                ),
                const SizedBox(width: 12),
                Text(label),
              ],
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Symbols.history_edu_rounded,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.exportHistory_empty,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportEntryCard extends StatelessWidget {
  const _ExportEntryCard({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
  });

  final ExportHistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  static const _kFormatBlue = Color(0xFF3B82F6);
  static const _kFormatOrange = Color(0xFFF97316);
  static const _kFormatPurple = Color(0xFF8B5CF6);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = _accentColor;
    final failed = entry.status == ExportHistoryStatus.failed;

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧 icon
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_icon, color: accent, size: 20),
              ),
              const SizedBox(width: 12),
              // 中间内容
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.sourceTitle.isEmpty
                                ? '#${entry.sourceTopicId}'
                                : entry.sourceTitle,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              height: 1.3,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _FormatPill(label: _formatLabel, color: accent),
                      ],
                    ),
                    const SizedBox(height: 6),
                    DefaultTextStyle.merge(
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11.5,
                      ),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(TimeUtils.formatRelativeTime(entry.createdAt)),
                          if (entry.postCount != null)
                            Text(
                              context.l10n
                                  .exportHistory_postCount(entry.postCount!),
                            ),
                          if (entry.size != null && entry.size! > 0)
                            Text(_formatSize(entry.size!)),
                          if (failed)
                            Text(
                              context.l10n.exportHistory_statusFailed,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Icon(
                  _trailingIcon,
                  color: theme.colorScheme.outline.withValues(alpha: 0.5),
                  size: 18,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData get _icon => switch (entry.format) {
    ExportHistoryFormat.markdown => Symbols.description_rounded,
    ExportHistoryFormat.html => Symbols.public_rounded,
    ExportHistoryFormat.notion => Symbols.cloud_sync_rounded,
  };

  Color get _accentColor => switch (entry.format) {
    ExportHistoryFormat.markdown => _kFormatBlue,
    ExportHistoryFormat.html => _kFormatOrange,
    ExportHistoryFormat.notion => _kFormatPurple,
  };

  String get _formatLabel => switch (entry.format) {
    ExportHistoryFormat.markdown => 'MD',
    ExportHistoryFormat.html => 'HTML',
    ExportHistoryFormat.notion => 'Notion',
  };

  IconData get _trailingIcon => switch (entry.targetType) {
    ExportHistoryTarget.notion => Symbols.north_east_rounded,
    ExportHistoryTarget.shared => Symbols.share_rounded,
    ExportHistoryTarget.localFile => PlatformUtils.isDesktop
        ? Symbols.folder_open_rounded
        : Symbols.file_open_rounded,
  };

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _FormatPill extends StatelessWidget {
  const _FormatPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
