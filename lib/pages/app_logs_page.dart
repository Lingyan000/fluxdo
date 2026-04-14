import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cross_file/cross_file.dart';

import '../services/app_error_handler.dart';
import '../utils/share_utils.dart';
import '../services/discourse/discourse_service.dart';
import '../services/log/logger_utils.dart';
import '../services/network/adapters/platform_adapter.dart';
import '../services/toast_service.dart';
import '../widgets/common/dismissible_popup_menu.dart';
import '../widgets/post/reply_sheet.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';

/// 日志筛选类型
enum _LogFilter { all, error, request, lifecycle }

/// 应用日志查看页面
class AppLogsPage extends StatefulWidget {
  const AppLogsPage({super.key});

  @override
  State<AppLogsPage> createState() => _AppLogsPageState();
}

class _AppLogsPageState extends State<AppLogsPage> {
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;
  _LogFilter _filter = _LogFilter.all;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  List<Map<String, dynamic>> get _filteredEntries {
    switch (_filter) {
      case _LogFilter.all:
        return _entries;
      case _LogFilter.error:
        return _entries.where((e) => e['level'] == 'error').toList();
      case _LogFilter.request:
        return _entries.where((e) => e['type'] == 'request').toList();
      case _LogFilter.lifecycle:
        return _entries.where((e) => e['type'] == 'lifecycle').toList();
    }
  }

  Future<void> _loadLogs() async {
    setState(() => _loading = true);
    final entries = await LoggerUtils.readLogEntries();
    if (mounted) {
      setState(() {
        _entries = entries;
        _loading = false;
      });
    }
  }

  Future<void> _copyDeviceInfo() async {
    final text = await LoggerUtils.getDeviceInfoText();
    await Clipboard.setData(ClipboardData(text: text));
    ToastService.showSuccess(S.current.common_copiedToClipboard);
  }

  Future<void> _copyAll() async {
    final content = await LoggerUtils.readLogContent();
    if (content.trim().isEmpty) {
      ToastService.showInfo(S.current.appLogs_noLogs);
      return;
    }
    await Clipboard.setData(ClipboardData(text: content));
    ToastService.showSuccess(S.current.common_copiedToClipboard);
  }

  Future<void> _shareLog() async {
    final path = await LoggerUtils.getShareFilePath();
    await ShareUtils.shareOrSaveFile(
      XFile(path),
      subject: S.current.appLogs_shareSubject,
    );
  }

  Future<void> _clearLogs() async {
    final confirmed = await showAppDialog<bool>(
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
            child: Text(context.l10n.common_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await LoggerUtils.clearLogs();
      await _loadLogs();
      ToastService.showSuccess(S.current.appLogs_logsCleared);
    }
  }

  /// 打开私信界面，预填设备信息、日志摘要和完整日志附件
  Future<void> _sendFeedback() async {
    try {
      // 并行：获取设备信息、读取日志内容、上传完整日志文件
      final deviceInfoFuture = LoggerUtils.getDeviceInfoText();
      final logContentFuture = LoggerUtils.readLogContent();
      final uploadFuture = _uploadLogFile();
      final deviceInfo = await deviceInfoFuture;
      final logContent = await logContentFuture;
      final attachmentMarkdown = await uploadFuture;

      if (!mounted) return;

      final buf = StringBuffer()
        ..writeln('## 设备信息')
        ..writeln('```')
        ..writeln(deviceInfo)
        ..writeln('```')
        ..writeln();

      // 完整日志附件
      if (attachmentMarkdown != null) {
        buf
          ..writeln('## 完整日志')
          ..writeln(attachmentMarkdown)
          ..writeln();
      }

      // 行内日志摘要（截断避免超长）
      buf.writeln('## 日志摘要');
      buf.writeln('```');
      const maxLogLength = 30000;
      if (logContent.length > maxLogLength) {
        buf.writeln('... (已截断，仅保留最近日志)');
        buf.writeln(logContent.substring(logContent.length - maxLogLength));
      } else {
        buf.writeln(logContent.isEmpty ? '(无日志)' : logContent);
      }
      buf.writeln('```');

      showReplySheet(
        context: context,
        targetUsername: 'pyteng',
        initialTitle: S.current.appLogs_feedbackTitle,
        initialContent: buf.toString(),
      );
    } on DioException catch (_) {
      // 网络错误已由 ErrorInterceptor 处理
    } catch (e, s) {
      AppErrorHandler.handleUnexpected(e, s);
    }
  }

  /// 上传完整日志文件（.txt），返回附件 markdown；失败返回 null
  Future<String?> _uploadLogFile() async {
    try {
      final jsonlPath = await LoggerUtils.getShareFilePath();
      // 复制为 .txt，避免 .jsonl 不在服务器 authorized_extensions 中
      final txtPath = jsonlPath.replaceAll('.jsonl', '.txt');
      await File(jsonlPath).copy(txtPath);
      final result = await DiscourseService().uploadFile(txtPath);
      return result.toAutoMarkdown();
    } catch (e) {
      debugPrint('[AppLogsPage] 上传日志文件失败: $e');
      return null;
    }
  }

  /// 根据 level 获取图标和颜色
  (IconData, Color) _getIconAndColor(Map<String, dynamic> entry) {
    final level = entry['level']?.toString() ?? 'error';
    final type = entry['type']?.toString() ?? 'general';

    if (type == 'request') {
      return (Icons.http, Colors.blue);
    }

    if (type == 'lifecycle') {
      final event = entry['event']?.toString() ?? '';
      return switch (event) {
        'app_start' => (Icons.rocket_launch_outlined, Colors.teal),
        'login' => (Icons.login, Colors.green),
        'logout_active' => (Icons.logout, Colors.blueGrey),
        'logout_passive' => (Icons.logout, Colors.orange),
        _ => (Icons.timeline, Colors.teal),
      };
    }

    switch (level) {
      case 'error':
        return (Icons.error_outline, Colors.red);
      case 'warning':
        return (Icons.warning_amber_outlined, Colors.orange);
      case 'info':
        return (Icons.info_outline, Colors.grey);
      default:
        return (Icons.article_outlined, Colors.grey);
    }
  }

  /// 获取卡片标题
  String _getTitle(Map<String, dynamic> entry) {
    final type = entry['type']?.toString() ?? 'general';
    if (type == 'request') {
      final method = entry['method']?.toString() ?? '';
      final url = entry['url']?.toString() ?? '';
      // 只显示路径部分
      final uri = Uri.tryParse(url);
      final path = uri?.path ?? url;
      return '$method $path';
    }

    if (type == 'lifecycle') {
      return entry['message']?.toString() ?? S.current.appLogs_lifecycleEvent;
    }

    final tag = entry['tag']?.toString();
    final errorType = entry['errorType']?.toString();
    final message = entry['message']?.toString() ?? S.current.error_unknown;

    if (tag != null && errorType != null) {
      return '[$tag] $errorType';
    }
    if (errorType != null && entry['level'] == 'error') {
      return errorType;
    }
    if (tag != null) {
      return '[$tag] $message';
    }
    return message;
  }

  /// 获取卡片副标题
  String _getSubtitle(Map<String, dynamic> entry) {
    final type = entry['type']?.toString() ?? 'general';
    if (type == 'request') {
      final statusCode = entry['statusCode'];
      final duration = entry['duration'];
      final adapter = _getRequestAdapterLabel(entry);
      final parts = <String>[];
      if (statusCode != null) parts.add('$statusCode');
      if (duration != null) parts.add('${duration}ms');
      if (adapter != null) parts.add(adapter);
      return parts.join(' · ');
    }

    if (type == 'lifecycle') {
      final parts = <String>[];
      final username = entry['username']?.toString();
      final reason = entry['reason']?.toString();
      if (username != null) parts.add('${S.current.appLogs_user}: $username');
      if (reason != null) parts.add(reason);
      return parts.join(' · ');
    }

    final level = entry['level']?.toString() ?? 'error';
    if (level == 'error') {
      return entry['error']?.toString() ?? S.current.error_unknown;
    }
    return entry['message']?.toString() ?? '';
  }

  void _showDetail(Map<String, dynamic> entry) {
    final type = entry['type']?.toString() ?? 'general';
    if (type == 'request') {
      _showRequestDetail(entry);
    } else if (type == 'lifecycle') {
      _showLifecycleDetail(entry);
    } else {
      _showGeneralDetail(entry);
    }
  }

  void _showLifecycleDetail(Map<String, dynamic> entry) {
    final timestamp = entry['timestamp']?.toString() ?? '';
    final event = entry['event']?.toString() ?? '';
    final message = entry['message']?.toString() ?? '';
    final username = entry['username']?.toString();
    final reason = entry['reason']?.toString();
    final appVersion = entry['appVersion']?.toString();

    final eventLabel = switch (event) {
      'app_start' => S.current.appLogs_appStart,
      'login' => S.current.appLogs_userLogin,
      'logout_active' => S.current.appLogs_logoutActive,
      'logout_passive' => S.current.appLogs_logoutPassive,
      _ => event,
    };

    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Expanded(
              child: Text(
                eventLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              onPressed: () {
                final detail = StringBuffer()
                  ..writeln('${S.current.appLogs_time}: $timestamp')
                  ..writeln('${S.current.appLogs_event}: $eventLabel');
                if (appVersion != null) detail.writeln('${S.current.appLogs_version}: $appVersion');
                detail.writeln('${S.current.appLogs_message}: $message');
                if (username != null) detail.writeln('${S.current.appLogs_user}: $username');
                if (reason != null) detail.writeln('${S.current.appLogs_reason}: $reason');
                Clipboard.setData(ClipboardData(text: detail.toString()));
                ToastService.showSuccess(S.current.common_copiedToClipboard);
              },
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailField(context.l10n.appLogs_time, timestamp),
              if (appVersion != null) _buildDetailField(context.l10n.appLogs_version, appVersion),
              _buildDetailField(context.l10n.appLogs_event, eventLabel),
              _buildDetailField(context.l10n.appLogs_message, message),
              if (username != null) _buildDetailField(context.l10n.appLogs_user, username),
              if (reason != null) _buildDetailField(context.l10n.appLogs_reason, reason),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_close),
          ),
        ],
      ),
    );
  }

  void _showGeneralDetail(Map<String, dynamic> entry) {
    final level = entry['level']?.toString() ?? 'error';
    final message = entry['message']?.toString() ?? '';
    final error = entry['error']?.toString();
    final errorType = entry['errorType']?.toString();
    final rawTrace = entry['stackTrace']?.toString();
    final stackTrace = rawTrace != null && rawTrace.trim().isNotEmpty
        ? rawTrace
        : null;
    final timestamp = entry['timestamp']?.toString() ?? '';
    final tag = entry['tag']?.toString();
    final appVersion = entry['appVersion']?.toString();

    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Expanded(
              child: Text(
                tag != null ? '[$tag]' : level.toUpperCase(),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              onPressed: () {
                final detail = StringBuffer()
                  ..writeln('${S.current.appLogs_time}: $timestamp')
                  ..writeln('${S.current.appLogs_level}: $level');
                if (appVersion != null) detail.writeln('${S.current.appLogs_version}: $appVersion');
                if (tag != null) detail.writeln('${S.current.appLogs_tag}: $tag');
                detail.writeln('${S.current.appLogs_message}: $message');
                if (error != null && error != message) {
                  detail.writeln('${S.current.appLogs_error}: $error');
                }
                if (errorType != null) detail.writeln('${S.current.appLogs_type}: $errorType');
                if (stackTrace != null) {
                  detail
                    ..writeln()
                    ..writeln('${S.current.appLogs_stack}:')
                    ..writeln(stackTrace);
                }
                Clipboard.setData(ClipboardData(text: detail.toString()));
                ToastService.showSuccess(S.current.common_copiedToClipboard);
              },
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailField(context.l10n.appLogs_time, timestamp),
              if (appVersion != null) _buildDetailField(context.l10n.appLogs_version, appVersion),
              _buildDetailField(context.l10n.appLogs_message, message),
              if (error != null && error != message)
                _buildDetailField(context.l10n.appLogs_error, error),
              if (errorType != null) _buildDetailField(context.l10n.appLogs_errorType, errorType),
              if (stackTrace != null) ...[
                const SizedBox(height: 12),
                Text(
                  context.l10n.appLogs_stackTrace,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    stackTrace,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_close),
          ),
        ],
      ),
    );
  }

  void _showRequestDetail(Map<String, dynamic> entry) {
    final timestamp = entry['timestamp']?.toString() ?? '';
    final method = entry['method']?.toString() ?? '';
    final url = entry['url']?.toString() ?? '';
    final statusCode = entry['statusCode']?.toString() ?? '';
    final duration = entry['duration'];
    final level = entry['level']?.toString() ?? 'info';
    final adapter = _getRequestAdapterLabel(entry);

    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Expanded(
              child: Text(
                '$method ${context.l10n.appLogs_request}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              onPressed: () {
                final detail = StringBuffer()
                  ..writeln('${S.current.appLogs_time}: $timestamp')
                  ..writeln('${S.current.appLogs_method}: $method')
                  ..writeln('URL: $url')
                  ..writeln('${S.current.appLogs_statusCode}: $statusCode');
                if (duration != null) detail.writeln('${S.current.appLogs_duration}: ${duration}ms');
                if (adapter != null) {
                  detail.writeln('${S.current.networkAdapter_adapterType}: $adapter');
                }
                detail.writeln('${S.current.appLogs_level}: $level');
                Clipboard.setData(ClipboardData(text: detail.toString()));
                ToastService.showSuccess(S.current.common_copiedToClipboard);
              },
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailField(context.l10n.appLogs_time, timestamp),
              _buildDetailField(context.l10n.appLogs_method, method),
              _buildDetailField('URL', url),
              _buildDetailField(context.l10n.appLogs_statusCode, statusCode),
              if (duration != null)
                _buildDetailField(context.l10n.appLogs_duration, '${duration}ms'),
              if (adapter != null)
                _buildDetailField(
                  context.l10n.networkAdapter_adapterType,
                  adapter,
                ),
              _buildDetailField(context.l10n.appLogs_level, level == 'warning' ? context.l10n.common_loadFailed : context.l10n.common_done),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.common_close),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  String? _getRequestAdapterLabel(Map<String, dynamic> entry) {
    final adapterName = entry['networkAdapter']?.toString();
    final adapterType = tryParseAdapterType(adapterName);
    if (adapterType == null) {
      return adapterName?.isEmpty == true ? null : adapterName;
    }
    return getAdapterDisplayName(adapterType);
  }

  String _formatTimestamp(String? timestamp) {
    if (timestamp == null) return '';
    final time = DateTime.tryParse(timestamp);
    if (time == null) return timestamp;
    final local = time.toLocal();
    return '${local.month}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.appLogs_title),
        centerTitle: true,
        actions: [
          SwipeDismissiblePopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'deviceInfo':
                  _copyDeviceInfo();
                case 'copy':
                  _copyAll();
                case 'share':
                  _shareLog();
                case 'feedback':
                  _sendFeedback();
                case 'clear':
                  _clearLogs();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'deviceInfo',
                child: ListTile(
                  leading: const Icon(Icons.smartphone),
                  title: Text(context.l10n.appLogs_copyDeviceInfo),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'copy',
                child: ListTile(
                  leading: const Icon(Icons.copy),
                  title: Text(context.l10n.appLogs_copyAll),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'share',
                child: ListTile(
                  leading: const Icon(Icons.share),
                  title: Text(context.l10n.appLogs_shareLogs),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'feedback',
                child: ListTile(
                  leading: const Icon(Icons.mail_outline),
                  title: Text(context.l10n.appLogs_sendFeedback),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(context.l10n.appLogs_clearLogs),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.article_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.appLogs_noLogs,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      );
    }

    final filtered = _filteredEntries;

    return Column(
      children: [
        // 筛选栏
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              _buildFilterChip(context.l10n.common_all, _LogFilter.all),
              const SizedBox(width: 8),
              _buildFilterChip(context.l10n.appLogs_error, _LogFilter.error),
              const SizedBox(width: 8),
              _buildFilterChip(context.l10n.appLogs_request, _LogFilter.request),
              const SizedBox(width: 8),
              _buildFilterChip(context.l10n.appLogs_lifecycle, _LogFilter.lifecycle),
            ],
          ),
        ),
        // 日志列表
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    context.l10n.appLogs_noMatchingLogs,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadLogs,
                  child: ListView.builder(
                    itemCount: filtered.length,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      final (icon, color) = _getIconAndColor(entry);
                      final title = _getTitle(entry);
                      final subtitle = _getSubtitle(entry);
                      final timestamp =
                          _formatTimestamp(entry['timestamp']?.toString());

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: Icon(icon, color: color),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (subtitle.isNotEmpty)
                                Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                ),
                              const SizedBox(height: 4),
                              Text(
                                timestamp,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline,
                                    ),
                              ),
                            ],
                          ),
                          onTap: () => _showDetail(entry),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildFilterChip(String label, _LogFilter filter) {
    final selected = _filter == filter;
    return FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (value) {
        setState(() => _filter = filter);
      },
    );
  }
}
