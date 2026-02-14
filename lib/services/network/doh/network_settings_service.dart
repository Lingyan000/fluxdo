import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../constants.dart';
import '../doh_proxy/doh_proxy_service.dart';
import 'doh_resolver.dart';

class NetworkSettings {
  const NetworkSettings({
    required this.dohEnabled,
    required this.selectedServerUrl,
    required this.customServers,
    required this.proxyPort,
    this.preferIPv6 = false,
  });

  final bool dohEnabled;
  final String selectedServerUrl;
  final List<DohServer> customServers;
  /// 代理端口（Rust 代理统一处理 DOH + ECH）
  final int? proxyPort;
  /// 优先使用 IPv6
  final bool preferIPv6;

  NetworkSettings copyWith({
    bool? dohEnabled,
    String? selectedServerUrl,
    List<DohServer>? customServers,
    int? proxyPort,
    bool? preferIPv6,
  }) {
    return NetworkSettings(
      dohEnabled: dohEnabled ?? this.dohEnabled,
      selectedServerUrl: selectedServerUrl ?? this.selectedServerUrl,
      customServers: customServers ?? this.customServers,
      proxyPort: proxyPort ?? this.proxyPort,
      preferIPv6: preferIPv6 ?? this.preferIPv6,
    );
  }
}

class DohServer {
  const DohServer({
    required this.name,
    required this.url,
    this.bootstrapIps = const [],
    this.isCustom = false,
  });

  final String name;
  final String url;
  /// Bootstrap IP 地址列表，用于直接连接 DOH 服务器（解决鸡蛋问题）
  /// Chrome 也是这样做的：预置 DOH 服务器的 IP，直接用 IP 连接
  final List<String> bootstrapIps;
  final bool isCustom;

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        if (bootstrapIps.isNotEmpty) 'bootstrapIps': bootstrapIps,
      };

  static DohServer fromJson(Map<String, dynamic> json) {
    final ips = json['bootstrapIps'];
    return DohServer(
      name: json['name']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      bootstrapIps: ips is List ? ips.cast<String>() : const [],
      isCustom: true,
    );
  }
}

class NetworkSettingsService {
  NetworkSettingsService._internal();

  static final NetworkSettingsService instance = NetworkSettingsService._internal();

  static const _dohEnabledKey = 'doh_enabled';
  static const _dohSelectedKey = 'doh_selected';
  static const _dohCustomKey = 'doh_custom';
  static const _proxyPortKey = 'doh_proxy_port';
  static const _preferIPv6Key = 'doh_prefer_ipv6';

  final ValueNotifier<NetworkSettings> notifier = ValueNotifier(
    NetworkSettings(
      dohEnabled: false,
      selectedServerUrl: _defaultServers.first.url,
      customServers: const [],
      proxyPort: null,
    ),
  );

  /// Rust 代理服务（处理 DOH + ECH）
  final DohProxyService _rustProxyService = DohProxyService.instance;

  late DohResolver _resolver;
  SharedPreferences? _prefs;
  int _version = 0;
  int _applyDepth = 0;
  Timer? _applyDebounce;
  bool _lastStartFailed = false;
  bool _wasRunningBeforeApply = false;
  bool _pendingStart = false;

  final ValueNotifier<bool> isApplying = ValueNotifier(false);

  int get version => _version;
  DohResolver get resolver => _resolver;
  bool get lastStartFailed => _lastStartFailed;
  bool get wasRunningBeforeApply => _wasRunningBeforeApply;
  bool get pendingStart => _pendingStart;

  /// 获取代理服务（优先使用 Rust 代理）
  DohProxyService get proxyService => _rustProxyService;

  NetworkSettings get current => notifier.value;

  List<DohServer> get servers => [
        ..._defaultServers,
        ...notifier.value.customServers,
      ];

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    final dohEnabled = prefs.getBool(_dohEnabledKey) ?? false;
    final selected = prefs.getString(_dohSelectedKey) ?? _defaultServers.first.url;
    final customRaw = prefs.getString(_dohCustomKey);
    final custom = _decodeServers(customRaw);
    final proxyPort = prefs.getInt(_proxyPortKey);
    await prefs.remove('doh_multi_ip');
    final preferIPv6 = prefs.getBool(_preferIPv6Key) ?? false;
    final resolvedSelected = _resolveSelected(selected, custom);
    notifier.value = NetworkSettings(
      dohEnabled: dohEnabled,
      selectedServerUrl: resolvedSelected,
      customServers: custom,
      proxyPort: proxyPort,
      preferIPv6: preferIPv6,
    );
    _resolver = DohResolver(
      serverUrl: notifier.value.selectedServerUrl,
      bootstrapIps: _getBootstrapIps(notifier.value.selectedServerUrl),
      preferIPv6: preferIPv6,
    );
    await _applyProxyState();
    _touch();
  }

  Future<void> setDohEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    _beginApply(enabled: enabled);
    notifier.value = notifier.value.copyWith(dohEnabled: enabled);
    if (!enabled && _lastStartFailed) {
      _setStartFailed(false);
    }
    await prefs.setBool(_dohEnabledKey, enabled);
    await _applyProxyState();
    _touch();
  }

  Future<void> setSelectedServer(String url) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(selectedServerUrl: url);
    _resolver.updateServer(url, bootstrapIps: _getBootstrapIps(url));
    await prefs.setString(_dohSelectedKey, url);
    _scheduleApplyProxyState();
    _touch(); // 在代理状态更新完成后触发
  }

  Future<void> addCustomServer(DohServer server) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = [...notifier.value.customServers, server];
    notifier.value = notifier.value.copyWith(customServers: updated);
    await prefs.setString(_dohCustomKey, jsonEncode(updated.map((e) => e.toJson()).toList()));
    _touch();
  }

  Future<void> removeCustomServer(DohServer server) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = notifier.value.customServers.where((s) => s.url != server.url).toList();
    final resolvedSelected = _resolveSelected(notifier.value.selectedServerUrl, updated);
    notifier.value = notifier.value.copyWith(
      customServers: updated,
      selectedServerUrl: resolvedSelected,
    );
    _resolver.updateServer(resolvedSelected, bootstrapIps: _getBootstrapIps(resolvedSelected));
    await prefs.setString(_dohCustomKey, jsonEncode(updated.map((e) => e.toJson()).toList()));
    _touch();
  }

  Future<void> resetDefaultServers() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final resolvedSelected = _resolveSelected(notifier.value.selectedServerUrl, const []);
    notifier.value = notifier.value.copyWith(
      customServers: const [],
      selectedServerUrl: resolvedSelected,
    );
    _resolver.updateServer(resolvedSelected, bootstrapIps: _getBootstrapIps(resolvedSelected));
    await prefs.setString(_dohCustomKey, jsonEncode([]));
    _touch();
  }

  Future<void> setPreferIPv6(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(preferIPv6: enabled);
    _resolver.preferIPv6 = enabled;
    await prefs.setBool(_preferIPv6Key, enabled);
    _scheduleApplyProxyState();
    _touch();
  }


  Future<void> _applyProxyState() async {
    final startedAt = DateTime.now();
    _applyDepth++;
    if (_applyDepth == 1) {
      if (!isApplying.value) {
        _wasRunningBeforeApply = _rustProxyService.isRunning;
        isApplying.value = true;
      }
      // 给 UI 一帧时间渲染 Loading
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (!current.dohEnabled) {
      try {
        await _rustProxyService.stop();
        await _clearWebViewProxy();
        if (_pendingStart) {
          _setPendingStart(false);
        }
        final prefs = _prefs;
        if (current.proxyPort != null) {
          notifier.value = notifier.value.copyWith(proxyPort: null);
          if (prefs != null) {
            await prefs.remove(_proxyPortKey);
          }
          _touch();
        }
        if (_lastStartFailed) {
          _setStartFailed(false);
        }
      } finally {
        _applyDepth--;
        if (_applyDepth == 0) {
          final elapsed = DateTime.now().difference(startedAt);
          const minDuration = Duration(milliseconds: 400);
          if (elapsed < minDuration) {
            await Future<void>.delayed(minDuration - elapsed);
          }
          isApplying.value = false;
        }
      }
      return;
    }

    try {
      // 启动 Rust 代理（内部处理 DOH + ECH）
      final success = await _rustProxyService.start(
        preferredPort: current.proxyPort ?? 0,
        preferIPv6: current.preferIPv6,
        dohServer: current.selectedServerUrl,
      );

      if (!success) {
        debugPrint('[DOH] Failed to start Rust proxy');
        _setStartFailed(true);
        _setPendingStart(false);
        await _clearWebViewProxy();
        return;
      }

      if (_lastStartFailed) {
        _setStartFailed(false);
      }
      if (_pendingStart) {
        _setPendingStart(false);
      }

      // 获取实际使用的端口（Rust 代理）
      final activePort = _rustProxyService.port;
      if (current.proxyPort != activePort) {
        final prefs = _prefs;
        if (prefs != null && activePort != null) {
          await prefs.setInt(_proxyPortKey, activePort);
          notifier.value = notifier.value.copyWith(proxyPort: activePort);
          _touch(); // 触发 HttpClient 重建
        }
      }

      await _applyWebViewProxy();
    } finally {
      _applyDepth--;
      if (_applyDepth == 0) {
        final elapsed = DateTime.now().difference(startedAt);
        const minDuration = Duration(milliseconds: 400);
        if (elapsed < minDuration) {
          await Future<void>.delayed(minDuration - elapsed);
        }
        isApplying.value = false;
        _touch();
      }
    }
  }

  void _setStartFailed(bool value) {
    if (_lastStartFailed == value) return;
    _lastStartFailed = value;
    _touch();
  }

  void _setPendingStart(bool value) {
    if (_pendingStart == value) return;
    _pendingStart = value;
    _touch();
  }

  Future<void> restartProxy() async {
    _beginApply(enabled: true);
    await _applyProxyState();
    _touch();
  }

  void _scheduleApplyProxyState() {
    if (!current.dohEnabled) {
      return;
    }
    _beginApply(enabled: true);
    _applyDebounce?.cancel();
    _applyDebounce = Timer(const Duration(milliseconds: 350), () async {
      await _applyProxyState();
      _touch();
    });
  }

  void _beginApply({required bool enabled}) {
    _wasRunningBeforeApply = _rustProxyService.isRunning;
    if (enabled) {
      _setPendingStart(true);
    }
    if (!isApplying.value) {
      isApplying.value = true;
    }
  }

  /// 获取当前活动的代理端口
  int? get _activeProxyPort => _rustProxyService.port;

  Future<void> _applyWebViewProxy() async {
    if (!current.dohEnabled) return;
    if (!Platform.isAndroid) return;
    final port = _activeProxyPort;
    if (port == null) return;
    try {
      await ProxyController.instance().setProxyOverride(
        settings: ProxySettings(
          proxyRules: [
            ProxyRule(url: 'http://127.0.0.1:$port'),
          ],
        ),
      );
    } catch (e) {
      debugPrint('[NetworkSettings] Failed to set WebView proxy: $e');
    }
  }

  Future<void> _clearWebViewProxy() async {
    if (!Platform.isAndroid) return;
    try {
      await ProxyController.instance().clearProxyOverride();
    } catch (e) {
      debugPrint('[NetworkSettings] Failed to clear WebView proxy: $e');
    }
  }

  void _touch() {
    _version++;
    // 通过重新赋值触发监听器更新
    notifier.value = notifier.value.copyWith();
  }

  String _resolveSelected(String selected, List<DohServer> customServers) {
    final allServers = [..._defaultServers, ...customServers];
    final found = allServers.any((s) => s.url == selected);
    return found ? selected : _defaultServers.first.url;
  }

  /// 根据 URL 查找服务器配置
  DohServer? _findServer(String url) {
    final allServers = [..._defaultServers, ...notifier.value.customServers];
    for (final server in allServers) {
      if (server.url == url) return server;
    }
    return null;
  }

  /// 获取选中服务器的 Bootstrap IP
  List<String> _getBootstrapIps(String url) {
    return _findServer(url)?.bootstrapIps ?? [];
  }

  List<DohServer> _decodeServers(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list
            .whereType<Map>()
            .map((e) => DohServer.fromJson(e.cast<String, dynamic>()))
            .toList();
      }
    } catch (e) {
      debugPrint('[NetworkSettings] Failed to decode custom servers: $e');
    }
    return const [];
  }

  String get testHost {
    final baseUri = Uri.tryParse(AppConstants.baseUrl);
    return baseUri?.host ?? 'example.com';
  }
}

/// 默认 DOH 服务器列表
/// Bootstrap IP 来源：各 DNS 提供商官方文档
/// Chrome 也是这样实现的：预置 IP 地址，直接连接，不需要先 DNS 解析
const List<DohServer> _defaultServers = [
  DohServer(
    name: 'DNSPod',
    url: 'https://doh.pub/dns-query',
    bootstrapIps: ['1.12.12.12', '120.53.53.53'],
  ),
  DohServer(
    name: '腾讯 DNS',
    url: 'https://dns.pub/dns-query',
    bootstrapIps: ['119.29.29.29', '119.28.28.28'],
  ),
  DohServer(
    name: 'Cloudflare',
    url: 'https://cloudflare-dns.com/dns-query',
    bootstrapIps: ['1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001'],
  ),
  DohServer(
    name: 'Canadian Shield',
    url: 'https://private.canadianshield.cira.ca/dns-query',
  ),
  DohServer(
    name: '阿里 DNS',
    url: 'https://dns.alidns.com/dns-query',
    bootstrapIps: ['223.5.5.5', '223.6.6.6', '2400:3200::1', '2400:3200:baba::1'],
  ),
  DohServer(
    name: 'Quad9',
    url: 'https://dns.quad9.net/dns-query',
    bootstrapIps: ['9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'],
  ),
  DohServer(
    name: 'Google',
    url: 'https://dns.google/dns-query',
    bootstrapIps: ['8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'],
  ),
];
