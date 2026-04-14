import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cross_file/cross_file.dart';
import 'package:ai_model_manager/ai_model_manager.dart';

import '../l10n/s.dart';
import '../utils/share_utils.dart';
import '../providers/app_state_refresher.dart';
import '../providers/core_providers.dart';
import '../providers/theme_provider.dart';
import '../utils/dialog_utils.dart';
import '../services/data_management/cache_size_service.dart';
import '../services/data_management/data_backup_service.dart';
import '../services/discourse_cache_manager.dart';
import '../services/toast_service.dart';
import '../settings/definitions/data_management_defs.dart';
import '../widgets/settings/settings_group_page.dart';

/// 数据管理页面（数据驱动版）
class DataManagementPage extends StatelessWidget {
  final String? highlightId;

  const DataManagementPage({super.key, this.highlightId});

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: context.l10n.dataManagement_title,
      groupsBuilder: buildDataManagementGroups,
      highlightId: highlightId,
    );
  }
}

// ─────────────────────────────────────────────
// 缓存管理区块（有状态，被 CustomModel 包装）
// ─────────────────────────────────────────────

/// 缓存管理区块，封装了缓存大小加载和清除逻辑
class CacheManagementSection extends ConsumerStatefulWidget {
  const CacheManagementSection({super.key});

  @override
  ConsumerState<CacheManagementSection> createState() =>
      _CacheManagementSectionState();
}

class _CacheManagementSectionState
    extends ConsumerState<CacheManagementSection> {
  int _imageCacheSize = -1;
  int _aiChatDataSize = -1;
  int _cookieCacheSize = -1;
  bool _isClearing = false;

  @override
  void initState() {
    super.initState();
    _loadCacheSizes();
  }

  Future<void> _loadCacheSizes() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final results = await Future.wait([
      CacheSizeService.getImageCacheSize(),
      CacheSizeService.getAiChatDataSize(prefs),
      CacheSizeService.getCookieCacheSize(),
    ]);
    if (mounted) {
      setState(() {
        _imageCacheSize = results[0];
        _aiChatDataSize = results[1];
        _cookieCacheSize = results[2];
      });
    }
  }

  int get _totalCacheSize {
    int total = 0;
    if (_imageCacheSize > 0) total += _imageCacheSize;
    if (_aiChatDataSize > 0) total += _aiChatDataSize;
    if (_cookieCacheSize > 0) total += _cookieCacheSize;
    return total;
  }

  String _formatCacheSize(int size) {
    if (size < 0) return S.current.dataManagement_calculating;
    if (size == 0) return S.current.dataManagement_noCache;
    return CacheSizeService.formatSize(size);
  }

  Future<void> _clearImageCache() async {
    setState(() => _isClearing = true);
    try {
      await Future.wait([
        DiscourseCacheManager().emptyCache(),
        EmojiCacheManager().emptyCache(),
        ExternalImageCacheManager().emptyCache(),
        StickerCacheManager().emptyCache(),
      ]);
      // emptyCache() 只清除了索引，磁盘文件可能残留，需要删除整个目录
      await CacheSizeService.deleteImageCacheDirs();
      PaintingBinding.instance.imageCache.clear();
      setState(() => _imageCacheSize = 0);
      ToastService.showSuccess(S.current.dataManagement_imageCacheCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  Future<void> _clearAiChatData() async {
    final confirmed = await _showConfirmDialog(
      title: S.current.dataManagement_clearAiChatTitle,
      content: S.current.dataManagement_clearAiChatContent,
    );
    if (confirmed != true) return;

    setState(() => _isClearing = true);
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await AiChatStorageService(prefs).deleteAllSessions();
      setState(() => _aiChatDataSize = 0);
      ToastService.showSuccess(S.current.dataManagement_aiChatCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  Future<void> _clearCookieCache() async {
    final confirmed = await _showConfirmDialog(
      title: S.current.dataManagement_clearCookieTitle,
      content: S.current.dataManagement_clearCookieContent,
      confirmText: S.current.dataManagement_clearAndLogout,
      isDestructive: true,
    );
    if (confirmed != true) return;

    setState(() => _isClearing = true);
    try {
      await _doClearCookies();
      setState(() => _cookieCacheSize = 0);
      ToastService.showSuccess(S.current.dataManagement_cookieCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  Future<void> _clearAllCache() async {
    final confirmed = await _showConfirmDialog(
      title: S.current.dataManagement_clearAllTitle,
      content: S.current.dataManagement_clearAllContent,
      confirmText: S.current.dataManagement_clearAll,
      isDestructive: true,
    );
    if (confirmed != true) return;

    setState(() => _isClearing = true);
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      await Future.wait([
        DiscourseCacheManager().emptyCache(),
        EmojiCacheManager().emptyCache(),
        ExternalImageCacheManager().emptyCache(),
        StickerCacheManager().emptyCache(),
        AiChatStorageService(prefs).deleteAllSessions(),
        _doClearCookies(),
      ]);
      await CacheSizeService.deleteImageCacheDirs();
      PaintingBinding.instance.imageCache.clear();
      setState(() {
        _imageCacheSize = 0;
        _aiChatDataSize = 0;
        _cookieCacheSize = 0;
      });
      ToastService.showSuccess(S.current.dataManagement_allCleared);
    } catch (e) {
      ToastService.showError(S.current.common_clearFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  /// 清除 Cookie，并同步执行退出登录链路的状态销毁。
  Future<void> _doClearCookies() async {
    await ref.read(discourseServiceProvider).logout(callApi: false);
    await AppStateRefresher.resetForLogout(ref);
  }

  Future<bool?> _showConfirmDialog({
    required String title,
    required String content,
    String? confirmText,
    bool isDestructive = false,
  }) {
    return showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: isDestructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  )
                : null,
            child: Text(confirmText ?? context.l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _buildCacheTile(
          theme: theme,
          icon: Icons.image_rounded,
          title: context.l10n.dataManagement_imageCache,
          size: _imageCacheSize,
          onClear: _isClearing ? null : _clearImageCache,
        ),
        _buildDivider(theme),
        _buildCacheTile(
          theme: theme,
          icon: Icons.smart_toy_rounded,
          title: context.l10n.dataManagement_aiChatData,
          size: _aiChatDataSize,
          onClear: _isClearing ? null : _clearAiChatData,
        ),
        _buildDivider(theme),
        _buildCacheTile(
          theme: theme,
          icon: Icons.cookie_rounded,
          title: context.l10n.dataManagement_cookieCache,
          size: _cookieCacheSize,
          onClear: _isClearing ? null : _clearCookieCache,
        ),
        _buildDivider(theme),
        ListTile(
          leading: Icon(
            Icons.delete_sweep_rounded,
            color: theme.colorScheme.error,
          ),
          title: Text(context.l10n.dataManagement_clearAllCache),
          subtitle: Text(_formatCacheSize(_totalCacheSize)),
          trailing: TextButton(
            onPressed:
                _isClearing || _totalCacheSize <= 0 ? null : _clearAllCache,
            child: Text(context.l10n.common_clear),
          ),
        ),
      ],
    );
  }

  Widget _buildCacheTile({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required int size,
    required VoidCallback? onClear,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(_formatCacheSize(size)),
      trailing: TextButton(
        onPressed: size <= 0 ? null : onClear,
        child: Text(S.current.common_clear),
      ),
    );
  }

  Widget _buildDivider(ThemeData theme) {
    return Divider(
      height: 1,
      indent: 56,
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
    );
  }
}

// ─────────────────────────────────────────────
// 数据备份区块（被 CustomModel 包装）
// ─────────────────────────────────────────────

/// 数据备份区块，封装了导出和导入逻辑
class DataBackupSection extends ConsumerWidget {
  const DataBackupSection({super.key});

  Future<void> _exportData(BuildContext context, WidgetRef ref) async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final filePath = await DataBackupService.exportToFile(prefs);
      await ShareUtils.shareOrSaveFile(
        XFile(filePath, mimeType: 'application/json'),
        subject: S.current.dataManagement_backupSubject,
      );
    } catch (e) {
      ToastService.showError(
          S.current.dataManagement_exportFailed(e.toString()));
    }
  }

  Future<void> _importData(BuildContext context, WidgetRef ref) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;

      final filePath = result.files.single.path;
      if (filePath == null) return;

      final backup = await DataBackupService.parseBackupFile(filePath);
      final data = backup['data'] as Map<String, dynamic>;
      final apiKeys = backup['apiKeys'] as Map<String, dynamic>?;
      final appVersion =
          backup['appVersion'] as String? ?? S.current.common_unknown;
      final exportTime =
          backup['exportTime'] as String? ?? S.current.common_unknown;

      if (!context.mounted) return;

      final details = StringBuffer()
        ..writeln(S.current.dataManagement_backupSource(appVersion))
        ..writeln(S.current.dataManagement_exportTime(exportTime))
        ..writeln(S.current.dataManagement_settingsCount(data.length));
      if (apiKeys != null && apiKeys.isNotEmpty) {
        details.writeln(S.current.dataManagement_apiKeysCount(apiKeys.length));
      }
      details.write('\n${S.current.dataManagement_importWarning}');

      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(S.current.dataManagement_confirmImport),
          content: Text(details.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ctx.l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(S.current.dataManagement_importAndRestart),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      final prefs = ref.read(sharedPreferencesProvider);
      await DataBackupService.importData(prefs, backup);
      ToastService.showSuccess(S.current.dataManagement_importSuccess);
    } on FormatException catch (e) {
      ToastService.showError(e.message);
    } catch (e) {
      ToastService.showError(
          S.current.dataManagement_importFailed(e.toString()));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.upload_rounded),
          title: Text(context.l10n.dataManagement_exportData),
          subtitle: Text(context.l10n.dataManagement_exportDesc),
          trailing: Icon(
            Icons.chevron_right_rounded,
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
            size: 20,
          ),
          onTap: () => _exportData(context, ref),
        ),
        Divider(
          height: 1,
          indent: 56,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
        ListTile(
          leading: const Icon(Icons.download_rounded),
          title: Text(context.l10n.dataManagement_importData),
          subtitle: Text(context.l10n.dataManagement_importDesc),
          trailing: Icon(
            Icons.chevron_right_rounded,
            color: theme.colorScheme.outline.withValues(alpha: 0.4),
            size: 20,
          ),
          onTap: () => _importData(context, ref),
        ),
      ],
    );
  }
}
