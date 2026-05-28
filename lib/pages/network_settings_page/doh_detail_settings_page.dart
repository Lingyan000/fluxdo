import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/s.dart';
import '../../services/network/doh/doh_resolver.dart';
import '../../utils/dialog_utils.dart';
import '../../services/network/doh/network_settings_service.dart';
import '../../services/toast_service.dart';
import '../../widgets/common/dismissible_popup_menu.dart';

/// DOH 详细设置页面（服务器列表、IPv6、服务端 IP、ECH）
class DohDetailSettingsPage extends StatefulWidget {
  const DohDetailSettingsPage({super.key});

  @override
  State<DohDetailSettingsPage> createState() => _DohDetailSettingsPageState();
}

class _DohDetailSettingsPageState extends State<DohDetailSettingsPage> {
  final NetworkSettingsService _service = NetworkSettingsService.instance;
  final Map<String, int?> _latencies = {};
  final Set<String> _testingServers = {};
  bool _testingAll = false;
  bool _dnsCacheBusy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: _service.notifier,
      builder: (context, _) {
        final settings = _service.current;

        return Scaffold(
          appBar: AppBar(title: Text(context.l10n.dohDetail_title)),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // IPv6 开关
              Card(
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: Text(context.l10n.dohDetail_gatewayMode),
                      subtitle: Text(
                        settings.gatewayEnabled
                            ? context.l10n.dohDetail_gatewayEnabledDesc
                            : context.l10n.dohDetail_gatewayDisabledDesc,
                      ),
                      secondary: const Icon(Icons.swap_horiz),
                      value: settings.gatewayEnabled,
                      onChanged: (value) => _service.setGatewayEnabled(value),
                    ),
                    Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                    ),
                    SwitchListTile(
                      title: Text(context.l10n.dohDetail_ipv6Prefer),
                      subtitle: Text(context.l10n.dohDetail_ipv6PreferDesc),
                      secondary: const Icon(Icons.language),
                      value: settings.preferIPv6,
                      onChanged: (value) => _service.setPreferIPv6(value),
                    ),
                    Divider(
                      height: 1,
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                    ),
                    // Server IP
                    ListTile(
                      leading: const Icon(Icons.dns),
                      title: Text(context.l10n.dohDetail_serverIp),
                      subtitle: Text(
                        settings.serverIp != null && settings.serverIp!.isNotEmpty
                            ? settings.serverIp!
                            : context.l10n.common_notSet,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: settings.serverIp != null && settings.serverIp!.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 20),
                              tooltip: context.l10n.common_clear,
                              onPressed: () => _service.setServerIp(null),
                            )
                          : null,
                      onTap: () => _showServerIpDialog(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // 服务器列表
              _buildSectionHeader(theme, context.l10n.dohDetail_servers),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    // 工具栏
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                      child: Row(
                        children: [
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _testingAll ? null : _testAllServers,
                            icon: _testingAll
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.speed, size: 16),
                            label: Text(_testingAll ? context.l10n.dohDetail_testingSpeed : context.l10n.dohDetail_testAllSpeed),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _showAddServerDialog,
                            icon: const Icon(Icons.add, size: 16),
                            label: Text(context.l10n.common_add),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // 服务器列表
                    _buildServerList(theme, settings),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ECH 服务器选择
              _buildSectionHeader(theme, 'ECH'),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _buildEchServerSelector(theme, settings),
              ),
              const SizedBox(height: 24),

              _buildSectionHeader(theme, context.l10n.dohDetail_dnsCacheSection),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _buildDnsCacheCard(theme),
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Text(
      title,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
  }

  Widget _buildServerList(ThemeData theme, NetworkSettings settings) {
    final servers = _service.servers;

    return RadioGroup<String>(
      groupValue: settings.selectedServerUrl,
      onChanged: (value) {
        if (value != null) _service.setSelectedServer(value);
      },
      child: Column(
        children: [
          for (int i = 0; i < servers.length; i++) ...[
            _buildServerTile(theme, servers[i], settings),
            if (i != servers.length - 1)
              Divider(
                height: 1,
                indent: 56,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
              ),
          ],
          if (servers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(S.current.dohDetail_noServers),
            ),
        ],
      ),
    );
  }

  Widget _buildServerTile(ThemeData theme, DohServer server, NetworkSettings settings) {
    final selected = server.url == settings.selectedServerUrl;
    final isTesting = _testingServers.contains(server.url);
    final latency = _latencies[server.url];

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 8, right: 12),
      leading: Radio<String>(
        value: server.url,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              server.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (server.isCustom)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                S.current.common_custom,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        server.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isTesting)
            const SizedBox(
              width: 48,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (latency != null)
            SizedBox(
              width: 48,
              child: Text(
                '${latency}ms',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _getLatencyColor(latency),
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            )
          else
            SizedBox(
              width: 48,
              child: IconButton(
                icon: const Icon(Icons.speed, size: 20),
                tooltip: S.current.dohDetail_testSpeed,
                onPressed: () => _testServer(server),
                visualDensity: VisualDensity.compact,
              ),
            ),
          SwipeDismissiblePopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 20, color: theme.colorScheme.onSurfaceVariant),
            tooltip: S.current.common_more,
            padding: EdgeInsets.zero,
            onSelected: (value) {
              switch (value) {
                case 'copy':
                  Clipboard.setData(ClipboardData(text: server.url));
                  ToastService.showInfo(S.current.dohDetail_dohAddressCopied);
                case 'edit':
                  _showEditServerDialog(server);
                case 'delete':
                  _confirmDeleteServer(server);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'copy',
                child: ListTile(
                  leading: const Icon(Icons.copy, size: 20),
                  title: Text(S.current.dohDetail_copyAddress),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (server.isCustom) ...[
                PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    leading: const Icon(Icons.edit, size: 20),
                    title: Text(S.current.common_edit),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline, size: 20, color: theme.colorScheme.error),
                    title: Text(S.current.common_delete, style: TextStyle(color: theme.colorScheme.error)),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      selected: selected,
      onTap: () => _service.setSelectedServer(server.url),
    );
  }

  Color _getLatencyColor(int latency) {
    if (latency < 100) return Colors.green;
    if (latency < 300) return Colors.orange;
    return Colors.red;
  }

  Future<void> _testServer(DohServer server) async {
    if (_testingServers.contains(server.url)) return;

    setState(() => _testingServers.add(server.url));

    final resolver = DohResolver(
      serverUrl: server.url,
      bootstrapIps: server.bootstrapIps,
      enableFallback: false,
    );
    try {
      final ms = await resolver.testLatency(_service.testHost);
      if (mounted) {
        setState(() {
          _latencies[server.url] = ms;
          _testingServers.remove(server.url);
        });
      }
    } finally {
      resolver.dispose();
    }
  }

  Future<void> _testAllServers() async {
    if (_testingAll) return;
    setState(() => _testingAll = true);

    final servers = _service.servers;
    final futures = <Future<void>>[];

    for (final server in servers) {
      futures.add(_testServer(server));
    }

    await Future.wait(futures);

    if (mounted) {
      setState(() => _testingAll = false);
    }
  }

  Widget _buildEchServerSelector(ThemeData theme, NetworkSettings settings) {
    final servers = _service.servers;
    final currentEch = settings.echServerUrl;
    String echLabel = S.current.dohDetail_sameAsDns;
    if (currentEch != null) {
      for (final s in servers) {
        if (s.url == currentEch) {
          echLabel = s.name;
          break;
        }
      }
    }

    return ListTile(
      leading: const Icon(Icons.security),
      title: Text(S.current.dohDetail_echServer),
      subtitle: Text(
        echLabel,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showEchServerDialog(servers, currentEch),
    );
  }

  Widget _buildDnsCacheCard(ThemeData theme) {
    final cacheCount = _service.dnsCacheEntryCount;
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.storage),
          title: Text(S.current.dohDetail_localDnsCache),
          subtitle: Text(
            S.current.dohDetail_dnsCacheDesc(cacheCount),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _dnsCacheBusy ? null : _clearDnsCache,
                  icon: _dnsCacheBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  label: Text(_dnsCacheBusy ? S.current.dohDetail_processing : S.current.dohDetail_clearCache),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _dnsCacheBusy ? null : _forceRefreshDnsCache,
                  icon: _dnsCacheBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(_dnsCacheBusy ? S.current.dohDetail_processing : S.current.dohDetail_forceRefresh),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showEchServerDialog(List<DohServer> servers, String? currentEch) async {
    final result = await showAppDialog<String?>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text(context.l10n.dohDetail_selectEchServer),
          children: [
            RadioGroup<String?>(
              groupValue: currentEch,
              onChanged: (value) =>
                  Navigator.pop(context, value ?? '__null__'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<String?>(
                    title: Text(context.l10n.dohDetail_sameAsDns),
                    subtitle: Text(
                      context.l10n.dohDetail_echSameAsDnsDesc,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    value: null,
                  ),
                  for (final server in servers)
                    RadioListTile<String?>(
                      title: Text(server.name),
                      subtitle: Text(
                        server.url,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: server.url,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );

    if (result != null) {
      if (result == '__null__') {
        await _service.setEchServer(null);
      } else {
        await _service.setEchServer(result);
      }
    }
  }

  Future<void> _clearDnsCache() async {
    if (_dnsCacheBusy) return;
    setState(() => _dnsCacheBusy = true);
    try {
      await _service.clearDnsCache();
      if (mounted) {
        ToastService.showSuccess(S.current.dohDetail_dnsCacheCleared);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.dohDetail_clearDnsCacheFailed('$e'));
      }
    } finally {
      if (mounted) {
        setState(() => _dnsCacheBusy = false);
      }
    }
  }

  Future<void> _forceRefreshDnsCache() async {
    if (_dnsCacheBusy) return;
    setState(() => _dnsCacheBusy = true);
    try {
      final count = await _service.forceRefreshDnsCache();
      if (mounted) {
        ToastService.showSuccess(
          count > 0 ? S.current.dohDetail_dnsCacheRefreshed(count) : S.current.dohDetail_dnsCacheRefreshedSimple,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError(S.current.dohDetail_refreshDnsCacheFailed('$e'));
      }
    } finally {
      if (mounted) {
        setState(() => _dnsCacheBusy = false);
      }
    }
  }

  Future<void> _showAddServerDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final bootstrapIpsController = TextEditingController();

    final result = await showAppDialog<DohServer>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.dohDetail_addServer),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: context.l10n.common_name,
                  hintText: context.l10n.dohDetail_exampleDns,
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: context.l10n.dohDetail_dohAddress,
                  hintText: 'https://dns.example.com/dns-query',
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bootstrapIpsController,
                decoration: InputDecoration(
                  labelText: context.l10n.dohDetail_bootstrapIpOptional,
                  hintText: context.l10n.dohDetail_bootstrapIpHint,
                  helperText: context.l10n.dohDetail_bootstrapIpHelper,
                  helperMaxLines: 2,
                ),
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
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
                final name = nameController.text.trim();
                final url = urlController.text.trim();
                if (name.isEmpty || url.isEmpty) {
                  ToastService.showInfo(S.current.common_fillComplete);
                  return;
                }
                if (!url.startsWith('https://')) {
                  ToastService.showError(S.current.dohDetail_urlMustHttps);
                  return;
                }
                final bootstrapIps = _parseBootstrapIps(bootstrapIpsController.text);
                Navigator.pop(
                  context,
                  DohServer(
                    name: name,
                    url: url,
                    isCustom: true,
                    bootstrapIps: bootstrapIps,
                  ),
                );
              },
              child: Text(context.l10n.common_add),
            ),
          ],
        );
      },
    );

    if (result != null) {
      await _service.addCustomServer(result);
    }
  }

  Future<void> _showEditServerDialog(DohServer server) async {
    final nameController = TextEditingController(text: server.name);
    final urlController = TextEditingController(text: server.url);
    final bootstrapIpsController = TextEditingController(
      text: server.bootstrapIps.join(', '),
    );

    final result = await showAppDialog<DohServer>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.dohDetail_editServer),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: context.l10n.common_name,
                  hintText: context.l10n.dohDetail_exampleDns,
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: context.l10n.dohDetail_dohAddress,
                  hintText: 'https://dns.example.com/dns-query',
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bootstrapIpsController,
                decoration: InputDecoration(
                  labelText: context.l10n.dohDetail_bootstrapIpOptional,
                  hintText: context.l10n.dohDetail_bootstrapIpHint,
                  helperText: context.l10n.dohDetail_bootstrapIpHelper,
                  helperMaxLines: 2,
                ),
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
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
                final name = nameController.text.trim();
                final url = urlController.text.trim();
                if (name.isEmpty || url.isEmpty) {
                  ToastService.showInfo(S.current.common_fillComplete);
                  return;
                }
                if (!url.startsWith('https://')) {
                  ToastService.showError(S.current.dohDetail_urlMustHttps);
                  return;
                }
                final bootstrapIps = _parseBootstrapIps(bootstrapIpsController.text);
                Navigator.pop(
                  context,
                  DohServer(
                    name: name,
                    url: url,
                    isCustom: true,
                    bootstrapIps: bootstrapIps,
                  ),
                );
              },
              child: Text(context.l10n.common_save),
            ),
          ],
        );
      },
    );

    if (result != null) {
      await _service.updateCustomServer(server, result);
    }
  }

  Future<void> _showServerIpDialog() async {
    final settings = _service.current;
    final controller = TextEditingController(
      text: settings.serverIp ?? '',
    );

    final result = await showAppDialog<String?>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(context.l10n.dohDetail_serverIp),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: context.l10n.dohDetail_serverIpHint,
              labelText: context.l10n.dohDetail_ipAddress,
            ),
            keyboardType: TextInputType.text,
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.common_cancel),
            ),
            if (settings.serverIp != null && settings.serverIp!.isNotEmpty)
              TextButton(
                onPressed: () => Navigator.pop(context, ''),
                child: Text(context.l10n.common_clear),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(context.l10n.common_confirm),
            ),
          ],
        );
      },
    );

    if (result != null) {
      await _service.setServerIp(result.isEmpty ? null : result);
    }
  }

  Future<void> _confirmDeleteServer(DohServer server) async {
    final confirm = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.dohDetail_deleteServer),
        content: Text(context.l10n.dohDetail_deleteServerConfirm(server.name)),
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
            child: Text(context.l10n.common_delete),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _service.removeCustomServer(server);
    }
  }

  List<String> _parseBootstrapIps(String text) {
    return text
        .split(RegExp(r'[,\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
}
