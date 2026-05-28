import 'package:flutter/material.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/network/proxy/shadowsocks_uri_parser.dart';
import '../../../services/network/vpn_auto_toggle_service.dart';
import '../../../services/toast_service.dart';

class HttpProxyCard extends StatelessWidget {
  const HttpProxyCard({super.key});

  @override
  Widget build(BuildContext context) {
    final proxyService = ProxySettingsService.instance;
    final networkService = NetworkSettingsService.instance;
    final vpnService = VpnAutoToggleService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        proxyService.notifier,
        proxyService.isTesting,
        proxyService.testResultNotifier,
        networkService.notifier,
        vpnService.enabledNotifier,
        vpnService.vpnActiveNotifier,
      ]),
      builder: (context, _) {
        final proxySettings = proxyService.notifier.value;
        final dohEnabled = networkService.notifier.value.dohEnabled;
        final isSuppressedByVpn = vpnService.enabled && vpnService.isProxySuppressed;
        return _HttpProxyCardInner(
          proxySettings: proxySettings,
          dohEnabled: dohEnabled,
          isSuppressedByVpn: isSuppressedByVpn,
        );
      },
    );
  }
}

class _HttpProxyCardInner extends StatelessWidget {
  const _HttpProxyCardInner({
    required this.proxySettings,
    required this.dohEnabled,
    this.isSuppressedByVpn = false,
  });

  final ProxySettings proxySettings;
  final bool dohEnabled;
  final bool isSuppressedByVpn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proxyService = ProxySettingsService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([
        proxyService.isTesting,
        proxyService.testResultNotifier,
      ]),
      builder: (context, _) {
        final isTesting = proxyService.isTesting.value;
        final testResult = proxyService.testResultNotifier.value;

        return Card(
          clipBehavior: Clip.antiAlias,
          color: proxySettings.enabled
              ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.3)
              : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: proxySettings.enabled
                ? BorderSide(
                    color: theme.colorScheme.tertiary.withValues(alpha: 0.3),
                  )
                : BorderSide.none,
          ),
          child: Column(
            children: [
              SwitchListTile(
                title: Text(context.l10n.httpProxy_title),
                subtitle: Text(
                  isSuppressedByVpn
                      ? context.l10n.httpProxy_suppressedByVpn
                      : proxySettings.enabled
                          ? context.l10n.httpProxy_enabledDesc(proxySettings.protocol.displayName)
                          : context.l10n.httpProxy_disabledDesc,
                ),
                secondary: Icon(
                  proxySettings.enabled ? Icons.vpn_key : Icons.vpn_key_outlined,
                  color: proxySettings.enabled
                      ? theme.colorScheme.tertiary
                      : null,
                ),
                value: proxySettings.enabled,
                onChanged: (value) async {
                  if (value && !proxySettings.hasServer) {
                    final saved = await _showProxyConfigDialog(
                      context,
                      proxySettings,
                    );
                    if (!saved) {
                      return;
                    }
                  }

                  await proxyService.setEnabled(value);
                  // 用户在 VPN 活跃时手动开启，清除压制标记
                  if (value && isSuppressedByVpn) {
                    VpnAutoToggleService.instance.clearProxySuppression();
                  }
                  if (!value) {
                    return;
                  }

                  final previous = proxyService.testResultNotifier.value;
                  final shouldRetest = previous == null ||
                      !previous.success ||
                      DateTime.now().difference(previous.testedAt) >
                          const Duration(seconds: 30);
                  if (shouldRetest) {
                    await _runProxyTest(showToast: true);
                  }
                },
              ),
              if (proxySettings.hasServer || proxySettings.enabled) ...[
                Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                ),
                ListTile(
                  leading: const Icon(Icons.dns),
                  title: Text(context.l10n.httpProxy_server),
                  subtitle: Text(
                    proxySettings.host.isNotEmpty
                        ? _buildProxySummary(proxySettings)
                        : context.l10n.common_notConfigured,
                  ),
                  trailing: const Icon(Icons.edit, size: 20),
                  onTap: () => _showProxyConfigDialog(context, proxySettings),
                ),
                if (!proxySettings.isShadowsocks &&
                    proxySettings.username != null &&
                    proxySettings.username!.isNotEmpty) ...[
                  Divider(
                    height: 1,
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                  ),
                  ListTile(
                    leading: const Icon(Icons.person),
                    title: Text(context.l10n.httpProxy_auth),
                    subtitle: Text(context.l10n.httpProxy_username(proxySettings.username!)),
                    dense: true,
                  ),
                ],
                Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                ),
                ListTile(
                  leading: Icon(
                    _resolveTestIcon(isTesting, testResult),
                    color: _resolveTestColor(theme, isTesting, testResult),
                  ),
                  title: Text(context.l10n.httpProxy_testAvailability),
                  subtitle: Text(
                    _buildTestSubtitle(
                      isTesting: isTesting,
                      testResult: testResult,
                      protocol: proxySettings.protocol,
                    ),
                  ),
                  trailing: isTesting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: () => _runProxyTest(showToast: true),
                          child: Text(context.l10n.common_test),
                        ),
                  onTap: isTesting ? null : () => _runProxyTest(showToast: true),
                ),
                if (proxySettings.enabled && dohEnabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.hub_outlined,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            context.l10n.httpProxy_dohProxyHint,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              if (!proxySettings.enabled)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.l10n.httpProxy_disabledHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<ProxyTestResult> _runProxyTest({required bool showToast}) async {
    final proxyService = ProxySettingsService.instance;
    final result = await proxyService.testCurrentAvailability();
    if (showToast) {
      if (result.success) {
        final latency =
            result.latency == null ? '' : ' · ${result.latency!.inMilliseconds}ms';
        ToastService.showSuccess('${result.detail}$latency');
      } else {
        ToastService.showError(result.detail);
      }
    }
    return result;
  }

  Future<bool> _showProxyConfigDialog(
    BuildContext context,
    ProxySettings proxySettings,
  ) async {
    final proxyService = ProxySettingsService.instance;
    final hostController = TextEditingController(text: proxySettings.host);
    final portController = TextEditingController(
      text: proxySettings.port > 0 ? proxySettings.port.toString() : '',
    );
    final usernameController =
        TextEditingController(text: proxySettings.username ?? '');
    final passwordController =
        TextEditingController(text: proxySettings.password ?? '');

    var selectedProtocol = proxySettings.protocol;
    var requireAuth = !proxySettings.isShadowsocks &&
        ((proxySettings.username?.isNotEmpty ?? false) ||
            (proxySettings.password?.isNotEmpty ?? false));
    var selectedCipher = proxySettings.cipher.isNotEmpty
        ? proxySettings.cipher
        : ProxySettingsService.supportedShadowsocksCiphers[1];

    final result = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setState) {
            final isShadowsocks =
                selectedProtocol == UpstreamProxyProtocol.shadowsocks;
            final isShadowsocks2022 =
                ProxySettingsService.isShadowsocks2022Cipher(selectedCipher);
            return AlertDialog(
              title: Text(dialogContext.l10n.httpProxy_configTitle),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<UpstreamProxyProtocol>(
                      initialValue: selectedProtocol,
                      decoration: InputDecoration(labelText: dialogContext.l10n.httpProxy_protocol),
                      items: UpstreamProxyProtocol.values
                          .map(
                            (item) => DropdownMenuItem<UpstreamProxyProtocol>(
                              value: item,
                              child: Text(item.displayName),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          selectedProtocol = value;
                          if (selectedProtocol ==
                              UpstreamProxyProtocol.shadowsocks) {
                            requireAuth = false;
                            if (selectedCipher.isEmpty) {
                              selectedCipher = ProxySettingsService
                                  .supportedShadowsocksCiphers[1];
                            }
                          }
                        });
                      },
                    ),
                    if (isShadowsocks) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () async {
                            final imported = await _showImportShadowsocksDialog(
                              dialogContext,
                            );
                            if (imported == null) {
                              return;
                            }
                            setState(() {
                              hostController.text = imported.host;
                              portController.text = imported.port.toString();
                              passwordController.text = imported.password;
                              selectedCipher = imported.cipher;
                            });
                            ToastService.showSuccess(
                              imported.remarks?.isNotEmpty == true
                                  ? S.current.httpProxy_importedNode(imported.remarks!)
                                  : S.current.httpProxy_ssImportSuccess,
                            );
                          },
                          icon: const Icon(Icons.download_rounded),
                          label: Text(S.current.httpProxy_importSsLink),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: hostController,
                      decoration: InputDecoration(
                        labelText: dialogContext.l10n.httpProxy_serverAddress,
                        hintText: dialogContext.l10n.httpProxy_serverAddressHint,
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: portController,
                      decoration: InputDecoration(
                        labelText: dialogContext.l10n.httpProxy_port,
                        hintText: dialogContext.l10n.httpProxy_portHint,
                      ),
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    if (isShadowsocks) ...[
                      DropdownButtonFormField<String>(
                        initialValue: selectedCipher,
                        decoration: InputDecoration(labelText: dialogContext.l10n.httpProxy_cipher),
                        items: ProxySettingsService.supportedShadowsocksCiphers
                            .map(
                              (item) => DropdownMenuItem<String>(
                                value: item,
                                child: Text(item),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            selectedCipher = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: passwordController,
                        decoration: InputDecoration(
                          labelText:
                              isShadowsocks2022 ? dialogContext.l10n.httpProxy_keyBase64Psk : dialogContext.l10n.httpProxy_password,
                          hintText: isShadowsocks2022
                              ? dialogContext.l10n.httpProxy_base64PskHint
                              : null,
                        ),
                        obscureText: true,
                      ),
                    ] else ...[
                      Row(
                        children: [
                          Checkbox(
                            value: requireAuth,
                            onChanged: (value) {
                              setState(() {
                                requireAuth = value ?? false;
                              });
                            },
                          ),
                          Text(dialogContext.l10n.httpProxy_requireAuth),
                        ],
                      ),
                      if (requireAuth) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: usernameController,
                          decoration: InputDecoration(labelText: dialogContext.l10n.httpProxy_usernameLabel),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: passwordController,
                          decoration: InputDecoration(labelText: dialogContext.l10n.httpProxy_password),
                          obscureText: true,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(dialogContext.l10n.common_cancel),
                ),
                FilledButton(
                  onPressed: () {
                    final host = hostController.text.trim();
                    final portText = portController.text.trim();
                    if (host.isEmpty || portText.isEmpty) {
                      ToastService.showInfo(S.current.httpProxy_fillServerAndPort);
                      return;
                    }
                    final port = int.tryParse(portText);
                    if (port == null || port <= 0 || port > 65535) {
                      ToastService.showError(S.current.httpProxy_portInvalid);
                      return;
                    }
                    if (isShadowsocks) {
                      final normalizedCipher =
                          ProxySettingsService.normalizeShadowsocksCipher(
                        selectedCipher,
                      );
                      if (normalizedCipher.isEmpty) {
                        ToastService.showError(S.current.httpProxy_selectSsCipher);
                        return;
                      }
                      final secretError =
                          ProxySettingsService.validateShadowsocksSecret(
                        cipher: normalizedCipher,
                        secret: passwordController.text.trim(),
                      );
                      if (secretError != null) {
                        ToastService.showError(secretError);
                        return;
                      }
                    }
                    Navigator.pop(dialogContext, true);
                  },
                  child: Text(dialogContext.l10n.common_save),
                ),
              ],
            );
          },
        );
      },
    );

    if (result == true) {
      final isShadowsocks =
          selectedProtocol == UpstreamProxyProtocol.shadowsocks;
      await proxyService.setServer(
        protocol: selectedProtocol,
        host: hostController.text.trim(),
        port: int.tryParse(portController.text.trim()) ?? 0,
        username: isShadowsocks
            ? null
            : (requireAuth ? usernameController.text.trim() : null),
        password: isShadowsocks
            ? passwordController.text.trim()
            : (requireAuth ? passwordController.text.trim() : null),
        cipher: isShadowsocks ? selectedCipher : null,
      );
      await _runProxyTest(showToast: true);
    }

    hostController.dispose();
    portController.dispose();
    usernameController.dispose();
    passwordController.dispose();
    return result == true;
  }

  Future<ShadowsocksUriConfig?> _showImportShadowsocksDialog(
    BuildContext context,
  ) async {
    final linkController = TextEditingController();
    final value = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(dialogContext.l10n.httpProxy_importSsLink),
          content: TextField(
            controller: linkController,
            decoration: InputDecoration(
              labelText: dialogContext.l10n.httpProxy_ssLink,
              hintText: 'ss://...',
            ),
            minLines: 2,
            maxLines: 4,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(dialogContext.l10n.common_cancel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, linkController.text.trim()),
              child: Text(dialogContext.l10n.common_import),
            ),
          ],
        );
      },
    );
    linkController.dispose();

    if (value == null || value.isEmpty) {
      return null;
    }

    try {
      return ShadowsocksUriParser.parse(value);
    } on FormatException catch (error) {
      ToastService.showError(error.message.toString());
      return null;
    } catch (error) {
      ToastService.showError(error.toString());
      return null;
    }
  }

  String _buildProxySummary(ProxySettings settings) {
    if (settings.isShadowsocks) {
      final cipher = settings.cipher.trim().isEmpty ? S.current.httpProxy_cipherNotSet : settings.cipher;
      return '${settings.protocol.displayName} · ${settings.host}:${settings.port} · $cipher';
    }
    return '${settings.protocol.displayName} · ${settings.host}:${settings.port}';
  }

  IconData _resolveTestIcon(bool isTesting, ProxyTestResult? testResult) {
    if (isTesting) {
      return Icons.network_check;
    }
    if (testResult == null) {
      return Icons.checklist_rtl_outlined;
    }
    return testResult.success ? Icons.check_circle_outline : Icons.error_outline;
  }

  Color? _resolveTestColor(
    ThemeData theme,
    bool isTesting,
    ProxyTestResult? testResult,
  ) {
    if (isTesting || testResult == null) {
      return theme.colorScheme.primary;
    }
    return testResult.success ? theme.colorScheme.primary : theme.colorScheme.error;
  }

  String _buildTestSubtitle({
    required bool isTesting,
    required ProxyTestResult? testResult,
    required UpstreamProxyProtocol protocol,
  }) {
    if (isTesting) {
      return protocol == UpstreamProxyProtocol.shadowsocks
          ? S.current.httpProxy_testingSsConfig
          : S.current.httpProxy_testingProxy;
    }
    if (testResult == null) {
      return protocol == UpstreamProxyProtocol.shadowsocks
          ? S.current.httpProxy_ssConfigSaved
          : S.current.httpProxy_proxyAutoTest;
    }

    final latency = testResult.latency == null
        ? ''
        : ' · ${testResult.latency!.inMilliseconds}ms';
    return '${testResult.detail}$latency · ${_formatTime(testResult.testedAt)}';
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}
