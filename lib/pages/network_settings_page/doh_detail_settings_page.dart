import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:app_icons/app_icons.dart';
import 'package:flutter/services.dart';

import '../../l10n/s.dart';
import '../../services/network/doh/doh_resolver.dart';
import '../../utils/dialog_utils.dart';
import '../../services/network/doh/network_settings_service.dart';
import '../../services/network/doh_proxy/doh_proxy_ffi.dart';
import '../../services/toast_service.dart';
import '../../widgets/common/app_bottom_sheet.dart';
import 'package:common_ui/common_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

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
  void initState() {
    super.initState();
    unawaited(_service.refreshDnsCacheStats());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: Listenable.merge([
        _service.notifier,
        _service.dnsCacheStatsNotifier,
      ]),
      builder: (context, _) {
        final settings = _service.current;

        return Scaffold(
          appBar: AppBar(title: Text(context.l10n.dohDetail_title)),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              // IPv6 开关
              SegmentedCardGroup(
                children: [
                  SwitchListTile(
                    title: Text(context.l10n.dohDetail_gatewayMode),
                    subtitle: Text(
                      settings.gatewayEnabled
                          ? context.l10n.dohDetail_gatewayEnabledDesc
                          : context.l10n.dohDetail_gatewayDisabledDesc,
                    ),
                    secondary: const Icon(Symbols.swap_horiz_rounded),
                    value: settings.gatewayEnabled,
                    onChanged: (value) => _service.setGatewayEnabled(value),
                  ),
                  SwitchListTile(
                    title: Text(context.l10n.dohDetail_h2Mitm),
                    subtitle: Text(
                      settings.h2Mitm
                          ? context.l10n.dohDetail_h2MitmEnabledDesc
                          : context.l10n.dohDetail_h2MitmDisabledDesc,
                    ),
                    secondary: const Icon(Symbols.bolt_rounded),
                    value: settings.h2Mitm,
                    onChanged: (value) => _service.setH2Mitm(value),
                  ),
                  SwitchListTile(
                    title: Text(context.l10n.dohDetail_ipv6Prefer),
                    subtitle: Text(context.l10n.dohDetail_ipv6PreferDesc),
                    secondary: const Icon(Symbols.language_rounded),
                    value: settings.preferIPv6,
                    onChanged: (value) => _service.setPreferIPv6(value),
                  ),
                  // Server IP
                  ListTile(
                    leading: const Icon(Symbols.dns_rounded),
                    title: Text(context.l10n.dohDetail_serverIp),
                    subtitle: Text(
                      settings.serverIp != null &&
                              settings.serverIp!.isNotEmpty
                          ? settings.serverIp!
                          : context.l10n.common_notSet,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    trailing:
                        settings.serverIp != null &&
                            settings.serverIp!.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Symbols.clear_rounded, size: 20),
                            tooltip: context.l10n.common_clear,
                            onPressed: () => _service.setServerIp(null),
                          )
                        : null,
                    onTap: () => _showServerIpDialog(),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // 服务器列表
              _buildSectionHeader(theme, context.l10n.dohDetail_servers),
              const SizedBox(height: 12),
              _buildServerList(theme, settings),
              const SizedBox(height: 24),

              // ECH 服务器选择
              _buildSectionHeader(theme, 'ECH'),
              const SizedBox(height: 12),
              SegmentedCardGroup(
                children: [_buildEchServerSelector(theme, settings)],
              ),
              const SizedBox(height: 24),

              _buildSectionHeader(
                theme,
                context.l10n.dohDetail_dnsCacheSection,
              ),
              const SizedBox(height: 12),
              _buildDnsCacheCard(theme),
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
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
    );
  }

  Widget _buildServerList(ThemeData theme, NetworkSettings settings) {
    final servers = _service.servers;

    return RadioGroup<String>(
      groupValue: settings.selectedServerUrl,
      onChanged: (value) {
        if (value != null) _service.setSelectedServer(value);
      },
      child: SegmentedCardGroup(
        children: [
          // 工具栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: [
                const Spacer(),
                TextButton.icon(
                  onPressed: _testingAll ? null : _testAllServers,
                  icon: _testingAll
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Symbols.speed_rounded, size: 16),
                  label: Text(
                    _testingAll
                        ? context.l10n.dohDetail_testingSpeed
                        : context.l10n.dohDetail_testAllSpeed,
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                TextButton.icon(
                  onPressed: _showAddServerDialog,
                  icon: const Icon(Symbols.add_rounded, size: 16),
                  label: Text(context.l10n.common_add),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          for (final server in servers)
            _buildServerTile(theme, server, settings),
          if (servers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(S.current.dohDetail_noServers),
            ),
        ],
      ),
    );
  }

  Widget _buildServerTile(
    ThemeData theme,
    DohServer server,
    NetworkSettings settings,
  ) {
    final selected = server.url == settings.selectedServerUrl;
    final isTesting = _testingServers.contains(server.url);
    final latency = _latencies[server.url];

    return ListTile(
      contentPadding: const EdgeInsets.only(left: 8, right: 12),
      leading: Radio<String>(value: server.url),
      title: Row(
        children: [
          Expanded(child: Text(server.name, overflow: TextOverflow.ellipsis)),
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
                icon: const Icon(Symbols.speed_rounded, size: 20),
                tooltip: S.current.dohDetail_testSpeed,
                onPressed: () => _testServer(server),
                visualDensity: VisualDensity.compact,
              ),
            ),
          SwipeDismissiblePopupMenuButton<String>(
            icon: Icon(
              Symbols.more_vert_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
                  leading: const Icon(Symbols.content_copy_rounded, size: 20),
                  title: Text(S.current.dohDetail_copyAddress),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (server.isCustom) ...[
                PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    leading: const Icon(Symbols.edit_rounded, size: 20),
                    title: Text(S.current.common_edit),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(
                      Symbols.delete_rounded,
                      size: 20,
                      color: theme.colorScheme.error,
                    ),
                    title: Text(
                      S.current.common_delete,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
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
      leading: const Icon(Symbols.security_rounded),
      title: Text(S.current.dohDetail_echServer),
      subtitle: Text(
        echLabel,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: const Icon(Symbols.chevron_right_rounded),
      onTap: () => _showEchServerDialog(servers, currentEch),
    );
  }

  Widget _buildDnsCacheCard(ThemeData theme) {
    final cacheCount = _service.dnsCacheEntryCount;
    return SegmentedCardGroup(
      children: [
        ListTile(
          leading: const Icon(Symbols.storage_rounded),
          title: Text(S.current.dohDetail_localDnsCache),
          trailing: IconButton(
            icon: const Icon(Symbols.list_alt_rounded),
            tooltip: S.current.dohDetail_viewDnsRecords,
            onPressed: _showDnsCacheRecords,
          ),
          subtitle: Text(
            S.current.dohDetail_dnsCacheDesc(cacheCount),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
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
                      : const Icon(Symbols.delete_rounded),
                  label: Text(
                    _dnsCacheBusy
                        ? S.current.dohDetail_processing
                        : S.current.dohDetail_clearCache,
                  ),
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
                      : const Icon(Symbols.refresh_rounded),
                  label: Text(
                    _dnsCacheBusy
                        ? S.current.dohDetail_processing
                        : S.current.dohDetail_forceRefresh,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showDnsCacheRecords() async {
    await AppBottomSheet.showDraggable<void>(
      context: context,
      title: context.l10n.dohDetail_dnsRecords,
      showCloseButton: true,
      contentPadding: EdgeInsets.zero,
      initialSize: 0.75,
      minSize: 0.5,
      maxSize: 0.95,
      bodyBuilder: (context, scrollController) {
        return _DnsRecordsSheet(scrollController: scrollController);
      },
    );
  }

  Future<void> _showEchServerDialog(
    List<DohServer> servers,
    String? currentEch,
  ) async {
    final result = await showAppDialog<String?>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text(context.l10n.dohDetail_selectEchServer),
          children: [
            RadioGroup<String?>(
              groupValue: currentEch,
              onChanged: (value) => Navigator.pop(context, value ?? '__null__'),
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
          count > 0
              ? S.current.dohDetail_dnsCacheRefreshed(count)
              : S.current.dohDetail_dnsCacheRefreshedSimple,
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
                final bootstrapIps = _parseBootstrapIps(
                  bootstrapIpsController.text,
                );
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
                final bootstrapIps = _parseBootstrapIps(
                  bootstrapIpsController.text,
                );
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
    final controller = TextEditingController(text: settings.serverIp ?? '');

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

class _DnsCacheRecordGroup {
  const _DnsCacheRecordGroup({required this.host, required this.records});

  final String host;
  final List<DohDnsCacheRecord> records;

  bool get hasEch => records.any((r) => r.kind == 'ech');
  bool get hasEchNegative => records.any((r) => r.kind == 'ech_negative');
  String? get stickyIp =>
      records.firstWhereOrNull((r) => r.kind == 'preferred_ip')?.values.first;
  List<String> get ips =>
      records.firstWhereOrNull((r) => r.kind == 'ip')?.values ?? const [];
  String? get echConfig =>
      records.firstWhereOrNull((r) => r.kind == 'ech')?.values.firstOrNull;
  Duration get maxTtl => records
      .where((r) => r.kind != 'ech_negative')
      .map((r) => r.ttl)
      .fold(Duration.zero, (a, b) => a > b ? a : b);
}

List<_DnsCacheRecordGroup> _groupDnsRecords(List<DohDnsCacheRecord> records) {
  final grouped = <String, List<DohDnsCacheRecord>>{};
  for (final record in records) {
    grouped.putIfAbsent(record.host, () => <DohDnsCacheRecord>[]).add(record);
  }

  final groups = grouped.entries.map((entry) {
    final list = entry.value
      ..sort(
        (a, b) =>
            _dnsRecordKindOrder(a.kind).compareTo(_dnsRecordKindOrder(b.kind)),
      );
    return _DnsCacheRecordGroup(host: entry.key, records: list);
  }).toList();
  groups.sort((a, b) => a.host.compareTo(b.host));
  return groups;
}

int _dnsRecordKindOrder(String kind) {
  switch (kind) {
    case 'ip':
      return 0;
    case 'ech':
      return 1;
    case 'ech_negative':
      return 2;
    case 'preferred_ip':
      return 3;
    default:
      return 4;
  }
}

String _formatDnsRecordTtl(Duration ttl) {
  if (ttl <= Duration.zero) {
    return '0s';
  }
  if (ttl.inHours > 0) {
    final minutes = ttl.inMinutes.remainder(60);
    return minutes == 0 ? '${ttl.inHours}h' : '${ttl.inHours}h ${minutes}m';
  }
  if (ttl.inMinutes > 0) {
    final seconds = ttl.inSeconds.remainder(60);
    return seconds == 0
        ? '${ttl.inMinutes}m'
        : '${ttl.inMinutes}m ${seconds}s';
  }
  return '${ttl.inSeconds}s';
}

class _DnsRecordsSheet extends StatefulWidget {
  const _DnsRecordsSheet({required this.scrollController});

  final ScrollController scrollController;

  @override
  State<_DnsRecordsSheet> createState() => _DnsRecordsSheetState();
}

class _DnsRecordsSheetState extends State<_DnsRecordsSheet> {
  final TextEditingController _searchController = TextEditingController();
  late final Future<List<DohDnsCacheRecord>> _recordsFuture;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _recordsFuture = NetworkSettingsService.instance.dnsCacheRecords();
    _searchController.addListener(() {
      final next = _searchController.text.trim().toLowerCase();
      if (next != _query) {
        setState(() => _query = next);
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;

    return FutureBuilder<List<DohDnsCacheRecord>>(
      future: _recordsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: LoadingSpinner());
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(snapshot.error.toString()),
          );
        }

        final records = snapshot.data ?? const <DohDnsCacheRecord>[];
        final groups = _groupDnsRecords(records);
        final visibleGroups = _query.isEmpty
            ? groups
            : groups.where((g) => g.host.toLowerCase().contains(_query)).toList();

        if (records.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                l10n.dohDetail_noDnsRecords,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }

        return CustomScrollView(
          controller: widget.scrollController,
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _DnsRecordsHeaderDelegate(
                child: _buildHeader(theme, l10n, groups.length),
              ),
            ),
            if (visibleGroups.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    l10n.dohDetail_hostsSearchEmpty,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                sliver: SliverList.separated(
                  itemCount: visibleGroups.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) =>
                      _DnsRecordGroupCard(group: visibleGroups[index]),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(ThemeData theme, AppLocalizations l10n, int totalCount) {
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Symbols.search_rounded, size: 20),
              hintText: l10n.dohDetail_searchHosts,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.4,
                  ),
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.4,
                  ),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: theme.colorScheme.primary),
              ),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Symbols.close_rounded, size: 18),
                      onPressed: () => _searchController.clear(),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.dohDetail_hostsCount(totalCount),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _DnsRecordsHeaderDelegate extends SliverPersistentHeaderDelegate {
  _DnsRecordsHeaderDelegate({required this.child});

  final Widget child;

  @override
  double get minExtent => 84;
  @override
  double get maxExtent => 84;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(color: Colors.transparent, child: child);
  }

  @override
  bool shouldRebuild(covariant _DnsRecordsHeaderDelegate oldDelegate) =>
      oldDelegate.child != child;
}

class _DnsRecordGroupCard extends StatefulWidget {
  const _DnsRecordGroupCard({required this.group});

  final _DnsCacheRecordGroup group;

  @override
  State<_DnsRecordGroupCard> createState() => _DnsRecordGroupCardState();
}

class _DnsRecordGroupCardState extends State<_DnsRecordGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final group = widget.group;
    final hasDetails = group.ips.isNotEmpty || group.echConfig != null;

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: hasDetails
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 头部：host 名 + 展开箭头
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          group.host,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: group.host));
                          ToastService.showInfo(l10n.dohDetail_recordCopied);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            Symbols.content_copy_rounded,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (hasDetails)
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: Icon(
                            Symbols.expand_more_rounded,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 状态标签行
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (group.ips.isNotEmpty)
                        _StatusChip(
                          icon: Symbols.public_rounded,
                          label: '${group.ips.length} IP',
                        ),
                      if (group.maxTtl > Duration.zero)
                        _StatusChip(
                          icon: Symbols.timer_rounded,
                          label: 'TTL ${_formatDnsRecordTtl(group.maxTtl)}',
                        ),
                      if (group.hasEch)
                        _StatusChip(
                          icon: Symbols.shield_rounded,
                          label: l10n.dohDetail_echAvailable,
                          tone: _ChipTone.success,
                        )
                      else if (group.hasEchNegative)
                        _StatusChip(
                          icon: Symbols.shield_rounded,
                          label: l10n.dohDetail_echUnavailable,
                          tone: _ChipTone.muted,
                        ),
                      if (group.stickyIp != null)
                        _StatusChip(
                          icon: Symbols.push_pin_rounded,
                          label: '${l10n.dohDetail_stickyIp} ${group.stickyIp}',
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (group.ips.isNotEmpty)
                    _RecordSection(
                      icon: Symbols.public_rounded,
                      label: l10n.dohDetail_ipAddresses,
                      values: group.ips,
                      copyText: group.ips.join('\n'),
                    ),
                  if (group.echConfig != null) ...[
                    if (group.ips.isNotEmpty) const SizedBox(height: 10),
                    _RecordSection(
                      icon: Symbols.security_rounded,
                      label: l10n.dohDetail_echConfig,
                      values: [group.echConfig!],
                      copyText: group.echConfig!,
                      ellipsisLong: true,
                    ),
                  ],
                ],
              ),
            ),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 180),
            sizeCurve: Curves.easeInOut,
          ),
        ],
      ),
    );
  }
}

enum _ChipTone { neutral, success, muted }

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    this.tone = _ChipTone.neutral,
  });

  final IconData icon;
  final String label;
  final _ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (bg, fg) = switch (tone) {
      _ChipTone.success => (
        theme.colorScheme.tertiaryContainer.withValues(alpha: 0.7),
        theme.colorScheme.onTertiaryContainer,
      ),
      _ChipTone.muted => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
      _ChipTone.neutral => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: fg),
          ),
        ],
      ),
    );
  }
}

class _RecordSection extends StatelessWidget {
  const _RecordSection({
    required this.icon,
    required this.label,
    required this.values,
    required this.copyText,
    this.ellipsisLong = false,
  });

  final IconData icon;
  final String label;
  final List<String> values;
  final String copyText;
  final bool ellipsisLong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
            const Spacer(),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                Clipboard.setData(ClipboardData(text: copyText));
                ToastService.showInfo(
                  context.l10n.dohDetail_recordCopied,
                );
              },
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Symbols.content_copy_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
          child: SelectableText(
            values.join('\n'),
            maxLines: ellipsisLong ? 3 : null,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
