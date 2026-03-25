import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inappwebview;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../constants.dart';
import '../../preloaded_data_service.dart';
import '../doh_proxy/cert_preference_service.dart';
import '../doh_proxy/doh_proxy_service.dart';
import '../doh_proxy/per_device_cert_service.dart';
import '../doh_proxy/proxy_certificate.dart';
import '../proxy/proxy_settings_service.dart';
import '../rhttp/rhttp_settings_service.dart';
import 'doh_resolver.dart';

class NetworkSettings {
  const NetworkSettings({
    required this.dohEnabled,
    required this.selectedServerUrl,
    this.echServerUrl,
    required this.customServers,
    required this.proxyPort,
    this.preferIPv6 = false,
    this.serverIp,
    this.gatewayEnabled = true,
  });

  final bool dohEnabled;
  /// DNS 解析服务器（A/AAAA 查询）
  final String selectedServerUrl;
  /// ECH 配置服务器（HTTPS 记录查询），null = 与 DNS 相同
  final String? echServerUrl;
  final List<DohServer> customServers;
  /// 代理端口（Rust 代理统一处理 DOH + ECH）
  final int? proxyPort;
  /// 优先使用 IPv6
  final bool preferIPv6;
  /// 全局 server IP（指定后跳过 DNS 解析直接连接）
  final String? serverIp;
  /// Gateway（反向代理）模式开关，关闭时回退为 MITM
  final bool gatewayEnabled;

  NetworkSettings copyWith({
    bool? dohEnabled,
    String? selectedServerUrl,
    String? Function()? echServerUrl,
    List<DohServer>? customServers,
    int? proxyPort,
    bool? preferIPv6,
    String? Function()? serverIp,
    bool? gatewayEnabled,
  }) {
    return NetworkSettings(
      dohEnabled: dohEnabled ?? this.dohEnabled,
      selectedServerUrl: selectedServerUrl ?? this.selectedServerUrl,
      echServerUrl: echServerUrl != null ? echServerUrl() : this.echServerUrl,
      customServers: customServers ?? this.customServers,
      proxyPort: proxyPort ?? this.proxyPort,
      preferIPv6: preferIPv6 ?? this.preferIPv6,
      gatewayEnabled: gatewayEnabled ?? this.gatewayEnabled,
      serverIp: serverIp != null ? serverIp() : this.serverIp,
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

class ResolvedHostConfig {
  const ResolvedHostConfig({
    required this.dnsOverrides,
    this.preferredIp,
    this.echConfig,
  });

  const ResolvedHostConfig.empty()
      : dnsOverrides = const [],
        preferredIp = null,
        echConfig = null;

  final List<String> dnsOverrides;
  final String? preferredIp;
  final Uint8List? echConfig;
}

class _ResolvedHostEntry {
  _ResolvedHostEntry({
    required this.ips,
    required this.preferredIp,
    required this.echConfig,
    required this.ttl,
    required this.resolvedAt,
  }) : expiresAt = resolvedAt.add(ttl);

  final List<String> ips;
  final String? preferredIp;
  final Uint8List? echConfig;
  final Duration ttl;
  final DateTime resolvedAt;
  final DateTime expiresAt;

  bool get hasData => ips.isNotEmpty || (echConfig?.isNotEmpty ?? false);
  bool get isExpired => !expiresAt.isAfter(DateTime.now());

  Duration get remaining {
    final value = expiresAt.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  Duration get refreshLeadTime {
    final byRatio = Duration(milliseconds: (ttl.inMilliseconds / 5).round());
    if (byRatio < _minDnsRefreshLeadTime) {
      return _minDnsRefreshLeadTime;
    }
    if (byRatio > _maxDnsRefreshLeadTime) {
      return _maxDnsRefreshLeadTime;
    }
    return byRatio;
  }

  bool get shouldRefreshSoon => remaining <= refreshLeadTime;
}

const Duration _defaultDnsCacheTtl = Duration(minutes: 5);
const Duration _missDnsCacheTtl = Duration(minutes: 1);
const Duration _minDnsRefreshLeadTime = Duration(seconds: 30);
const Duration _maxDnsRefreshLeadTime = Duration(minutes: 2);
const Duration _failedHostIpPenaltyTtl = Duration(minutes: 2);

class NetworkSettingsService {
  NetworkSettingsService._internal() {
    _proxyService.notifier.addListener(_handleProxySettingsChanged);
    RhttpSettingsService.instance.notifier.addListener(_handleRhttpSettingsChanged);
  }

  static final NetworkSettingsService instance = NetworkSettingsService._internal();

  static const _dohEnabledKey = 'doh_enabled';
  static const _dohSelectedKey = 'doh_selected';
  static const _dohCustomKey = 'doh_custom';
  static const _proxyPortKey = 'doh_proxy_port';
  static const _preferIPv6Key = 'doh_prefer_ipv6';
  static const _serverIpKey = 'doh_server_ip';
  static const _echServerKey = 'doh_ech_server';
  static const _gatewayEnabledKey = 'doh_gateway_enabled';

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
  final ProxySettingsService _proxyService = ProxySettingsService.instance;

  late DohResolver _resolver;
  SharedPreferences? _prefs;
  int _version = 0;
  int _applyDepth = 0;
  Timer? _applyDebounce;
  bool _lastStartFailed = false;
  bool _wasRunningBeforeApply = false;
  bool _pendingStart = false;
  final Map<String, _ResolvedHostEntry> _resolvedHostCache = {};
  final Map<String, Future<_ResolvedHostEntry?>> _hostLookupInflight = {};
  final Set<String> _backgroundRefreshingHosts = <String>{};
  final Map<String, Map<String, DateTime>> _hostIpPenaltyCache = {};
  String? _resolvedHostCacheSignature;

  final ValueNotifier<bool> isApplying = ValueNotifier(false);

  int get version => _version;
  DohResolver get resolver => _resolver;
  bool get lastStartFailed => _lastStartFailed;
  bool get wasRunningBeforeApply => _wasRunningBeforeApply;
  bool get pendingStart => _pendingStart;
  int get dnsCacheEntryCount => _resolvedHostCache.length;

  /// 获取代理服务（优先使用 Rust 代理）
  DohProxyService get proxyService => _rustProxyService;

  NetworkSettings get current => notifier.value;

  /// 当前是否使用 gateway（反向代理）模式
  /// Gateway 模式：DOH 开启 + 用户开关开启 + 代理运行中
  bool get isGatewayMode =>
      current.dohEnabled && current.gatewayEnabled && _rustProxyService.isRunning;

  String? get _effectiveEchServerUrl =>
      current.dohEnabled ? (current.echServerUrl ?? current.selectedServerUrl) : null;

  // Rust 代理始终为 WebView 提供 DOH/代理支持，不受 rhttp 影响
  // rhttp 只改变 Dio 用哪个适配器，不改变代理生命周期
  bool get shouldRunLocalProxy => current.dohEnabled || _proxyService.current.isValid;

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
    final serverIp = prefs.getString(_serverIpKey);
    final echServer = prefs.getString(_echServerKey);
    final gatewayEnabled = prefs.getBool(_gatewayEnabledKey) ?? true;
    final resolvedSelected = _resolveSelected(selected, custom);
    notifier.value = NetworkSettings(
      dohEnabled: dohEnabled,
      selectedServerUrl: resolvedSelected,
      echServerUrl: echServer,
      customServers: custom,
      proxyPort: proxyPort,
      preferIPv6: preferIPv6,
      serverIp: serverIp,
      gatewayEnabled: gatewayEnabled,
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
    _beginApply(enabled: enabled || _proxyService.current.isValid);
    notifier.value = notifier.value.copyWith(dohEnabled: enabled);
    if (!enabled) {
      _clearResolvedHostCache();
    }
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
    if (current.dohEnabled) {
      _clearResolvedHostCache();
    }
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

  Future<void> updateCustomServer(DohServer oldServer, DohServer newServer) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = notifier.value.customServers
        .map((s) => s.url == oldServer.url ? newServer : s)
        .toList();
    final selectedUrl = notifier.value.selectedServerUrl;
    final newSelected = selectedUrl == oldServer.url ? newServer.url : selectedUrl;
    notifier.value = notifier.value.copyWith(
      customServers: updated,
      selectedServerUrl: newSelected,
    );
    if (newSelected != selectedUrl) {
      _resolver.updateServer(newSelected, bootstrapIps: _getBootstrapIps(newSelected));
      _clearResolvedHostCache();
      _scheduleApplyProxyState();
    }
    await prefs.setString(_dohCustomKey, jsonEncode(updated.map((e) => e.toJson()).toList()));
    if (newSelected != selectedUrl) {
      await prefs.setString(_dohSelectedKey, newSelected);
    }
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
    _clearResolvedHostCache();
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
    _clearResolvedHostCache();
    await prefs.setString(_dohCustomKey, jsonEncode([]));
    _touch();
  }

  Future<void> setPreferIPv6(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(preferIPv6: enabled);
    _resolver.preferIPv6 = enabled;
    _clearResolvedHostCache();
    await prefs.setBool(_preferIPv6Key, enabled);
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setServerIp(String? ip) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final trimmed = ip?.trim();
    final value = (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
    notifier.value = notifier.value.copyWith(serverIp: () => value);
    _clearResolvedHostCache();
    if (value != null) {
      await prefs.setString(_serverIpKey, value);
    } else {
      await prefs.remove(_serverIpKey);
    }
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setEchServer(String? url) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(echServerUrl: () => url);
    _clearResolvedHostCache();
    if (url != null) {
      await prefs.setString(_echServerKey, url);
    } else {
      await prefs.remove(_echServerKey);
    }
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setGatewayEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(gatewayEnabled: enabled);
    await prefs.setBool(_gatewayEnabledKey, enabled);
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
    if (!shouldRunLocalProxy) {
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
      final upstream = _proxyService.current;
      final effectiveEchServer = _effectiveEchServerUrl;

      // ECH 场景：rhttp 按请求 host 查询 ECH；gateway 模式仅作为 WebView 后备。
      final shouldTryEch = effectiveEchServer != null;
      final useGateway = current.dohEnabled && current.gatewayEnabled;

      if (!shouldTryEch) {
        _clearResolvedHostCache();
      }

      // macOS: 启动前确保 CA 在钥匙串中被信任
      if (Platform.isMacOS && current.dohEnabled) {
        final trusted = await ProxyCertificate.ensureKeychainTrust();
        if (!trusted) {
          debugPrint('[DOH] macOS: CA 未被钥匙串信任，无法启动代理');
          _setStartFailed(true);
          _setPendingStart(false);
          return;
        }
      }

      // per-device CA: 读取证书传给代理（iOS/macOS 强制，其他平台可选）
      String? caCertPem;
      String? caKeyPem;
      if (await CertPreferenceService.usePerDevice()) {
        final certService = PerDeviceCertService.instance;
        if (certService.isLoaded || await certService.ensureCaCert()) {
          caCertPem = certService.certPem;
          caKeyPem = certService.keyPem;
        }
      }

      // Rust 代理始终为 WebView 提供 DOH/代理支持，enableDoh 不受 rhttp 影响
      final success = await _rustProxyService.start(
        preferredPort: current.proxyPort ?? 0,
        enableDoh: current.dohEnabled,
        gatewayMode: useGateway,
        preferIPv6: current.preferIPv6,
        dohServer: current.dohEnabled ? current.selectedServerUrl : null,
        dohServerEch: current.dohEnabled ? current.echServerUrl : null,
        serverIp: current.serverIp,
        upstreamProtocol: upstream.isValid ? upstream.protocol.storageValue : null,
        upstreamHost: upstream.isValid ? upstream.host : null,
        upstreamPort: upstream.isValid ? upstream.port : null,
        upstreamUsername: upstream.isValid ? upstream.username : null,
        upstreamPassword: upstream.isValid ? upstream.password : null,
        upstreamCipher: upstream.isValid ? upstream.cipher : null,
        caCertPem: caCertPem,
        caKeyPem: caKeyPem,
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
    _beginApply(enabled: shouldRunLocalProxy);
    await _applyProxyState();
    _touch();
  }

  void _scheduleApplyProxyState() {
    _beginApply(enabled: shouldRunLocalProxy);
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

  bool _webViewProxySet = false;

  Future<void> _applyWebViewProxy() async {
    if (!shouldRunLocalProxy) return;
    // macOS 14 以下 / iOS 17 以下调用 setProxyOverride 可能报错
    if (!Platform.isAndroid && !await _isMacOS14OrAbove() && !await _isiOS17OrAbove()) return;
    final port = _activeProxyPort;
    if (port == null) return;
    try {
      await inappwebview.ProxyController.instance().setProxyOverride(
        settings: inappwebview.ProxySettings(
          proxyRules: [
            inappwebview.ProxyRule(url: 'http://127.0.0.1:$port'),
          ],
        ),
      );
      _webViewProxySet = true;
      debugPrint('[DOH] WebView 代理已设置 -> 127.0.0.1:$port');
    } catch (e) {
      debugPrint('[DOH] WebView 代理设置失败: $e');
    }
  }

  Future<void> _clearWebViewProxy() async {
    if (!_webViewProxySet) return;
    if (!Platform.isAndroid && !await _isMacOS14OrAbove() && !await _isiOS17OrAbove()) return;
    try {
      await inappwebview.ProxyController.instance().clearProxyOverride();
      _webViewProxySet = false;
      debugPrint('[DOH] WebView 代理已清除');
    } catch (e) {
      debugPrint('[DOH] WebView 代理清除失败: $e');
    }
  }

  static bool? _isMacOS14OrAboveCache;

  Future<bool> _isMacOS14OrAbove() async {
    if (!Platform.isMacOS) return false;
    if (_isMacOS14OrAboveCache != null) return _isMacOS14OrAboveCache!;
    final info = await DeviceInfoPlugin().macOsInfo;
    // 修复：majorVersion 对应 macOS 大版本，如 macOS 14 (Sonoma) => majorVersion == 14 ≠ Darwin 23
    _isMacOS14OrAboveCache = info.majorVersion >= 14;
    return _isMacOS14OrAboveCache!;
  }

  static bool? _isiOS17OrAboveCache;

  Future<bool> _isiOS17OrAbove() async {
    if (!Platform.isIOS) return false;
    if (_isiOS17OrAboveCache != null) return _isiOS17OrAboveCache!;
    final info = await DeviceInfoPlugin().iosInfo;
    final major = int.tryParse(info.systemVersion.split('.').first) ?? 0;
    _isiOS17OrAboveCache = major >= 17;
    return _isiOS17OrAboveCache!;
  }

  void _touch() {
    _version++;
    // 通过重新赋值触发监听器更新
    notifier.value = notifier.value.copyWith();
  }

  void _handleProxySettingsChanged() {
    if (_prefs == null) return;
    _clearResolvedHostCache();
    _scheduleApplyProxyState();
    _touch();
  }

  Future<ResolvedHostConfig> resolveHostForRequest(
    String host, {
    bool forceRefresh = false,
  }) async {
    final normalizedHost = _normalizeHost(host);
    if (normalizedHost == null) {
      return const ResolvedHostConfig.empty();
    }

    final serverIpOverride = _parseServerIpOverride();
    if (!current.dohEnabled) {
      _clearResolvedHostCache();
      return ResolvedHostConfig(
        dnsOverrides: serverIpOverride != null ? <String>[serverIpOverride] : const [],
        preferredIp: serverIpOverride,
      );
    }

    final entry = await _resolveHostEntry(
      normalizedHost,
      forceRefresh: forceRefresh,
    );
    final orderedIps = _applyHostIpPenalties(
      normalizedHost,
      entry?.ips ?? const [],
      preferredIp: entry?.preferredIp,
    );
    final stickyIp = _selectUsablePreferredIp(
      normalizedHost,
      entry?.preferredIp,
      orderedIps,
    );
    return ResolvedHostConfig(
      dnsOverrides: serverIpOverride != null
          ? <String>[serverIpOverride]
          : stickyIp != null
              ? <String>[stickyIp]
              : orderedIps,
      preferredIp: serverIpOverride ?? stickyIp,
      echConfig: entry?.echConfig,
    );
  }

  void reportHostConnectionFailure(String host, String? ip) {
    final normalizedHost = _normalizeHost(host);
    final normalizedIp = _normalizeSingleIp(ip);
    if (normalizedHost == null || normalizedIp == null) {
      return;
    }

    _evictExpiredHostIpPenalties();
    final penalties = _hostIpPenaltyCache.putIfAbsent(
      normalizedHost,
      () => <String, DateTime>{},
    );
    penalties[normalizedIp] = DateTime.now().add(_failedHostIpPenaltyTtl);
    if (current.dohEnabled) {
      final dohServer = current.selectedServerUrl;
      final dohServerEch = _effectiveEchServerUrl ?? current.selectedServerUrl;
      unawaited(
        _rustProxyService.clearPreferredHostIp(
          normalizedHost,
          dohServer,
          dohServerEch: dohServerEch,
          preferIpv6: current.preferIPv6,
        ),
      );
    }
  }

  void reportHostConnectionSuccess(String host, String? ip) {
    final normalizedHost = _normalizeHost(host);
    final normalizedIp = _normalizeSingleIp(ip);
    if (normalizedHost == null || normalizedIp == null) {
      return;
    }

    final penalties = _hostIpPenaltyCache[normalizedHost];
    if (penalties == null) {
      return;
    }
    penalties.remove(normalizedIp);
    if (penalties.isEmpty) {
      _hostIpPenaltyCache.remove(normalizedHost);
    }

    if (current.dohEnabled) {
      final dohServer = current.selectedServerUrl;
      final dohServerEch = _effectiveEchServerUrl ?? current.selectedServerUrl;
      unawaited(
        _rustProxyService.recordHostSuccess(
          normalizedHost,
          dohServer,
          dohServerEch: dohServerEch,
          preferIpv6: current.preferIPv6,
          ip: normalizedIp,
        ),
      );
    }
  }

  Future<List<String>> getDnsOverridesForHost(String host) async {
    return (await resolveHostForRequest(host)).dnsOverrides;
  }

  Future<Uint8List?> getEchConfigForHost(String host) async {
    return (await resolveHostForRequest(host)).echConfig;
  }

  Future<void> clearDnsCache() async {
    _clearResolvedHostCache(touch: true);
    await _rustProxyService.clearDnsCache();
  }

  Future<int> forceRefreshDnsCache() async {
    final hosts = _collectCommonHosts();
    await clearDnsCache();
    if (!current.dohEnabled || hosts.isEmpty) {
      return 0;
    }

    await Future.wait(
      hosts.map((host) => _resolveHostEntry(host, forceRefresh: true)),
    );
    _touch();
    return hosts.length;
  }

  Future<_ResolvedHostEntry?> _resolveHostEntry(
    String host, {
    bool forceRefresh = false,
  }) {
    _ensureResolvedHostCacheSignature();

    if (!forceRefresh) {
      final cached = _resolvedHostCache[host];
      if (cached != null) {
        if (!cached.isExpired) {
          if (cached.shouldRefreshSoon) {
            _refreshHostInBackground(host);
          }
          return Future.value(cached);
        }
        _resolvedHostCache.remove(host);
      }
    } else {
      _resolvedHostCache.remove(host);
    }

    final inflight = _hostLookupInflight[host];
    if (inflight != null) {
      return inflight;
    }

    final future = _loadHostEntry(host, forceRefresh: forceRefresh);
    _hostLookupInflight[host] = future;
    return future.whenComplete(() {
      if (identical(_hostLookupInflight[host], future)) {
        _hostLookupInflight.remove(host);
      }
    });
  }

  Future<_ResolvedHostEntry?> _loadHostEntry(
    String host, {
    required bool forceRefresh,
  }) async {
    final dohServer = current.selectedServerUrl;
    final dohServerEch = _effectiveEchServerUrl ?? current.selectedServerUrl;
    final resolvedAt = DateTime.now();

    final rustResult = await _rustProxyService.lookupHost(
      host,
      dohServer,
      dohServerEch: dohServerEch,
      preferIpv6: current.preferIPv6,
      forceRefresh: forceRefresh,
    );
    if (rustResult != null && rustResult.hasData) {
      final entry = _ResolvedHostEntry(
        ips: _normalizeIpList(rustResult.ips),
        preferredIp: _normalizeSingleIp(rustResult.preferredIp),
        echConfig: rustResult.echConfig,
        ttl: _clampDnsTtl(rustResult.ttl),
        resolvedAt: resolvedAt,
      );
      _resolvedHostCache[host] = entry;
      debugPrint(
        '[DOH] Host 已解析 $host '
        '(DNS: ${entry.preferredIp ?? (entry.ips.isEmpty ? "none" : entry.ips.join(", "))}, '
        'ECH: ${entry.echConfig == null ? "off" : "on"}, '
        'TTL: ${entry.ttl.inSeconds}s)',
      );
      return entry;
    }

    final fallbackResults = await Future.wait<dynamic>([
      _lookupIpViaRust(
        host,
        dohServer,
        current.preferIPv6,
      ),
      _rustProxyService.lookupEchConfig(host, dohServerEch),
    ]);

    var ips = fallbackResults[0] as List<String>;
    final echConfig = fallbackResults[1] as Uint8List?;

    if (ips.isEmpty) {
      final fallback = await resolver.resolveAll(host);
      ips = _normalizeIpList(fallback.map((address) => address.address));
      if (ips.isNotEmpty) {
        debugPrint('[DOH] Dart IP 已解析 $host -> ${ips.join(', ')}');
      }
    }

    final hasData = ips.isNotEmpty || (echConfig?.isNotEmpty ?? false);
    // fallback 路径同样不要在真正连通前提前 pin 单 IP。
    // 让 rhttp 先拿完整候选集，避免把错误/不稳定边缘节点缓存成 sticky。
    final preferredIp = null;
    final entry = _ResolvedHostEntry(
      ips: ips,
      preferredIp: preferredIp,
      echConfig: echConfig != null && echConfig.isEmpty ? null : echConfig,
      ttl: hasData ? _defaultDnsCacheTtl : _missDnsCacheTtl,
      resolvedAt: resolvedAt,
    );
    _resolvedHostCache[host] = entry;

    if (!hasData) {
      debugPrint('[DOH] Host 解析失败或为空: $host');
    }
    return entry;
  }

  void _ensureResolvedHostCacheSignature() {
    final signature = _currentResolvedHostCacheSignature;
    if (_resolvedHostCacheSignature == signature) {
      return;
    }
    _clearResolvedHostCache();
    _resolvedHostCacheSignature = signature;
  }

  void _refreshHostInBackground(String host) {
    if (!_backgroundRefreshingHosts.add(host)) {
      return;
    }
    unawaited(
      _resolveHostEntry(host, forceRefresh: true).whenComplete(() {
        _backgroundRefreshingHosts.remove(host);
      }),
    );
  }

  void _clearResolvedHostCache({bool touch = false}) {
    final changed = _resolvedHostCache.isNotEmpty ||
        _hostLookupInflight.isNotEmpty ||
        _backgroundRefreshingHosts.isNotEmpty ||
        _hostIpPenaltyCache.isNotEmpty ||
        _resolvedHostCacheSignature != null;
    _resolvedHostCache.clear();
    _hostLookupInflight.clear();
    _backgroundRefreshingHosts.clear();
    _hostIpPenaltyCache.clear();
    _resolvedHostCacheSignature = null;
    if (touch && changed) {
      _touch();
    }
  }

  void _handleRhttpSettingsChanged() {
    if (_prefs == null) return;
    _scheduleApplyProxyState();
    _touch();
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

  String? _normalizeHost(String host) {
    final normalizedHost = host.trim().toLowerCase();
    if (normalizedHost.isEmpty || InternetAddress.tryParse(normalizedHost) != null) {
      return null;
    }
    return normalizedHost;
  }

  String? _parseServerIpOverride() {
    final serverIp = current.serverIp?.trim();
    if (serverIp == null || serverIp.isEmpty) {
      return null;
    }
    return InternetAddress.tryParse(serverIp)?.address;
  }

  Duration _clampDnsTtl(Duration ttl) {
    if (ttl <= Duration.zero) {
      return _defaultDnsCacheTtl;
    }
    if (ttl < _missDnsCacheTtl) {
      return _missDnsCacheTtl;
    }
    if (ttl > const Duration(minutes: 30)) {
      return const Duration(minutes: 30);
    }
    return ttl;
  }

  String? get _currentResolvedHostCacheSignature => current.dohEnabled
      ? '${current.selectedServerUrl}|${_effectiveEchServerUrl ?? ""}|${current.preferIPv6 ? "v6" : "v4"}'
      : null;

  List<String> _collectCommonHosts() {
    final preloaded = PreloadedDataService();
    final hosts = <String>{
      'connect.linux.do',
      'ping.linux.do',
      'cdn.linux.do',
      'credit.linux.do',
      'cdk.linux.do',
    };

    for (final value in [
      AppConstants.baseUrl,
      preloaded.longPollingBaseUrl,
      preloaded.cdnUrl,
      preloaded.s3CdnUrl,
      preloaded.s3BaseUrl,
    ]) {
      final host = _extractHost(value);
      if (host != null) {
        hosts.add(host);
      }
    }

    final result = hosts.toList()..sort();
    return result;
  }

  String? _extractHost(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final normalized = raw.startsWith('//') ? 'https:$raw' : raw;
    final host = Uri.tryParse(normalized)?.host.trim().toLowerCase();
    if (host == null || host.isEmpty) {
      return null;
    }
    return host;
  }

  Future<List<String>> _lookupIpViaRust(
    String host,
    String dohServer,
    bool preferIpv6,
  ) async {
    final result = await _rustProxyService.lookupIp(
      host,
      dohServer,
      preferIpv6: preferIpv6,
    );
    return _normalizeIpList(result);
  }

  List<String> _normalizeIpList(Iterable<String> raw) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final value in raw) {
      final ip = InternetAddress.tryParse(value.trim())?.address;
      if (ip == null || !seen.add(ip)) {
        continue;
      }
      normalized.add(ip);
    }
    return normalized;
  }

  String? _normalizeSingleIp(String? raw) {
    if (raw == null) {
      return null;
    }
    return InternetAddress.tryParse(raw.trim())?.address;
  }

  List<String> _applyHostIpPenalties(
    String host,
    List<String> ips, {
    String? preferredIp,
  }) {
    if (ips.isEmpty) {
      return const [];
    }

    _evictExpiredHostIpPenalties();
    final penalties = _hostIpPenaltyCache[host];
    if (penalties == null || penalties.isEmpty) {
      return ips;
    }

    final preferred = _normalizeSingleIp(preferredIp);
    final available = <String>[];
    final penalized = <String>[];

    for (final ip in ips) {
      if (_isHostIpPenalized(host, ip)) {
        penalized.add(ip);
      } else {
        available.add(ip);
      }
    }

    if (preferred != null &&
        available.remove(preferred)) {
      available.insert(0, preferred);
    }

    if (available.isNotEmpty) {
      return <String>[...available, ...penalized];
    }
    return penalized;
  }

  String? _selectUsablePreferredIp(
    String host,
    String? preferredIp,
    List<String> orderedIps,
  ) {
    final normalizedPreferred = _normalizeSingleIp(preferredIp);
    if (normalizedPreferred == null || orderedIps.isEmpty) {
      return null;
    }
    if (_isHostIpPenalized(host, normalizedPreferred)) {
      return null;
    }
    return orderedIps.first == normalizedPreferred ? normalizedPreferred : null;
  }

  bool _isHostIpPenalized(String host, String ip) {
    final penalties = _hostIpPenaltyCache[host];
    if (penalties == null) {
      return false;
    }
    final expiresAt = penalties[ip];
    if (expiresAt == null) {
      return false;
    }
    if (expiresAt.isAfter(DateTime.now())) {
      return true;
    }
    penalties.remove(ip);
    if (penalties.isEmpty) {
      _hostIpPenaltyCache.remove(host);
    }
    return false;
  }

  void _evictExpiredHostIpPenalties() {
    if (_hostIpPenaltyCache.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final emptyHosts = <String>[];
    for (final entry in _hostIpPenaltyCache.entries) {
      entry.value.removeWhere((_, expiresAt) => !expiresAt.isAfter(now));
      if (entry.value.isEmpty) {
        emptyHosts.add(entry.key);
      }
    }
    for (final host in emptyHosts) {
      _hostIpPenaltyCache.remove(host);
    }
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
    } catch (_) {}
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
