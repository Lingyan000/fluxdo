import 'dart:io';

import 'package:flutter/material.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/apk_download_service.dart';
import '../services/cf_challenge_logger.dart';
import '../services/toast_service.dart';
import '../services/update_service.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import '../widgets/download_progress_dialog.dart';
import '../widgets/update_dialog.dart';
import 'app_logs_page.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final UpdateService _updateService = UpdateService();
  String _version = '0.1.0';
  int _versionTapCount = 0;
  DateTime? _lastVersionTapTime;
  bool _developerMode = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadDeveloperMode();
  }

  void _onVersionTap() {
    final now = DateTime.now();
    if (_lastVersionTapTime != null &&
        now.difference(_lastVersionTapTime!) > const Duration(seconds: 2)) {
      _versionTapCount = 0; // 超时重置
    }
    _lastVersionTapTime = now;
    _versionTapCount++;

    if (_versionTapCount == 7) {
      _versionTapCount = 0;
      _enableDeveloperMode();
    }
  }

  Future<void> _enableDeveloperMode() async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyEnabled = prefs.getBool('developer_mode') ?? false;
    if (alreadyEnabled) {
      setState(() => _developerMode = true);
      if (!mounted) return;
      ToastService.showInfo(S.current.about_developerModeAlreadyEnabled);
      return;
    }
    await _setDeveloperMode(true);
  }

  Future<void> _setDeveloperMode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('developer_mode', enabled);
    if (!enabled) {
      await CfChallengeLogger.clear();
    }
    await CfChallengeLogger.setEnabled(enabled);
    if (mounted) {
      setState(() => _developerMode = enabled);
    }
    if (!mounted) return;
    ToastService.showSuccess(enabled ? S.current.about_developerModeEnabled : S.current.about_developerModeClosed);
  }

  Future<void> _loadVersion() async {
    final version = await _updateService.getCurrentVersion();
    setState(() {
      _version = version;
    });
  }

  Future<void> _loadDeveloperMode() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('developer_mode') ?? false;
    if (mounted) {
      setState(() => _developerMode = enabled);
    }
  }

  Future<void> _checkForUpdate() async {
    if (!mounted) return;

    // 显示加载提示
    showAppDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: CircularProgressIndicator(),
          ),
        ),
      ),
    );

    try {
      final updateInfo = await _updateService.checkForUpdate();

      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭加载对话框

      if (updateInfo.hasUpdate) {
        showAppDialog(
          context: context,
          builder: (context) => UpdateDialog(
            updateInfo: updateInfo,
            onUpdate: () {
              Navigator.of(context).pop();
              _handleUpdate(updateInfo);
            },
            onCancel: () => Navigator.of(context).pop(),
            onOpenReleasePage: () {
              Navigator.of(context).pop();
              _openInBrowser(updateInfo.releaseUrl);
            },
          ),
        );
      } else {
        _showNoUpdateDialog(updateInfo.currentVersion);
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // 关闭加载对话框
      _showErrorDialog(e.toString());
    }
  }

  /// 处理更新逻辑
  Future<void> _handleUpdate(UpdateInfo updateInfo) async {
    if (Platform.isAndroid) {
      await _startInAppDownload(updateInfo);
    } else {
      _openInBrowser(updateInfo.releaseUrl);
    }
  }

  /// 启动应用内下载
  Future<void> _startInAppDownload(UpdateInfo updateInfo) async {
    final apkAsset = await _updateService.getMatchingApkAsset(updateInfo);

    if (apkAsset == null) {
      // 无法匹配架构，回退到浏览器
      _openInBrowser(updateInfo.releaseUrl);
      return;
    }

    if (!mounted) return;

    showAppDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => DownloadProgressDialog(
        asset: apkAsset,
        downloadService: ApkDownloadService(),
      ),
    );
  }

  /// 在浏览器中打开
  void _openInBrowser(String url) {
    launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  }

  void _showNoUpdateDialog(String currentVersion) {
    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
        title: Text(context.l10n.about_latestVersion),
        content: Text(context.l10n.about_noUpdateContent(currentVersion)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.common_ok),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String error) {
    showAppDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.error_outline, size: 48, color: Colors.red),
        title: Text(context.l10n.about_checkUpdateFailed),
        content: Text(context.l10n.about_checkUpdateError(error)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.about_title),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          const SizedBox(height: 40),
          // Logo Header
          Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: ScalableImageWidget.fromSISource(
                si: ScalableImageSource.fromSvg(
                  DefaultAssetBundle.of(context),
                  'assets/logo.svg',
                  warnF: (_) {},
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Column(
              children: [
                Text(
                  'FluxDO',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: _onVersionTap,
                  child: Text(
                    'Version $_version',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 48),

          // Action List
          _buildSectionTitle(context, context.l10n.about_info),
          _buildListTile(
            context,
            icon: Icons.update_rounded,
            title: context.l10n.about_checkUpdate,
            onTap: _checkForUpdate,
          ),
          _buildListTile(
            context,
            icon: Icons.description_outlined,
            title: context.l10n.about_openSourceLicense,
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'FluxDO',
              applicationVersion: _version,
              applicationLegalese: context.l10n.about_legalese,
            ),
          ),

          const Divider(height: 32, indent: 16, endIndent: 16),

          _buildSectionTitle(context, context.l10n.about_develop),
          if (_developerMode)
            SwitchListTile(
              title: Text(context.l10n.about_developerMode),
              subtitle: Text(context.l10n.about_tapToDisableDeveloperMode),
              value: true,
              onChanged: (value) {
                if (!value) {
                  _setDeveloperMode(false);
                }
              },
            ),
          _buildListTile(
            context,
            icon: Icons.code,
            title: context.l10n.about_sourceCode,
            subtitle: 'GitHub',
            onTap: () => launchUrl(
              Uri.parse('https://github.com/Lingyan000/fluxdo'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          _buildListTile(
            context,
            icon: Icons.article_outlined,
            title: context.l10n.about_appLogs,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AppLogsPage()),
            ),
          ),
          _buildListTile(
            context,
            icon: Icons.bug_report_outlined,
            title: context.l10n.about_feedback,
            onTap: () => launchUrl(
              Uri.parse('https://github.com/Lingyan000/fluxdo/issues'),
              mode: LaunchMode.externalApplication,
            ),
          ),

          const SizedBox(height: 40),
          Center(
            child: Text(
              'Made with Flutter & \u2764\uFE0F',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildListTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      leading: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
      onTap: onTap,
    );
  }
}
