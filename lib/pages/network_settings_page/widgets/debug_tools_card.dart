import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../l10n/s.dart';
import '../../../utils/share_utils.dart';
import '../../../services/network_logger.dart';
import '../../../utils/dialog_utils.dart';
import '../../../services/cf_challenge_logger.dart';
import '../../../services/toast_service.dart';

/// 调试工具卡片
class DebugToolsCard extends StatefulWidget {
  const DebugToolsCard({super.key});

  @override
  State<DebugToolsCard> createState() => _DebugToolsCardState();
}

class _DebugToolsCardState extends State<DebugToolsCard> {
  bool _isDeveloperMode = false;

  @override
  void initState() {
    super.initState();
    _loadDeveloperMode();
  }

  Future<void> _loadDeveloperMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isDeveloperMode = prefs.getBool('developer_mode') ?? false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(context.l10n.appLogs_title),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: _showLogSheet,
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: Text(context.l10n.appLogs_shareLogs),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: _shareLogs,
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
          ListTile(
            leading: Icon(Icons.delete_sweep_outlined, color: theme.colorScheme.error),
            title: Text(context.l10n.appLogs_clearLogs, style: TextStyle(color: theme.colorScheme.error)),
            trailing: Icon(Icons.chevron_right, size: 20, color: theme.colorScheme.error),
            onTap: _clearLogs,
          ),
          // CF 验证日志（开发者模式）
          if (_isDeveloperMode) ...[
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('CF 验证日志'),
              subtitle: const Text('查看 Cloudflare 验证详情'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: _showCfChallengeLogSheet,
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('导出 CF 日志'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: _shareCfChallengeLogs,
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
            ListTile(
              leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
              title: Text('清除 CF 日志', style: TextStyle(color: theme.colorScheme.error)),
              trailing: Icon(Icons.chevron_right, size: 20, color: theme.colorScheme.error),
              onTap: _clearCfChallengeLogs,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showLogSheet() async {
    final logs = await NetworkLogger.readLogs();
    if (!mounted) return;

    final theme = Theme.of(context);
    await showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                // 拖动条
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 标题栏
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        '调试日志',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: context.l10n.common_copy,
                        onPressed: logs == null || logs.isEmpty
                            ? null
                            : () {
                                Clipboard.setData(ClipboardData(text: logs));
                                ToastService.showSuccess(S.current.common_copiedToClipboard);
                              },
                      ),
                      IconButton(
                        icon: const Icon(Icons.share),
                        tooltip: context.l10n.common_share,
                        onPressed: logs == null || logs.isEmpty
                            ? null
                            : () {
                                Navigator.pop(context);
                                _shareLogs();
                              },
                      ),
                    ],
                  ),
                ),
                const Divider(),
                // 日志内容
                Expanded(
                  child: logs == null || logs.isEmpty
                      ? _buildEmptyLog(theme)
                      : SingleChildScrollView(
                          controller: scrollController,
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(
                            logs,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.5,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyLog(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.article_outlined,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.appLogs_noLogs,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '启用 DOH 并发起请求后会产生日志',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareLogs() async {
    final logs = await NetworkLogger.readLogs();
    if (logs == null || logs.isEmpty) {
      if (!mounted) return;
      ToastService.showInfo('暂无日志可分享');
      return;
    }

    final path = await NetworkLogger.getLogPath();
    if (path != null) {
      await ShareUtils.shareOrSaveFile(XFile(path), subject: 'DOH 调试日志');
    } else {
      await SharePlus.instance.share(ShareParams(text: logs, subject: 'DOH 调试日志'));
    }
  }

  Future<void> _clearLogs() async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.appLogs_clearTitle),
        content: Text(context.l10n.appLogs_clearContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(context.l10n.common_clear),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await NetworkLogger.clear();
      if (mounted) {
        ToastService.showSuccess(S.current.appLogs_logsCleared);
      }
    }
  }

  Future<void> _showCfChallengeLogSheet() async {
    final logs = await CfChallengeLogger.readLogs();
    if (!mounted) return;

    final theme = Theme.of(context);
    await showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                // 拖动条
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 标题栏
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        'CF 验证日志',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: context.l10n.common_copy,
                        onPressed: logs == null || logs.isEmpty
                            ? null
                            : () {
                                Clipboard.setData(ClipboardData(text: logs));
                                ToastService.showSuccess(S.current.common_copiedToClipboard);
                              },
                      ),
                      IconButton(
                        icon: const Icon(Icons.share),
                        tooltip: context.l10n.common_share,
                        onPressed: logs == null || logs.isEmpty
                            ? null
                            : () {
                                Navigator.pop(context);
                                _shareCfChallengeLogs();
                              },
                      ),
                    ],
                  ),
                ),
                const Divider(),
                // 日志内容
                Expanded(
                  child: logs == null || logs.isEmpty
                      ? _buildEmptyCfLog(theme)
                      : SingleChildScrollView(
                          controller: scrollController,
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(
                            logs,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.5,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildEmptyCfLog(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bug_report_outlined,
            size: 64,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无 CF 验证日志',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '触发 CF 验证后会产生日志',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareCfChallengeLogs() async {
    final logs = await CfChallengeLogger.readLogs();
    if (logs == null || logs.isEmpty) {
      if (!mounted) return;
      ToastService.showInfo('暂无 CF 日志可分享');
      return;
    }

    final path = await CfChallengeLogger.getLogPath();
    if (path != null) {
      await ShareUtils.shareOrSaveFile(XFile(path), subject: 'CF 验证日志');
    } else {
      await SharePlus.instance.share(ShareParams(text: logs, subject: 'CF 验证日志'));
    }
  }

  Future<void> _clearCfChallengeLogs() async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.appLogs_clearTitle),
        content: Text(context.l10n.appLogs_clearContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(context.l10n.common_clear),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await CfChallengeLogger.clear();
      if (mounted) {
        ToastService.showSuccess(S.current.appLogs_logsCleared);
      }
    }
  }
}
