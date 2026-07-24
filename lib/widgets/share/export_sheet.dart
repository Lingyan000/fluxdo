import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../../models/topic.dart';
import '../../l10n/s.dart';
import '../../pages/notion_settings_page.dart';
import '../../providers/export_history_provider.dart';
import '../../providers/notion_config_provider.dart';
import '../../services/notion/notion_client.dart';
import '../../services/notion/notion_config.dart';
import '../../services/notion/notion_sync_service.dart';
import '../../services/toast_service.dart';
import '../../storage/export_history_dao.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/export_utils.dart';
import '../common/app_bottom_sheet.dart';

/// 用户在 sheet 上选的"目标"。
/// 本地 MD/HTML 走 ExportUtils.exportTopic；Notion 走 NotionSyncService。
enum _ExportTarget { md, html, notion }

/// 导出选项 Sheet
class ExportSheet extends ConsumerStatefulWidget {
  /// 话题详情
  final TopicDetail detail;

  const ExportSheet({super.key, required this.detail});

  /// 显示导出 Sheet
  static Future<void> show(BuildContext context, TopicDetail detail) {
    return showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ExportSheet(detail: detail),
    );
  }

  @override
  ConsumerState<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends ConsumerState<ExportSheet> {
  ExportScope _scope = ExportScope.firstPostOnly;
  _ExportTarget _target = _ExportTarget.md;
  bool _isExporting = false;
  int _progress = 0;
  int _total = 0;
  String? _phaseLabel; // Notion 同步的阶段文案

  int get _totalPostsCount => widget.detail.postStream.stream.length;

  bool get _willBeLimited =>
      _target == _ExportTarget.md &&
      _scope == ExportScope.allPosts &&
      _totalPostsCount > ExportUtils.maxMarkdownPosts;

  Future<void> _export() async {
    if (_isExporting) return;
    setState(() {
      _isExporting = true;
      _progress = 0;
      _total = 0;
      _phaseLabel = null;
    });

    try {
      switch (_target) {
        case _ExportTarget.md:
        case _ExportTarget.html:
          await _exportLocal();
          break;
        case _ExportTarget.notion:
          await _exportNotion();
          break;
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.export_failed('$e'));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
          _phaseLabel = null;
        });
      }
    }
  }

  Future<void> _exportLocal() async {
    final format = _target == _ExportTarget.md
        ? ExportFormat.markdown
        : ExportFormat.html;
    final result = await ExportUtils.exportTopic(
      detail: widget.detail,
      scope: _scope,
      format: format,
      onProgress: (current, total) {
        if (mounted) {
          setState(() {
            _progress = current;
            _total = total;
          });
        }
      },
    );
    await ref
        .read(exportHistoryProvider.notifier)
        .add(
          ExportHistoryEntry(
            id: const Uuid().v4(),
            sourceType: ExportHistorySource.topic,
            sourceTopicId: widget.detail.id,
            sourceTitle: widget.detail.title,
            format: format == ExportFormat.markdown
                ? ExportHistoryFormat.markdown
                : ExportHistoryFormat.html,
            targetType: ExportHistoryTarget.localFile,
            targetRef: result.finalPath ?? '',
            status: ExportHistoryStatus.success,
            createdAt: DateTime.now(),
            size: result.byteSize,
            postCount: result.postCount,
          ),
        );
    if (mounted) Navigator.pop(context);
  }

  Future<void> _exportNotion() async {
    final cfg = ref.read(notionConfigProvider);
    if (!cfg.isComplete) {
      // 未配置：跳转设置页让用户先配
      final go = await _askGoToSettings();
      if (go == true && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NotionSettingsPage()),
        );
      }
      return;
    }

    final scope = _scope == ExportScope.firstPostOnly
        ? NotionSyncScope.firstPostOnly
        : NotionSyncScope.allPosts;
    final svc = NotionSyncService(config: cfg);

    Future<NotionSyncResult> doSync(DuplicateAction onDup) {
      return svc.syncTopic(
        detail: widget.detail,
        scope: scope,
        onDuplicate: onDup,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _phaseLabel = _labelForPhase(p);
            _progress = p.current;
            _total = p.total;
          });
        },
      );
    }

    NotionSyncResult result;
    try {
      result = await doSync(DuplicateAction.skip);
    } on NotionApiException catch (e) {
      throw Exception(e.message);
    }

    // 命中重复时,弹框让用户选 skip / overwrite
    if (result.duplicated) {
      final action = await _askDuplicate();
      if (action == null) {
        // 用户取消 → 把刚才"命中已有"那条记录也写进历史,
        // 既反映"曾尝试过"也方便用户跳过去原 page
        await _writeNotionHistory(result);
        return;
      }
      if (action == DuplicateAction.overwrite) {
        result = await doSync(DuplicateAction.overwrite);
      }
      // skip 就用原 result
    }

    await _writeNotionHistory(result);
    if (mounted) {
      ToastService.showSuccess(S.current.notion_syncSucceed);
      Navigator.pop(context);
    }
  }

  Future<void> _writeNotionHistory(NotionSyncResult result) {
    return ref
        .read(exportHistoryProvider.notifier)
        .add(
          ExportHistoryEntry(
            id: const Uuid().v4(),
            sourceType: ExportHistorySource.topic,
            sourceTopicId: widget.detail.id,
            sourceTitle: widget.detail.title,
            format: ExportHistoryFormat.notion,
            targetType: ExportHistoryTarget.notion,
            targetRef: result.pageUrl,
            status: ExportHistoryStatus.success,
            createdAt: DateTime.now(),
            postCount: result.postCount,
          ),
        );
  }

  String _labelForPhase(NotionSyncProgress p) {
    switch (p.phase) {
      case SyncPhase.fetch:
        if (p.total > 0) {
          return S.current.notion_syncingFetch(p.current, p.total);
        }
        return S.current.notion_syncing;
      case SyncPhase.convert:
        return S.current.notion_syncingConvert;
      case SyncPhase.create:
        return S.current.notion_syncingCreate;
      case SyncPhase.append:
        return S.current.notion_syncingAppend(p.current, p.total);
      case SyncPhase.done:
        return S.current.notion_syncing;
    }
  }

  Future<bool?> _askGoToSettings() {
    return showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.notion_title),
        content: Text(S.current.notion_notConfigured),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.current.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(S.current.common_confirm),
          ),
        ],
      ),
    );
  }

  Future<DuplicateAction?> _askDuplicate() {
    return showAppDialog<DuplicateAction?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(S.current.notion_duplicateTitle),
        content: Text(S.current.notion_duplicateMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.current.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, DuplicateAction.skip),
            child: Text(S.current.notion_duplicateSkip),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, DuplicateAction.overwrite),
            child: Text(S.current.notion_duplicateOverwrite),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 订阅 notionConfigProvider,保证它在打开 sheet 的整段生命周期里都在
    // 重建到 username 解析完后的"已配置"状态。否则首次进入时 ref.read
    // 拿到的可能是 username 还在 loading 时构造的空 cfg,误判"未配置"。
    ref.watch(notionConfigProvider);

    return AppSheetScaffold(
      title: context.l10n.export_title,
      showCloseButton: false,
      contentPadding: EdgeInsets.zero,
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton.icon(
          onPressed: _isExporting ? null : _export,
          icon: _isExporting
              ? const LoadingSpinner(size: 18, color: Colors.white)
              : const Icon(Symbols.download_rounded),
          label: Text(_buttonLabel(context)),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 4),
          // 导出范围选择
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              context.l10n.export_range,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: M3eButtonGroup<ExportScope>(
              items: [
                M3eButtonGroupItem(
                  value: ExportScope.firstPostOnly,
                  label: Text(context.l10n.export_firstPostOnly),
                  icon: const Icon(Symbols.article_rounded),
                ),
                M3eButtonGroupItem(
                  value: ExportScope.allPosts,
                  label: Text(context.l10n.common_all),
                  icon: const Icon(Symbols.forum_rounded),
                ),
              ],
              selected: _scope,
              onSelected: (scope) {
                setState(() => _scope = scope);
              },
            ),
          ),
          const SizedBox(height: 20),
          // 导出格式选择
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              context.l10n.export_format,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: M3eButtonGroup<_ExportTarget>(
              items: const [
                M3eButtonGroupItem(
                  value: _ExportTarget.md,
                  label: Text('MD'),
                  icon: Icon(Symbols.code_rounded),
                ),
                M3eButtonGroupItem(
                  value: _ExportTarget.html,
                  label: Text('HTML'),
                  icon: Icon(Symbols.html_rounded),
                ),
                M3eButtonGroupItem(
                  value: _ExportTarget.notion,
                  label: Text('Notion'),
                  icon: Icon(Symbols.cloud_sync_rounded),
                ),
              ],
              selected: _target,
              onSelected: (target) {
                setState(() => _target = target);
              },
            ),
          ),
          // Markdown 限制提示
          if (_willBeLimited) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    Symbols.info_rounded,
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      context.l10n.export_markdownLimit(
                        ExportUtils.maxMarkdownPosts,
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _buttonLabel(BuildContext context) {
    if (!_isExporting) return context.l10n.common_export;
    if (_phaseLabel != null) return _phaseLabel!;
    if (_total > 0) {
      return context.l10n.export_exporting(_progress, _total);
    }
    return context.l10n.export_exportingNoProgress;
  }
}
