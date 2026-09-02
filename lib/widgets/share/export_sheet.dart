import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
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
import '../../services/public_file_channel.dart';
import '../../services/toast_service.dart';
import '../../storage/export_history_dao.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/export_utils.dart';
import '../../utils/platform_utils.dart';
import '../../utils/share_utils.dart';
import '../common/app_bottom_sheet.dart';

/// 用户在 sheet 上点的"去向"。
/// 本地 MD/HTML 走 ExportUtils.exportTopic；Notion 走 NotionSyncService。
enum _ExportAction { save, saveAs, share, notion }

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
  ExportFormat _format = ExportFormat.markdown;

  /// 正在执行的去向（null = 空闲）。执行中其余行禁用。
  _ExportAction? _running;
  int _progress = 0;
  int _total = 0;
  String? _phaseLabel; // Notion 同步的阶段文案

  int get _totalPostsCount => widget.detail.postStream.stream.length;

  bool get _willBeLimited =>
      _format == ExportFormat.markdown &&
      _scope == ExportScope.allPosts &&
      _totalPostsCount > ExportUtils.maxMarkdownPosts;

  Future<void> _run(_ExportAction action) async {
    if (_running != null) return;
    setState(() {
      _running = action;
      _progress = 0;
      _total = 0;
      _phaseLabel = null;
    });

    try {
      switch (action) {
        case _ExportAction.save:
          await _exportLocal(ExportDelivery.save);
          break;
        case _ExportAction.saveAs:
          await _exportLocal(ExportDelivery.saveAs);
          break;
        case _ExportAction.share:
          await _exportLocal(ExportDelivery.share);
          break;
        case _ExportAction.notion:
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
          _running = null;
          _phaseLabel = null;
        });
      }
    }
  }

  Future<void> _exportLocal(ExportDelivery delivery) async {
    final result = await ExportUtils.exportTopic(
      detail: widget.detail,
      scope: _scope,
      format: _format,
      delivery: delivery,
      onProgress: (current, total) {
        if (mounted) {
          setState(() {
            _progress = current;
            _total = total;
          });
        }
      },
    );
    // 保存/另存为被用户取消（未选位置）时不写历史、不关闭 sheet
    final isSaving =
        delivery == ExportDelivery.save || delivery == ExportDelivery.saveAs;
    if (isSaving && !result.shared) return;
    await ref
        .read(exportHistoryProvider.notifier)
        .add(
          ExportHistoryEntry(
            id: const Uuid().v4(),
            sourceType: ExportHistorySource.topic,
            sourceTopicId: widget.detail.id,
            sourceTitle: widget.detail.title,
            format: _format == ExportFormat.markdown
                ? ExportHistoryFormat.markdown
                : ExportHistoryFormat.html,
            // 分享不产生本地文件:写临时路径进历史,点开只会是「文件已不存在」,
            // 桌面端还会把用户带到临时目录
            targetType: isSaving
                ? ExportHistoryTarget.localFile
                : ExportHistoryTarget.shared,
            targetRef: isSaving ? (result.finalPath ?? '') : '',
            status: ExportHistoryStatus.success,
            createdAt: DateTime.now(),
            size: result.byteSize,
            postCount: result.postCount,
          ),
        );
    if (isSaving) {
      final name = result.displayName?.isNotEmpty == true
          ? result.displayName!
          : p.basename(result.finalPath ?? '');
      ToastService.showSuccess(S.current.export_savedAs(name));
    }
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
    final notionCfg = ref.watch(notionConfigProvider);
    final busy = _running != null;

    return AppSheetScaffold(
      title: context.l10n.export_title,
      showCloseButton: false,
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 导出范围
          _sectionLabel(theme, context.l10n.export_range),
          M3eButtonGroup<ExportScope>(
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
            onSelected: busy ? (_) {} : (v) => setState(() => _scope = v),
          ),
          const SizedBox(height: 16),
          // 文件格式（只作用于"保存"/"分享"，Notion 固定以页面写入）
          _sectionLabel(theme, context.l10n.export_format),
          M3eButtonGroup<ExportFormat>(
            items: const [
              M3eButtonGroupItem(
                value: ExportFormat.markdown,
                label: Text('Markdown'),
                icon: Icon(Symbols.code_rounded),
              ),
              M3eButtonGroupItem(
                value: ExportFormat.html,
                label: Text('HTML'),
                icon: Icon(Symbols.html_rounded),
              ),
            ],
            selected: _format,
            onSelected: busy ? (_) {} : (v) => setState(() => _format = v),
          ),
          // Markdown 限制提示
          if (_willBeLimited) ...[
            const SizedBox(height: 8),
            Row(
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
          ],
          const SizedBox(height: 16),
          // 去向：点哪个即执行哪个
          _sectionLabel(theme, context.l10n.export_deliverTitle),
          SegmentedCardGroup(
            children: [
              // iOS 没有「公共目录」这一说:沙盒外无处可写,Documents 里躺着
              // 数据库/cookie/日志(不能靠 UIFileSharingEnabled 整目录暴露),
              // 所以那边只给「另存为」,由用户导出到「文件」App。
              if (PlatformUtils.isDesktop || PublicFileChannel.hasPublicDownloads)
                _deliveryTile(
                  theme,
                  action: _ExportAction.save,
                  icon: Symbols.save_rounded,
                  title: context.l10n.export_deliverSave,
                  subtitle: PlatformUtils.isDesktop
                      ? context.l10n.export_deliverSaveDescDesktop
                      : context.l10n.export_deliverSaveDescMobile,
                ),
              // 桌面端「保存」本身就是另存为对话框，不必重复这一行
              if (!PlatformUtils.isDesktop)
                _deliveryTile(
                  theme,
                  action: _ExportAction.saveAs,
                  icon: Symbols.drive_folder_upload_rounded,
                  title: context.l10n.export_deliverSaveAs,
                  subtitle: context.l10n.export_deliverSaveAsDesc,
                ),
              // Linux 上 share_plus 不支持分享文件，隐藏该入口
              if (ShareUtils.canShareFiles)
                _deliveryTile(
                  theme,
                  action: _ExportAction.share,
                  icon: Symbols.share_rounded,
                  title: context.l10n.export_deliverShare,
                  subtitle: context.l10n.export_deliverShareDesc,
                ),
              _deliveryTile(
                theme,
                action: _ExportAction.notion,
                icon: Symbols.cloud_sync_rounded,
                title: context.l10n.export_deliverNotion,
                subtitle: notionCfg.isComplete
                    ? context.l10n.export_deliverNotionDesc
                    : context.l10n.export_deliverNotionUnconfigured,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 一行去向。执行中的那行显示进度文案与转圈，其余行禁用。
  Widget _deliveryTile(
    ThemeData theme, {
    required _ExportAction action,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final cs = theme.colorScheme;
    final isRunning = _running == action;
    final disabled = _running != null && !isRunning;

    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: ListTile(
        enabled: _running == null,
        onTap: () => _run(action),
        leading: Icon(icon, color: cs.primary),
        title: Text(
          title,
          // 显式给色：执行中整行 enabled=false，否则文字会被 ListTile 灰化
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
        subtitle: Text(
          isRunning ? _progressLabel(context) : subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: isRunning ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
        trailing: isRunning
            ? LoadingSpinner(size: 18, color: cs.primary)
            : Icon(Symbols.chevron_right_rounded, color: cs.onSurfaceVariant),
      ),
    );
  }

  String _progressLabel(BuildContext context) {
    if (_phaseLabel != null) return _phaseLabel!;
    if (_total > 0) {
      return context.l10n.export_exporting(_progress, _total);
    }
    return context.l10n.export_exportingNoProgress;
  }
}
