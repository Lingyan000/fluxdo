import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:jovial_svg/jovial_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_logger.dart';
import '../services/cf_challenge_logger.dart';
import '../services/toast_service.dart';
import '../services/update_checker_helper.dart';
import '../services/update_service.dart';
import '../l10n/s.dart';
import '../utils/dialog_utils.dart';
import 'package:m3e_ui/m3e_ui.dart';
import '../widgets/update_dialog.dart';
import 'app_logs_page.dart';
import 'perf_diagnostics_page.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final UpdateService _updateService = UpdateService();
  String _version = '0.1.0';
  String _githubProxy = '';
  int _versionTapCount = 0;
  DateTime? _lastVersionTapTime;
  bool _developerMode = false;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadDeveloperMode();
    _loadGithubProxy();
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
    CfChallengeLogger.setEnabled(enabled);
    // 开发者模式控制 debug 级日志是否落盘
    AppLogger.setVerbose(enabled);
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

  Future<void> _loadGithubProxy() async {
    final proxy = await UpdateService.getGithubProxy();
    if (mounted) {
      setState(() => _githubProxy = proxy);
    }
  }

  Future<void> _showGithubProxyDialog() async {
    final result = await showAppDialog<String>(
      context: context,
      builder: (_) => _GithubProxyDialog(initialValue: _githubProxy),
    );

    if (result == null) return;

    await UpdateService.setGithubProxy(result);
    await _loadGithubProxy();
    ToastService.showSuccess(
      result.isEmpty
          ? S.current.update_githubProxyCleared
          : S.current.update_githubProxySaved,
    );
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
      // 弹框挂在根 Navigator（showAppDialog 默认 useRootNavigator: true），
      // 平行视界下 AboutPage 在嵌套 detail Navigator 里，必须显式取根层，
      // 否则 pop 掉的是页面本身，loading 弹框永远卡住。
      Navigator.of(context, rootNavigator: true).pop(); // 关闭加载对话框

      if (updateInfo.hasUpdate) {
        showAppDialog(
          context: context,
          builder: (context) => UpdateDialog(
            updateInfo: updateInfo,
            onUpdate: () {
              Navigator.of(context).pop();
              UpdateCheckerHelper.handleUpdate(context, updateInfo);
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
      Navigator.of(context, rootNavigator: true).pop(); // 关闭加载对话框
      _showErrorDialog(e.toString());
    }
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
        icon: const Icon(Symbols.check_circle_rounded, size: 48, color: Colors.green),
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
        icon: const Icon(Symbols.error_rounded, size: 48, color: Colors.red),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedCardGroup(
              children: [
                _buildListTile(
                  context,
                  icon: Symbols.update_rounded,
                  title: context.l10n.about_checkUpdate,
                  onTap: _checkForUpdate,
                ),
                _buildListTile(
                  context,
                  icon: Symbols.swap_horiz_rounded,
                  title: context.l10n.update_githubProxy,
                  subtitle: _githubProxy.isEmpty
                      ? context.l10n.update_githubProxyDirect
                      : _githubProxy,
                  onTap: _showGithubProxyDialog,
                ),
                _buildListTile(
                  context,
                  icon: Symbols.description_rounded,
                  title: context.l10n.about_openSourceLicense,
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'FluxDO',
                    applicationVersion: _version,
                    applicationLegalese: context.l10n.about_legalese,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          _buildSectionTitle(context, context.l10n.about_develop),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedCardGroup(
              children: [
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
                  icon: Symbols.code_rounded,
                  title: context.l10n.about_sourceCode,
                  subtitle: 'GitHub',
                  onTap: () => launchUrl(
                    Uri.parse('https://github.com/Lingyan000/fluxdo'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
                _buildListTile(
                  context,
                  icon: Symbols.article_rounded,
                  title: context.l10n.about_appLogs,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AppLogsPage()),
                  ),
                ),
                // 性能诊断(开发者向工具,文案暂不接入 l10n)
                _buildListTile(
                  context,
                  icon: Symbols.speed_rounded,
                  title: '性能诊断',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const PerfDiagnosticsPage(),
                    ),
                  ),
                ),
                _buildListTile(
                  context,
                  icon: Symbols.bug_report_rounded,
                  title: context.l10n.about_feedback,
                  onTap: () => launchUrl(
                    Uri.parse('https://github.com/Lingyan000/fluxdo/issues'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ],
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: const Icon(Symbols.chevron_right_rounded, size: 20, color: Colors.grey),
      onTap: onTap,
    );
  }
}

/// GitHub 反代配置弹窗
///
/// controller 由弹窗自身 State 持有，随路由真正销毁时才 dispose，
/// 避免退场动画期间外部提前 dispose 导致重建崩溃。
class _GithubProxyDialog extends StatefulWidget {
  const _GithubProxyDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_GithubProxyDialog> createState() => _GithubProxyDialogState();
}

class _GithubProxyDialogState extends State<_GithubProxyDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(context.l10n.update_githubProxy),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            context.l10n.update_githubProxyDesc,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: context.l10n.update_githubProxy,
              hintText: context.l10n.update_githubProxyHint,
            ),
            keyboardType: TextInputType.url,
            autofocus: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.common_cancel),
        ),
        FilledButton(
          onPressed: () {
            final value = _controller.text.trim();
            if (value.isNotEmpty && !UpdateService.isValidGithubProxy(value)) {
              ToastService.showError(S.current.update_githubProxyInvalid);
              return;
            }
            Navigator.pop(context, value);
          },
          child: Text(context.l10n.common_save),
        ),
      ],
    );
  }
}
