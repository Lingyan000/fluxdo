import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/s.dart';
import '../../../services/network/adapters/cronet_fallback_service.dart';
import '../../../services/network/adapters/platform_adapter.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/network/rhttp/rhttp_settings_service.dart';
import '../../../services/network/webview/webview_adapter_settings_service.dart';
import '../../../services/toast_service.dart';
import '../../../utils/dialog_utils.dart';

/// 网络引擎卡片（预设单选 + 自定义展开）
///
/// 顶部用预设 chips（标准 / 高性能 / 兼容 / 自定义）单选，常用场景一键切换；
/// 复杂开关（rhttp 模式、WebView、Android 降级）收进「自定义」展开区。
/// 「当前生效引擎」压成一行，降级等异常即时可见。
class EngineCard extends StatefulWidget {
  const EngineCard({super.key});

  @override
  State<EngineCard> createState() => _EngineCardState();
}

enum _EnginePreset { standard, performance, compat, custom }

class _EngineCardState extends State<EngineCard> {
  bool _customExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rhttp = RhttpSettingsService.instance;
    final webview = WebViewAdapterSettingsService.instance;
    final fallbackService = CronetFallbackService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        rhttp.notifier,
        NetworkSettingsService.instance.notifier,
        NetworkSettingsService.instance.isApplying,
        ProxySettingsService.instance.notifier,
        webview.notifier,
        fallbackService,
      ]),
      builder: (context, _) {
        final rhttpSettings = rhttp.current;
        final rhttpEnabled = rhttpSettings.enabled;
        final webviewEnabled = webview.enabled;

        final autoPreset = _presetOf(
          rhttpEnabled,
          rhttpSettings.mode,
          webviewEnabled,
        );
        final isCustom =
            _customExpanded || autoPreset == _EnginePreset.custom;
        final shownPreset = isCustom ? _EnginePreset.custom : autoPreset;

        return Card(
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 预设单选
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: _buildPresetSelector(theme, shownPreset, rhttp, webview),
              ),
              _divider(theme),
              // 当前生效引擎（压一行）
              _buildCurrentEngineRow(theme, fallbackService),
              // 自定义展开区
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 200),
                crossFadeState: isCustom
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: _buildCustomSection(
                  theme,
                  rhttp,
                  rhttpSettings,
                  webview,
                  webviewEnabled,
                  fallbackService,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---- 预设 ----

  Widget _buildPresetSelector(
    ThemeData theme,
    _EnginePreset shown,
    RhttpSettingsService rhttp,
    WebViewAdapterSettingsService webview,
  ) {
    final l10n = context.l10n;
    final items = <(_EnginePreset, String)>[
      (_EnginePreset.standard, l10n.enginePreset_standard),
      (_EnginePreset.performance, l10n.enginePreset_performance),
      (_EnginePreset.compat, l10n.enginePreset_compat),
      (_EnginePreset.custom, l10n.enginePreset_custom),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in items)
              ChoiceChip(
                label: Text(item.$2),
                selected: item.$1 == shown,
                onSelected: (s) {
                  if (s) _applyPreset(item.$1, rhttp, webview);
                },
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _presetDesc(shown),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  void _applyPreset(
    _EnginePreset preset,
    RhttpSettingsService rhttp,
    WebViewAdapterSettingsService webview,
  ) {
    switch (preset) {
      case _EnginePreset.standard:
        setState(() => _customExpanded = false);
        rhttp.setEnabled(false);
        webview.setEnabled(false);
      case _EnginePreset.performance:
        setState(() => _customExpanded = false);
        rhttp.setMode(RhttpMode.always);
        rhttp.setEnabled(true);
        webview.setEnabled(false);
      case _EnginePreset.compat:
        setState(() => _customExpanded = false);
        rhttp.setEnabled(false);
        webview.setEnabled(true);
      case _EnginePreset.custom:
        setState(() => _customExpanded = true);
    }
  }

  _EnginePreset _presetOf(bool rhttpOn, RhttpMode mode, bool webviewOn) {
    if (!rhttpOn && !webviewOn) return _EnginePreset.standard;
    if (rhttpOn && mode == RhttpMode.always && !webviewOn) {
      return _EnginePreset.performance;
    }
    if (!rhttpOn && webviewOn) return _EnginePreset.compat;
    return _EnginePreset.custom;
  }

  String _presetDesc(_EnginePreset preset) {
    final l10n = context.l10n;
    return switch (preset) {
      _EnginePreset.standard => l10n.enginePreset_standardDesc,
      _EnginePreset.performance => l10n.enginePreset_performanceDesc,
      _EnginePreset.compat => l10n.enginePreset_compatDesc,
      _EnginePreset.custom => l10n.enginePreset_customDesc,
    };
  }

  // ---- 当前生效引擎（一行）----

  Widget _buildCurrentEngineRow(
    ThemeData theme,
    CronetFallbackService fallbackService,
  ) {
    final effective = resolveEffectiveAdapter();
    final engineName = getAdapterDisplayName(effective.type);
    final isFallback = effective.reason == AdapterReason.fallback;
    final webviewEnabled = WebViewAdapterSettingsService.instance.enabled;
    final showReset = isFallback && Platform.isAndroid;

    // WebView 在最外层分流：主站 API 走 WebView，其余走推算出的引擎。
    // 它不参与 resolveEffectiveAdapter()，所以开启时要单独显示分流，
    // 否则「兼容」预设会错误地只显示 native/Cronet。
    final IconData icon;
    final Color iconColor;
    final InlineSpan span;
    if (webviewEnabled) {
      icon = Icons.call_split;
      iconColor = theme.colorScheme.tertiary;
      span = TextSpan(
        text: context.l10n.engineStatus_webviewSplit(engineName),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    } else {
      icon = _engineIcon(effective.type);
      iconColor =
          isFallback ? theme.colorScheme.error : theme.colorScheme.primary;
      span = TextSpan(
        children: [
          TextSpan(
            text: '${context.l10n.engineStatus_currentEngine}: ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: engineName,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isFallback
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: '  ·  ${_reasonText(effective.reason)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 10, showReset ? 4 : 16, 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              span,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (showReset)
            IconButton(
              tooltip: context.l10n.networkAdapter_resetFallback,
              icon: const Icon(Icons.refresh, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: () => _resetFallbackState(fallbackService),
            ),
        ],
      ),
    );
  }

  // ---- 自定义展开区 ----

  Widget _buildCustomSection(
    ThemeData theme,
    RhttpSettingsService rhttp,
    RhttpSettings rhttpSettings,
    WebViewAdapterSettingsService webview,
    bool webviewEnabled,
    CronetFallbackService fallbackService,
  ) {
    final l10n = context.l10n;
    final rhttpEnabled = rhttpSettings.enabled;
    final ns = NetworkSettingsService.instance.current;
    final echFallback =
        rhttpEnabled && ns.dohEnabled && ns.echServerUrl != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _divider(theme),
        // rhttp 引擎
        SwitchListTile(
          dense: true,
          secondary: Icon(
            rhttpEnabled ? Icons.rocket_launch : Icons.rocket_launch_outlined,
            color: rhttpEnabled ? theme.colorScheme.primary : null,
          ),
          title: Text(l10n.rhttpEngine_title),
          subtitle: Text(l10n.rhttpEngine_enabledDesc),
          value: rhttpEnabled,
          onChanged: (value) => rhttp.setEnabled(value),
        ),
        if (rhttpEnabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<RhttpMode>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: [
                      ButtonSegment(
                        value: RhttpMode.always,
                        label: Text(l10n.rhttpEngine_alwaysUse),
                      ),
                      ButtonSegment(
                        value: RhttpMode.proxyOnly,
                        label: Text(l10n.rhttpEngine_proxyDohOnly),
                      ),
                    ],
                    selected: {rhttpSettings.mode},
                    onSelectionChanged: (modes) => rhttp.setMode(modes.first),
                  ),
                ),
                if (echFallback)
                  _miniHint(theme, l10n.rhttpEngine_echFallbackHint),
                if (rhttpSettings.forceDisabled)
                  _miniHint(
                    theme,
                    l10n.rhttpEngine_initFailedHint,
                    color: theme.colorScheme.error,
                  ),
              ],
            ),
          ),
        _divider(theme),
        // WebView 适配器
        SwitchListTile(
          dense: true,
          secondary: Icon(
            webviewEnabled ? Icons.language : Icons.language_outlined,
            color: webviewEnabled ? theme.colorScheme.primary : null,
          ),
          title: Text(l10n.webviewAdapter_title),
          subtitle: Text(l10n.webviewAdapter_enabledDesc),
          value: webviewEnabled,
          onChanged: (value) => webview.setEnabled(value),
        ),
        // Android：Cronet 降级控制
        if (Platform.isAndroid)
          ..._buildFallbackControls(theme, fallbackService),
      ],
    );
  }

  /// Android Cronet 降级控制
  List<Widget> _buildFallbackControls(
    ThemeData theme,
    CronetFallbackService fallbackService,
  ) {
    final l10n = context.l10n;
    final hasFallenBack = fallbackService.hasFallenBack;
    final forceFallback = fallbackService.forceFallback;
    final failureReason = fallbackService.fallbackReason;
    final autoFellBack = hasFallenBack && !forceFallback;

    return [
      _divider(theme),
      SwitchListTile(
        secondary: const Icon(Icons.swap_horiz),
        title: Text(l10n.networkAdapter_forceFallback),
        subtitle: Text(l10n.networkAdapter_forceFallbackDesc),
        value: forceFallback,
        onChanged: (value) async {
          await fallbackService.setForceFallback(value);
          ToastService.showSuccess(S.current.networkAdapter_settingSaved);
        },
      ),
      if (autoFellBack) ...[
        ListTile(
          leading: Icon(Icons.info_outline, color: theme.colorScheme.error),
          title: Text(l10n.networkAdapter_autoFallback),
          subtitle: Text(l10n.networkAdapter_autoFallbackDesc),
          dense: true,
        ),
        if (failureReason != null)
          ListTile(
            leading: const Icon(Icons.bug_report),
            title: Text(l10n.networkAdapter_viewReason),
            trailing: const Icon(Icons.chevron_right, size: 20),
            dense: true,
            onTap: () => _showFailureReasonDialog(failureReason),
          ),
        ListTile(
          leading: const Icon(Icons.refresh),
          title: Text(l10n.networkAdapter_resetFallback),
          subtitle: Text(l10n.networkAdapter_resetFallbackDesc),
          trailing: const Icon(Icons.chevron_right, size: 20),
          dense: true,
          onTap: () => _resetFallbackState(fallbackService),
        ),
      ],
      if (kDebugMode && !hasFallenBack)
        ListTile(
          leading: Icon(Icons.science, color: theme.colorScheme.tertiary),
          title: Text(l10n.networkAdapter_simulateError),
          subtitle: Text(l10n.networkAdapter_simulateErrorDesc),
          trailing: const Icon(Icons.chevron_right, size: 20),
          dense: true,
          onTap: () => _simulateCronetError(fallbackService),
        ),
    ];
  }

  // ---- 小组件 / 映射 ----

  Widget _miniHint(ThemeData theme, String text, {Color? color}) {
    final c = color ?? theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            color != null ? Icons.warning_amber : Icons.info_outline,
            size: 13,
            color: c,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: c,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(ThemeData theme) => Divider(
    height: 1,
    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
  );

  IconData _engineIcon(AdapterType type) => switch (type) {
    AdapterType.rhttp => Icons.rocket_launch,
    AdapterType.network => Icons.hub,
    AdapterType.webview => Icons.language,
    AdapterType.native => Icons.bolt,
  };

  String _reasonText(AdapterReason reason) {
    final l10n = context.l10n;
    return switch (reason) {
      AdapterReason.rhttp => l10n.engineStatus_reasonRhttp,
      AdapterReason.gateway => l10n.engineStatus_reasonGateway,
      AdapterReason.proxy => l10n.engineStatus_reasonProxy,
      AdapterReason.fallback => l10n.engineStatus_reasonFallback,
      AdapterReason.native => l10n.engineStatus_reasonNative,
    };
  }

  // ---- 降级对话框 ----

  Future<void> _showFailureReasonDialog(String reason) async {
    await showAppDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.networkAdapter_degradeReason),
        content: SingleChildScrollView(
          child: SelectableText(
            reason,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.l10n.common_close),
          ),
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: reason));
              ToastService.showSuccess(S.current.common_copiedToClipboard);
            },
            child: Text(dialogContext.l10n.common_copy),
          ),
        ],
      ),
    );
  }

  Future<void> _resetFallbackState(
    CronetFallbackService fallbackService,
  ) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.networkAdapter_resetFallback),
        content: Text(dialogContext.l10n.networkAdapter_resetFallbackDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.common_reset),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await fallbackService.reset();
      ToastService.showSuccess(S.current.networkAdapter_resetSuccess);
    }
  }

  Future<void> _simulateCronetError(
    CronetFallbackService fallbackService,
  ) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.networkAdapter_simulateError),
        content: Text(dialogContext.l10n.networkAdapter_simulateErrorDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(dialogContext.l10n.common_cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.tertiary,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(dialogContext.l10n.common_confirm),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await fallbackService.simulateCronetError();
      ToastService.showInfo(S.current.networkAdapter_simulateSuccess);
    }
  }
}
