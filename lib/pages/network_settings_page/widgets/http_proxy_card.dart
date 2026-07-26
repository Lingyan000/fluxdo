import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';

import '../../../l10n/s.dart';
import '../../../services/network/doh/network_settings_service.dart';
import '../../../utils/dialog_utils.dart';
import '../../../services/network/proxy/proxy_settings_service.dart';
import '../../../services/network/proxy/shadowsocks_uri_parser.dart';
import '../../../services/network/vpn_auto_toggle_service.dart';
import '../../../services/toast_service.dart';
import 'package:m3e_ui/m3e_ui.dart';

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
        vpnService.suppressionNotifier,
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
        // VPN 活跃 + 自动切换开启 = 接管期，代理开关在此期间一律锁定
        final vpnLocked = VpnAutoToggleService.instance.enabled &&
            VpnAutoToggleService.instance.vpnActive;

        return SegmentedCardGroup(
          color: proxySettings.enabled
              ? theme.colorScheme.tertiaryContainer.withValues(alpha: 0.3)
              : null,
          children: [
            SwitchListTile(
              title: Text(context.l10n.httpProxy_title),
              subtitle: Text(
                vpnLocked
                    ? (isSuppressedByVpn
                        ? context.l10n.httpProxy_suppressedByVpn
                        : context.l10n.vpnToggle_lockedHint)
                    : proxySettings.enabled
                        ? context.l10n.httpProxy_enabledDesc(proxySettings.protocol.displayName)
                        : context.l10n.httpProxy_disabledDesc,
              ),
              secondary: Icon(
                (vpnLocked ? isSuppressedByVpn : proxySettings.enabled)
                    ? Symbols.vpn_key_rounded
                    : Symbols.vpn_key_rounded,
                color: (vpnLocked ? isSuppressedByVpn : proxySettings.enabled)
                    ? theme.colorScheme.tertiary
                    : null,
              ),
              // VPN 接管期间：开关照常可拨，但操作的是"VPN 断开后是否启用"的意图标记，
              // 不立即生效（功能仍由自动切换接管）。
              value: vpnLocked ? isSuppressedByVpn : proxySettings.enabled,
              onChanged: vpnLocked
                  ? (value) =>
                      VpnAutoToggleService.instance.setProxySuppressed(value)
                  : (value) async {
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
              ListTile(
                leading: const Icon(Symbols.dns_rounded),
                title: Text(context.l10n.httpProxy_server),
                subtitle: Text(
                  proxySettings.host.isNotEmpty
                      ? _buildProxySummary(proxySettings)
                      : context.l10n.common_notConfigured,
                ),
                trailing: const Icon(Symbols.edit_rounded, size: 20),
                onTap: () => _showProxyConfigDialog(context, proxySettings),
              ),
              if (!proxySettings.isShadowsocks &&
                  proxySettings.username != null &&
                  proxySettings.username!.isNotEmpty)
                ListTile(
                  leading: const Icon(Symbols.person_rounded),
                  title: Text(context.l10n.httpProxy_auth),
                  subtitle: Text(context.l10n.httpProxy_username(proxySettings.username!)),
                  dense: true,
                ),
              Column(
                children: [
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
                        ? const LoadingSpinner(size: 18)
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
                            Symbols.hub_rounded,
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
              ),
            ],
            if (!proxySettings.enabled)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      Symbols.info_rounded,
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
                          icon: const Icon(Symbols.download_rounded),
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
      return Symbols.network_check_rounded;
    }
    if (testResult == null) {
      return Symbols.checklist_rtl_rounded;
    }
    return testResult.success ? Symbols.check_circle_rounded : Symbols.error_rounded;
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
