import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inappwebview;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../constants.dart';
import '../../network_logger.dart';
import '../core/net_core_service.dart';
import '../doh_proxy/cert_preference_service.dart';
import '../doh_proxy/per_device_cert_service.dart';
import '../doh_proxy/proxy_certificate.dart';
import '../doh_proxy/windows_cert_trust_service.dart';
import '../fingerprint/fingerprint_template_service.dart';
import '../proxy/proxy_settings_service.dart';
import '../system_proxy_service.dart';
import '../../windows_webview_environment_service.dart';
import 'doh_resolver.dart';
import 'ech_dns_policy.dart';

class NetworkSettings {
  const NetworkSettings({
    required this.dohEnabled,
    required this.selectedServerUrl,
    this.echServerUrl,
    required this.customServers,
    required this.proxyPort,
    this.preferIPv6 = false,
    this.serverIp,
    this.echDnsPolicy = const EchDnsPolicy(),
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

  final EchDnsPolicy echDnsPolicy;

  NetworkSettings copyWith({
    bool? dohEnabled,
    String? selectedServerUrl,
    String? Function()? echServerUrl,
    List<DohServer>? customServers,
    int? proxyPort,
    bool? preferIPv6,
    String? Function()? serverIp,
    EchDnsPolicy? echDnsPolicy,
  }) {
    return NetworkSettings(
      dohEnabled: dohEnabled ?? this.dohEnabled,
      selectedServerUrl: selectedServerUrl ?? this.selectedServerUrl,
      echServerUrl: echServerUrl != null ? echServerUrl() : this.echServerUrl,
      customServers: customServers ?? this.customServers,
      proxyPort: proxyPort ?? this.proxyPort,
      preferIPv6: preferIPv6 ?? this.preferIPv6,
      serverIp: serverIp != null ? serverIp() : this.serverIp,
      echDnsPolicy: echDnsPolicy ?? this.echDnsPolicy,
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
  NetworkSettingsService._internal() {
    _proxyService.notifier.addListener(_handleProxySettingsChanged);
    SystemProxyService.instance.version.addListener(_handleSystemProxyChanged);
    FingerprintTemplateService.instance.templateReady.addListener(() {
      _coreService.refreshStatus();
      _touch();
    });
  }

  static final NetworkSettingsService instance =
      NetworkSettingsService._internal();

  static const _dohEnabledKey = 'doh_enabled';
  static const _dohSelectedKey = 'doh_selected';
  static const _dohCustomKey = 'doh_custom';
  static const _proxyPortKey = 'doh_proxy_port';
  static const _preferIPv6Key = 'doh_prefer_ipv6';
  static const _serverIpKey = 'doh_server_ip';
  static const _echServerKey = 'doh_ech_server';
  static const _echDnsPolicyKey = 'doh_ech_dns_policy';

  final ValueNotifier<NetworkSettings> notifier = ValueNotifier(
    NetworkSettings(
      dohEnabled: false,
      selectedServerUrl: _defaultServers.first.url,
      customServers: const [],
      proxyPort: null,
    ),
  );

  /// 网络核心：dio 的网络栈，同时为 WebView 提供本地监听与指纹采样
  final NetCoreService _coreService = NetCoreService.instance;
  final ProxySettingsService _proxyService = ProxySettingsService.instance;

  /// DNS 缓存条目数（设置页展示）
  final ValueNotifier<int> dnsCacheStatsNotifier = ValueNotifier(0);

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
  int get dnsCacheEntryCount => dnsCacheStatsNotifier.value;

  /// 网络核心服务（设置页展示状态用）
  NetCoreService get coreService => _coreService;

  NetworkSettings get current => notifier.value;

  /// WebView 是否经核心做 MITM（DoH 或应用内代理开启时）。
  ///
  /// 只在这种模式下 WebView 才会遇到核心签发的证书，
  /// 证书放行判断依赖它；dio 始终经核心，与此无关。
  bool get webViewUsesCoreMitm =>
      _coreService.isRunning && _coreService.status.webViewMitm;

  /// 配置上是否需要让 WebView 走核心：开了 DoH（要加密 DNS 与 ECH），
  /// 或配了应用内代理（WebView 自己不会走我们的代理）。
  bool get _needsWebViewMitm =>
      current.dohEnabled || _proxyService.current.isValid;

  List<DohServer> get servers => [
    ..._defaultServers,
    ...notifier.value.customServers,
  ];

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    final dohEnabled = prefs.getBool(_dohEnabledKey) ?? false;
    final selected =
        prefs.getString(_dohSelectedKey) ?? _defaultServers.first.url;
    final customRaw = prefs.getString(_dohCustomKey);
    final custom = _decodeServers(customRaw);
    final proxyPort = prefs.getInt(_proxyPortKey);
    await prefs.remove('doh_multi_ip');
    final preferIPv6 = prefs.getBool(_preferIPv6Key) ?? false;
    final serverIp = prefs.getString(_serverIpKey);
    final echServer = prefs.getString(_echServerKey);
    var echDnsPolicy = const EchDnsPolicy();
    try {
      final raw = prefs.getString(_echDnsPolicyKey);
      if (raw != null) {
        echDnsPolicy = EchDnsPolicy.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        );
      }
    } catch (_) {
      // 旧配置损坏时恢复默认规则。
    }
    final resolvedSelected = _resolveSelected(selected, custom);
    notifier.value = NetworkSettings(
      dohEnabled: dohEnabled,
      selectedServerUrl: resolvedSelected,
      echServerUrl: echServer,
      customServers: custom,
      proxyPort: proxyPort,
      preferIPv6: preferIPv6,
      serverIp: serverIp,
      echDnsPolicy: echDnsPolicy,
    );
    _resolver = DohResolver(
      serverUrl: notifier.value.selectedServerUrl,
      bootstrapIps: _getBootstrapIps(notifier.value.selectedServerUrl),
      preferIPv6: preferIPv6,
      echDnsPolicy: echDnsPolicy,
    );
    _coreService.configureEchDnsPolicy(echDnsPolicy);
    await _applyProxyState();
    await refreshDnsCacheStats();
    _touch();
  }

  Future<void> setDohEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    _beginApply();
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
    if (current.dohEnabled) {}
    await prefs.setString(_dohSelectedKey, url);
    _scheduleApplyProxyState();
    _touch(); // 在代理状态更新完成后触发
  }

  Future<void> addCustomServer(DohServer server) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = [...notifier.value.customServers, server];
    notifier.value = notifier.value.copyWith(customServers: updated);
    await prefs.setString(
      _dohCustomKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    _touch();
  }

  Future<void> updateCustomServer(
    DohServer oldServer,
    DohServer newServer,
  ) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = notifier.value.customServers
        .map((s) => s.url == oldServer.url ? newServer : s)
        .toList();
    final selectedUrl = notifier.value.selectedServerUrl;
    final newSelected = selectedUrl == oldServer.url
        ? newServer.url
        : selectedUrl;
    notifier.value = notifier.value.copyWith(
      customServers: updated,
      selectedServerUrl: newSelected,
    );
    if (newSelected != selectedUrl) {
      _resolver.updateServer(
        newSelected,
        bootstrapIps: _getBootstrapIps(newSelected),
      );
      _scheduleApplyProxyState();
    }
    await prefs.setString(
      _dohCustomKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    if (newSelected != selectedUrl) {
      await prefs.setString(_dohSelectedKey, newSelected);
    }
    _touch();
  }

  Future<void> removeCustomServer(DohServer server) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final updated = notifier.value.customServers
        .where((s) => s.url != server.url)
        .toList();
    final resolvedSelected = _resolveSelected(
      notifier.value.selectedServerUrl,
      updated,
    );
    notifier.value = notifier.value.copyWith(
      customServers: updated,
      selectedServerUrl: resolvedSelected,
    );
    _resolver.updateServer(
      resolvedSelected,
      bootstrapIps: _getBootstrapIps(resolvedSelected),
    );
    await prefs.setString(
      _dohCustomKey,
      jsonEncode(updated.map((e) => e.toJson()).toList()),
    );
    _touch();
  }

  Future<void> resetDefaultServers() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final resolvedSelected = _resolveSelected(
      notifier.value.selectedServerUrl,
      const [],
    );
    notifier.value = notifier.value.copyWith(
      customServers: const [],
      selectedServerUrl: resolvedSelected,
    );
    _resolver.updateServer(
      resolvedSelected,
      bootstrapIps: _getBootstrapIps(resolvedSelected),
    );
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

  Future<void> setServerIp(String? ip) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final trimmed = ip?.trim();
    final value = (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
    notifier.value = notifier.value.copyWith(serverIp: () => value);
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
    if (url != null) {
      await prefs.setString(_echServerKey, url);
    } else {
      await prefs.remove(_echServerKey);
    }
    _scheduleApplyProxyState();
    _touch();
  }

  Future<void> setEchDnsPolicy(EchDnsPolicy policy) async {
    final prefs = _prefs;
    if (prefs == null) return;
    // 持久化、Rust 查询和 Dart 后备解析共用同一份规范化配置。
    final normalized = EchDnsPolicy.fromJson(policy.toJson());
    notifier.value = current.copyWith(echDnsPolicy: normalized);
    _resolver.echDnsPolicy = normalized;
    _coreService.configureEchDnsPolicy(normalized);
    await prefs.setString(_echDnsPolicyKey, jsonEncode(normalized.toJson()));
    _scheduleApplyProxyState();
    _touch();
  }

  /// 按当前设置启动（或重启）网络核心。
  ///
  /// 核心在所有模式下都运行：它是 dio 的网络栈，同时为 WebView 提供
  /// 本地监听与指纹采样。DoH / 应用内代理开启时，WebView 额外经核心做 MITM。
  Future<void> _applyProxyState() async {
    final startedAt = DateTime.now();
    _applyDepth++;
    if (_applyDepth == 1) {
      if (!isApplying.value) {
        _wasRunningBeforeApply = _coreService.isRunning;
        isApplying.value = true;
      }
      // 给 UI 一帧时间渲染 Loading
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    try {
      var webViewMitm = _needsWebViewMitm;
      if (webViewMitm && !await _webViewMitmCaReady()) {
        // CA 没装好就做 MITM 只会换来证书失败重试风暴：WebView 不拦，
        // 核心照常启动——它是 dio 的网络栈，不能跟着 WebView 的条件一起停
        webViewMitm = false;
      }

      // per-device CA：iOS/macOS 用设备各自的 CA，其他平台可选
      String? caCertPem;
      String? caKeyPem;
      if (webViewMitm && await CertPreferenceService.usePerDevice()) {
        final certService = PerDeviceCertService.instance;
        if (certService.isLoaded || await certService.ensureCaCert()) {
          caCertPem = certService.certPem;
          caKeyPem = certService.keyPem;
        }
      }

      final started = await _coreService.start(
        NetCoreConfig(
          bindPort:
              WindowsWebViewEnvironmentService.instance.activeLocalProxyPort ??
              _coreService.port ??
              current.proxyPort ??
              0,
          enableDoh: current.dohEnabled,
          dohServer: current.dohEnabled ? current.selectedServerUrl : null,
          dohServerEch: current.dohEnabled ? current.echServerUrl : null,
          echDnsPolicy: current.echDnsPolicy,
          preferIpv6: current.preferIPv6,
          upstreamProxy: _proxyService.current,
          // Windows 的系统代理由宿主读注册表；苹果与 Linux 由核心自行读取
          systemProxy: Platform.isWindows ? _windowsSystemProxy() : null,
          serverIp: current.serverIp,
          webViewMitm: webViewMitm,
          fingerprintCachePath: await _fingerprintCachePath(),
          fingerprintUserAgent: await AppConstants.getUserAgent(),
          caCertPem: caCertPem,
          caKeyPem: caKeyPem,
        ),
      );

      if (!started) {
        _setStartFailed(true);
        _setPendingStart(false);
        await _clearWebViewProxy();
        return;
      }
      _setStartFailed(false);
      _setPendingStart(false);

      final port = _coreService.port;
      if (port != null && current.proxyPort != port) {
        await _prefs?.setInt(_proxyPortKey, port);
        notifier.value = notifier.value.copyWith(proxyPort: port);
        _touch();
      }

      // WebView：需要 MITM 时指向核心，否则清掉代理让它直连
      if (webViewMitm) {
        await _applyWebViewProxy();
      } else {
        await _clearWebViewProxy();
      }
      // 直连模式下 WebView 不经过核心，指纹只能靠探针采样
      if (port != null) {
        unawaited(FingerprintTemplateService.instance.ensure(port));
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
        await refreshDnsCacheStats();
        _touch();
      }
    }
  }

  /// WebView MITM 的前置条件：Windows 要装好受信任 CA，macOS 要钥匙串信任。
  Future<bool> _webViewMitmCaReady() async {
    if (Platform.isWindows &&
        !await WindowsCertTrustService.instance.isInstalled()) {
      NetworkLogger.log(
        '[NetCore] Windows 缺少受信任 CA，WebView 不走 MITM',
        level: 'warning',
      );
      return false;
    }
    if (Platform.isMacOS && !await ProxyCertificate.ensureKeychainTrust()) {
      NetworkLogger.log(
        '[NetCore] macOS CA 未被钥匙串信任，WebView 不走 MITM',
        level: 'warning',
      );
      return false;
    }
    return true;
  }

  /// Windows 的系统代理：注册表里读到的地址直接作为核心的上游。
  NetCoreProxy? _windowsSystemProxy() {
    final url = SystemProxyService.instance.effectiveProxyUrl;
    if (url == null) return null;
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.host.isEmpty || parsed.port == 0) return null;
    return NetCoreProxy(
      host: parsed.host,
      port: parsed.port,
      protocol: parsed.scheme.startsWith('socks') ? 'socks5' : 'http',
    );
  }

  /// 指纹模板缓存文件：冷启动即可按模板出站，不必等 WebView 再经过一次。
  Future<String?> _fingerprintCachePath() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final core = Directory('${dir.path}/net_core');
      if (!core.existsSync()) {
        await core.create(recursive: true);
      }
      return '${core.path}/fingerprint_template.json';
    } catch (e) {
      NetworkLogger.log('[NetCore] 指纹缓存目录不可用: $e', level: 'warning');
      return null;
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
    _beginApply();
    await _applyProxyState();
    _touch();
  }

  /// 检查核心是否仍然存活，若已意外停止则自动重启。
  ///
  /// 用于 App 从后台恢复时调用：iOS 挂起进程后 TCP listener 可能失效。
  /// 同时清空连接池——挂起期间网络可能已切换，旧连接绑在旧源地址上。
  Future<void> ensureProxyAlive() async {
    if (!_coreService.isRunning) {
      await restartProxy();
      return;
    }
    _coreService.resetConnections(reason: '从后台恢复');
    // 挂起期间系统代理可能变了（安卓的变化不会通知过来），有变化会触发重启
    await _coreService.refreshSystemProxy();
  }

  void _scheduleApplyProxyState() {
    _beginApply();
    _applyDebounce?.cancel();
    _applyDebounce = Timer(const Duration(milliseconds: 350), () async {
      await _applyProxyState();
      _touch();
    });
  }

  void _beginApply() {
    _wasRunningBeforeApply = _coreService.isRunning;
    _setPendingStart(true);
    if (!isApplying.value) {
      isApplying.value = true;
    }
  }

  bool _webViewProxySet = false;

  Future<void> _applyWebViewProxy() async {
    final port = _coreService.port;
    if (port == null) return;

    if (Platform.isWindows) {
      try {
        final applied = await WindowsWebViewEnvironmentService.instance
            .setProxy('http://127.0.0.1:$port');
        _webViewProxySet = true;
        NetworkLogger.log(
          applied
              ? '[WebView] WebView2 代理已设置 -> 127.0.0.1:$port'
              : '[WebView] WebView2 代理已登记，重启应用后生效 -> '
                    '127.0.0.1:$port',
        );
      } catch (e) {
        NetworkLogger.log('[WebView] WebView2 代理设置失败: $e', level: 'error');
      }
      return;
    }

    // macOS 14 以下 / iOS 17 以下调用 setProxyOverride 可能报错
    if (!Platform.isAndroid &&
        !await _isMacOS14OrAbove() &&
        !await _isiOS17OrAbove()) {
      NetworkLogger.log(
        '[WebView] 系统版本不支持代理设置（需 macOS 14 / iOS 17），WebView 不经核心',
        level: 'warning',
      );
      return;
    }

    try {
      await inappwebview.ProxyController.instance().setProxyOverride(
        settings: inappwebview.ProxySettings(
          proxyRules: [inappwebview.ProxyRule(url: 'http://127.0.0.1:$port')],
        ),
      );
      _webViewProxySet = true;
      NetworkLogger.log('[WebView] 代理已设置 -> 127.0.0.1:$port');
    } catch (e) {
      NetworkLogger.log('[WebView] 代理设置失败: $e', level: 'error');
    }
  }

  Future<bool> _clearWebViewProxy() async {
    if (Platform.isWindows) {
      try {
        final applied = await WindowsWebViewEnvironmentService.instance
            .setProxy(null);
        _webViewProxySet = false;
        NetworkLogger.log(
          applied
              ? '[WebView] WebView2 代理已清除'
              : '[WebView] WebView2 代理清除已登记，重启应用后生效',
        );
        return applied;
      } catch (e) {
        NetworkLogger.log('[WebView] WebView2 代理清除失败: $e', level: 'error');
        return false;
      }
    }

    if (!_webViewProxySet) return true;

    if (!Platform.isAndroid &&
        !await _isMacOS14OrAbove() &&
        !await _isiOS17OrAbove()) {
      return true;
    }
    try {
      await inappwebview.ProxyController.instance().clearProxyOverride();
      _webViewProxySet = false;
      NetworkLogger.log('[WebView] 代理已清除');
      return true;
    } catch (e) {
      NetworkLogger.log('[WebView] 代理清除失败: $e', level: 'error');
      return false;
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
    _scheduleApplyProxyState();
    _touch();
  }

  void _handleSystemProxyChanged() {
    if (_prefs == null || !Platform.isWindows) return;
    // Windows 的系统代理随配置下发给核心；应用内代理优先级更高，配了就不受影响
    if (_proxyService.current.isValid) return;
    _scheduleApplyProxyState();
  }

  /// 刷新 DNS 缓存条目数（设置页展示）。
  Future<void> refreshDnsCacheStats() async {
    final cache = await _coreService.dnsCache();
    dnsCacheStatsNotifier.value = cache.entryCount;
  }

  /// DNS 缓存明细，按域名、类型排序。
  Future<List<NetCoreDnsRecord>> dnsCacheRecords() async {
    final records = [...(await _coreService.dnsCache()).records];
    records.sort((a, b) {
      final hostOrder = a.host.compareTo(b.host);
      if (hostOrder != 0) return hostOrder;
      return _dnsCacheRecordKindOrder(a.kind)
          .compareTo(_dnsCacheRecordKindOrder(b.kind));
    });
    return records;
  }

  Future<void> clearDnsCache() async {
    _coreService.clearDnsCache();
    await refreshDnsCacheStats();
  }

  /// 清空缓存并丢弃连接池，下次请求重新解析。返回预热的域名数（核心按需解析，不预热）。
  Future<int> forceRefreshDnsCache() async {
    _coreService.clearDnsCache();
    _coreService.resetConnections(reason: '手动刷新 DNS 缓存');
    await refreshDnsCacheStats();
    return 0;
  }

  int _dnsCacheRecordKindOrder(String kind) {
    switch (kind) {
      case 'preferred_ip':
        return 0;
      case 'ip':
        return 1;
      case 'ech':
        return 2;
      case 'ech_negative':
        return 3;
      default:
        return 4;
    }
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
    bootstrapIps: [
      '1.1.1.1',
      '1.0.0.1',
      '2606:4700:4700::1111',
      '2606:4700:4700::1001',
    ],
  ),
  DohServer(
    name: 'Canadian Shield',
    url: 'https://private.canadianshield.cira.ca/dns-query',
  ),
  DohServer(
    name: '阿里 DNS',
    url: 'https://dns.alidns.com/dns-query',
    bootstrapIps: [
      '223.5.5.5',
      '223.6.6.6',
      '2400:3200::1',
      '2400:3200:baba::1',
    ],
  ),
  DohServer(
    name: 'Quad9',
    url: 'https://dns.quad9.net/dns-query',
    bootstrapIps: ['9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9'],
  ),
  DohServer(
    name: 'Google',
    url: 'https://dns.google/dns-query',
    bootstrapIps: [
      '8.8.8.8',
      '8.8.4.4',
      '2001:4860:4860::8888',
      '2001:4860:4860::8844',
    ],
  ),
];
