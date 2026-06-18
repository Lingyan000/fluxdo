import 'dart:io';

import 'package:ai_model_manager/ai_model_manager.dart'
    show SwipeActionCell, SwipeAction, SwipeActionScope;
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../l10n/s.dart';
import '../providers/export_history_provider.dart';
import '../services/toast_service.dart';
import 'package:common_ui/common_ui.dart';
import '../storage/export_history_dao.dart';
import '../utils/dialog_utils.dart';
import '../utils/platform_utils.dart';
import '../utils/share_utils.dart';
import '../utils/time_utils.dart';

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
              icon: const Icon(Icons.delete_sweep_rounded),
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
                        icon: Icons.delete_outline,
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
                    ),
                  );
                },
              ),
            ),
    );
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
    }
  }

  Future<void> _handleLocalFile(ExportHistoryEntry entry) async {
    final path = entry.targetRef;
    if (path.isEmpty || !File(path).existsSync()) {
      ToastService.showError(S.current.exportHistory_fileNotFound);
      return;
    }
    if (PlatformUtils.isDesktop) {
      await _revealInFolder(path);
      return;
    }
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && mounted) {
      await ShareUtils.shareOrSaveFile(XFile(path));
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
          const Icon(Icons.filter_list_rounded),
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
                      ? Icons.check_rounded
                      : Icons.circle_outlined,
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
            Icons.history_edu_rounded,
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
  const _ExportEntryCard({required this.entry, required this.onTap});

  final ExportHistoryEntry entry;
  final VoidCallback onTap;

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
    ExportHistoryFormat.markdown => Icons.description_rounded,
    ExportHistoryFormat.html => Icons.public_rounded,
    ExportHistoryFormat.notion => Icons.cloud_sync_rounded,
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
    ExportHistoryTarget.notion => Icons.north_east_rounded,
    ExportHistoryTarget.localFile => PlatformUtils.isDesktop
        ? Icons.folder_open_rounded
        : Icons.ios_share_rounded,
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
