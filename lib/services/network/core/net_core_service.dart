import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../storage/secret_store.dart';
import '../../storage/system_secret_store.dart';

import 'package:flutter/foundation.dart';
import 'package:jni/jni.dart';

import '../../network_logger.dart';
import '../doh/ech_dns_policy.dart';
import '../proxy/proxy_settings_service.dart';
import 'net_core_bindings.dart';
import 'network_health_monitor.dart';

/// 网络核心的生命周期与配置。
///
/// 核心在所有模式下都运行：它既是 dio 的网络栈，也为 WebView 提供本地监听
/// （DoH / 代理模式下的 MITM）与指纹采样端点。配置变化时整体重启——
/// 配置项互相牵连（换 DoH 要换解析器、换代理要清连接池），整体重建比逐项同步可靠。
class NetCoreService {
  NetCoreService._();

  static final NetCoreService instance = NetCoreService._();

  final NetCoreBindings _bindings = NetCoreBindings.instance;

  /// 串行化 start/stop，避免并发配置变更互相覆盖。
  Future<void> _pending = Future<void>.value();

  NetCoreStatus _status = const NetCoreStatus.stopped();
  String? _lastError;
  String? _configSignature;
  NetCoreConfig? _lastConfig;

  /// 首次启动结束（无论成败）时完成。冷启动早期的请求在这里等一等，
  /// 而不是直接落到指纹最差的应急路径上去撞 CF。
  final Completer<void> _firstStart = Completer<void>();

  /// 核心当前状态。变化时通知，UI 与适配器据此切换。
  final ValueNotifier<NetCoreStatus> statusNotifier = ValueNotifier(
    const NetCoreStatus.stopped(),
  );

  NetCoreStatus get status => _status;

  bool get isRunning => _status.running;

  /// 核心是否可用；不可用时 dio 回退到 Dart IO 应急路径。
  bool get isAvailable => _bindings.isAvailable;

  String? get lastError => _lastError ?? _bindings.lastInitError;

  /// 本地监听端口（WebView 代理与采样探针用）。
  int? get port => _status.port;

  /// 按配置启动核心；显式重启不受相同配置去重影响。
  Future<bool> start(NetCoreConfig config, {bool forceRestart = false}) {
    final result = _serialize(() async {
      if (!_bindings.isAvailable) {
        _lastError = _bindings.lastInitError ?? '网络核心不可用';
        NetworkLogger.log('[NetCore] $_lastError，改走应急路径', level: 'error');
        _publish(const NetCoreStatus.stopped());
        return false;
      }
      _lastConfig = config;
      // 签名按探测后的配置算：安卓系统代理变了也要重启，否则 dio 与 WebView 出口不一致
      final resolved = await config.withDetectedSystemProxy();
      final signature = jsonEncode(resolved.toJson());
      if (!forceRestart && _status.running && signature == _configSignature) {
        return true;
      }
      final nativeConfig = resolved.toJson();
      final cachePath = resolved.fingerprintCachePath;
      if (cachePath != null) {
        try {
          const key = SecretKey(
            namespace: 'network',
            name: 'tls_ticket_encryption',
          );
          final store = SystemSecretStore.instance;
          var secret = await store.read(key);
          if (secret == null || base64Decode(secret).length != 32) {
            final random = Random.secure();
            secret = base64Encode(
              List<int>.generate(32, (_) => random.nextInt(256)),
            );
            await store.write(key, secret);
          }
          nativeConfig['tls_session_cache_path'] = '$cachePath.sessions';
          nativeConfig['tls_session_cache_key'] = secret;
        } catch (_) {
          // 系统安全存储不可用时保留内存票据，不降级成明文文件。
          NetworkLogger.log('[NetCore] TLS 票据使用内存缓存', level: 'info');
        }
      }
      final configJson = jsonEncode(nativeConfig);
      final restarting = _status.running;
      final started = DateTime.now();
      NetworkHealthMonitor.instance.reset(reason: 'core_start');
      final port = _bindings.start(configJson);
      if (port < 0) {
        // 具体原因由核心日志给出（同在网络日志里）
        _lastError = '网络核心启动失败';
        NetworkLogger.log(
          '[NetCore] $_lastError（${resolved.describe()}）',
          level: 'error',
        );
        _configSignature = null;
        _publish(const NetCoreStatus.stopped());
        return false;
      }
      _lastError = null;
      _configSignature = signature;
      _refreshStatus();
      NetworkLogger.log(
        '[NetCore] ${restarting ? (forceRestart ? '已手动重启' : '已按新配置重启') : '已启动'}，'
        '端口 $port，耗时 ${DateTime.now().difference(started).inMilliseconds}ms'
        '（${resolved.describe()}）',
      );
      return true;
    });
    result.whenComplete(() {
      if (!_firstStart.isCompleted) _firstStart.complete();
    });
    return result;
  }

  /// 等核心首次启动结束，最多等 [timeout]。已启动过则立即返回。
  Future<void> whenFirstStarted({
    Duration timeout = const Duration(seconds: 8),
  }) {
    if (_firstStart.isCompleted) return Future<void>.value();
    return _firstStart.future.timeout(timeout, onTimeout: () {});
  }

  /// 重新探测系统代理，有变化就按上次的配置重启。
  ///
  /// 从后台恢复时调用：安卓的系统代理只在 Java 属性里可见，变化不会通知到这里。
  Future<void> refreshSystemProxy() async {
    final config = _lastConfig;
    if (config == null) return;
    await start(config);
  }

  Future<void> stop() {
    return _serialize(() async {
      if (!_status.running) return;
      NetworkHealthMonitor.instance.reset(reason: 'core_stop');
      _bindings.shutdown();
      _configSignature = null;
      _publish(const NetCoreStatus.stopped());
      NetworkLogger.log('[NetCore] 已停止');
    });
  }

  /// 重新读取核心状态（模板是否就绪等）。探针采样后调用。
  void refreshStatus() => _refreshStatus();

  /// 丢弃所有池化连接。网络切换后调用：旧连接绑在旧网络的源地址上，
  /// 不主动丢弃会一直等到 NAT 超时才失败。
  void resetConnections({String reason = ''}) {
    if (!_status.running) return;
    NetworkHealthMonitor.instance.reset(reason: reason);
    _bindings.resetConnections();
    NetworkLogger.log('[NetCore] 已清空连接池${reason.isEmpty ? '' : '（$reason）'}');
  }

  /// 生成一份新的 CA（per-device 证书用）。
  ({String certPem, String keyPem})? generateCa() {
    if (!_bindings.isAvailable) return null;
    final json = _bindings.generateCa();
    if (json == null) return null;
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      NetworkLogger.log(
        '[NetCore] 生成 CA 失败: ${decoded['error']}',
        level: 'error',
      );
      return null;
    }
    return (
      certPem: decoded['cert'] as String,
      keyPem: decoded['key'] as String,
    );
  }

  /// 设置公共 ECH 入口策略。
  bool configureEchDnsPolicy(EchDnsPolicy policy) {
    if (!_bindings.isAvailable) return false;
    return _bindings.setEchDnsPolicy(jsonEncode(policy.toJson())) == 0;
  }

  Future<NetCoreDnsCache> dnsCache() async {
    if (!_bindings.isAvailable) return const NetCoreDnsCache.empty();
    final json = _bindings.dnsCacheJson();
    if (json == null) return const NetCoreDnsCache.empty();
    try {
      return NetCoreDnsCache.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (e) {
      NetworkLogger.log('[NetCore] 解析 DNS 缓存失败: $e', level: 'warning');
      return const NetCoreDnsCache.empty();
    }
  }

  void clearDnsCache() {
    if (_bindings.isAvailable) _bindings.clearDnsCache();
  }

  void _refreshStatus() {
    final json = _bindings.statusJson();
    if (json == null) {
      _publish(const NetCoreStatus.stopped());
      return;
    }
    try {
      _publish(
        NetCoreStatus.fromJson(jsonDecode(json) as Map<String, dynamic>),
      );
    } catch (e) {
      NetworkLogger.log('[NetCore] 解析状态失败: $e', level: 'warning');
    }
  }

  void _publish(NetCoreStatus status) {
    _status = status;
    statusNotifier.value = status;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// 核心配置。字段名与 Rust 侧 `NetConfig` 的 serde 名对应。
@immutable
class NetCoreConfig {
  const NetCoreConfig({
    this.bindPort = 0,
    this.enableDoh = false,
    this.dohServer,
    this.dohServerEch,
    this.echDnsPolicy,
    this.preferIpv6 = false,
    this.upstreamProxy,
    this.systemProxy,
    this.serverIp,
    this.webViewMitm = false,
    this.fingerprintCachePath,
    this.http3CachePath,
    this.fingerprintUserAgent,
    this.fingerprintPreset,
    this.caCertPem,
    this.caKeyPem,
  });

  final int bindPort;
  final bool enableDoh;
  final String? dohServer;
  final String? dohServerEch;
  final EchDnsPolicy? echDnsPolicy;
  final bool preferIpv6;

  /// 用户在设置页配置的应用内代理。
  final ProxySettings? upstreamProxy;

  /// 宿主读到的系统代理（安卓）。苹果与 Linux 由核心自行读取。
  final NetCoreProxy? systemProxy;
  final String? serverIp;

  /// WebView 是否经本地监听做 MITM（DoH / 代理模式）。
  final bool webViewMitm;
  final String? fingerprintCachePath;
  final String? http3CachePath;
  final String? fingerprintUserAgent;
  final String? fingerprintPreset;
  final String? caCertPem;
  final String? caKeyPem;

  /// 补齐宿主负责探测的系统代理。
  ///
  /// 安卓的系统代理（Wi-Fi 代理、全局代理、PAC 转出的本机代理）只在 Java
  /// 系统属性里可见，核心读不到，由这里读出后随配置下发。
  Future<NetCoreConfig> withDetectedSystemProxy() async {
    if (!Platform.isAndroid || systemProxy != null) return this;
    final detected = _androidSystemProxy();
    return detected == null ? this : copyWith(systemProxy: detected);
  }

  NetCoreConfig copyWith({NetCoreProxy? systemProxy}) => NetCoreConfig(
    bindPort: bindPort,
    enableDoh: enableDoh,
    dohServer: dohServer,
    dohServerEch: dohServerEch,
    echDnsPolicy: echDnsPolicy,
    preferIpv6: preferIpv6,
    upstreamProxy: upstreamProxy,
    systemProxy: systemProxy ?? this.systemProxy,
    serverIp: serverIp,
    webViewMitm: webViewMitm,
    fingerprintCachePath: fingerprintCachePath,
    http3CachePath: http3CachePath,
    fingerprintUserAgent: fingerprintUserAgent,
    fingerprintPreset: fingerprintPreset,
    caCertPem: caCertPem,
    caKeyPem: caKeyPem,
  );

  Map<String, dynamic> toJson() => {
    'bind_addr': '127.0.0.1',
    'bind_port': bindPort,
    'enable_doh': enableDoh,
    if (dohServer != null) 'doh_server': dohServer,
    if (dohServerEch != null) 'doh_server_ech': dohServerEch,
    if (echDnsPolicy != null) 'ech_dns_policy': echDnsPolicy!.toJson(),
    'prefer_ipv6': preferIpv6,
    'timeout_secs': 30,
    if (upstreamProxy != null && upstreamProxy!.isValid)
      'upstream_proxy': _proxyJson(upstreamProxy!),
    if (systemProxy != null) 'system_proxy': systemProxy!.toJson(),
    if (serverIp != null && serverIp!.isNotEmpty) 'server_ip': serverIp,
    'webview_mitm': webViewMitm,
    'fingerprint_platform': Platform.operatingSystem,
    if (fingerprintPreset != null) 'fingerprint_preset': fingerprintPreset,
    if (fingerprintUserAgent != null)
      'fingerprint_user_agent': fingerprintUserAgent,
    if (fingerprintCachePath != null)
      'fingerprint_cache_path': fingerprintCachePath,
    if (http3CachePath != null) 'http3_cache_path': http3CachePath,
    if (caCertPem != null) 'ca_cert_pem': caCertPem,
    if (caKeyPem != null) 'ca_key_pem': caKeyPem,
  };

  /// 日志用的配置摘要：不含账号密码与证书。
  String describe() {
    final parts = <String>[
      enableDoh ? 'DoH ${dohServer ?? '默认'}' : 'DoH 关',
      if (upstreamProxy != null && upstreamProxy!.isValid)
        '应用代理 ${upstreamProxy!.protocol.storageValue}://'
            '${upstreamProxy!.host}:${upstreamProxy!.port}',
      if (systemProxy != null) '系统代理 ${systemProxy!.host}:${systemProxy!.port}',
      if (serverIp != null && serverIp!.isNotEmpty) '指定 IP $serverIp',
      if (preferIpv6) '优先 IPv6',
      webViewMitm ? 'WebView 经核心' : 'WebView 直连',
      if (caCertPem != null) '设备证书',
    ];
    return parts.join('，');
  }

  static Map<String, dynamic> _proxyJson(ProxySettings proxy) => {
    'protocol': proxy.protocol.storageValue,
    'host': proxy.host,
    'port': proxy.port,
    if (proxy.username?.isNotEmpty ?? false) 'username': proxy.username,
    if (proxy.password?.isNotEmpty ?? false) 'password': proxy.password,
    if (proxy.cipher.isNotEmpty) 'cipher': proxy.cipher,
  };

  /// 读安卓的系统代理设置。系统会把 PAC 自动配置转成本机代理，一并覆盖。
  static NetCoreProxy? _androidSystemProxy() {
    try {
      final system = JClass.forName('java/lang/System');
      try {
        final getProperty = system.staticMethodId(
          'getProperty',
          '(Ljava/lang/String;)Ljava/lang/String;',
        );
        String? read(String key) {
          final name = key.toJString();
          final value = getProperty.callNullable(system, JString.type, [name]);
          name.release();
          return value?.toDartString(releaseOriginal: true);
        }

        final host = read('https.proxyHost') ?? read('http.proxyHost');
        if (host == null || host.isEmpty) return null;
        final port =
            int.tryParse(read('https.proxyPort') ?? '') ??
            int.tryParse(read('http.proxyPort') ?? '') ??
            0;
        if (port == 0) return null;
        return NetCoreProxy(host: host, port: port);
      } finally {
        system.release();
      }
    } catch (e) {
      NetworkLogger.log('[NetCore] 读取安卓系统代理失败: $e', level: 'warning');
      return null;
    }
  }
}

/// 下发给核心的代理端点。
@immutable
class NetCoreProxy {
  const NetCoreProxy({
    required this.host,
    required this.port,
    this.protocol = 'http',
  });

  final String host;
  final int port;
  final String protocol;

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'host': host,
    'port': port,
  };
}

/// 核心状态快照。
@immutable
class NetCoreStatus {
  const NetCoreStatus({
    required this.running,
    this.port,
    this.templateReady = false,
    this.templateSource,
    this.templatePreset,
    this.templateMode = 'auto',
    this.userAgent,
    this.webViewMitm = false,
    this.systemProxy = false,
    this.establishedConnections = 0,
    this.pooledHttp2 = 0,
    this.pooledHttp1Idle = 0,
  });

  const NetCoreStatus.stopped() : this(running: false);

  final bool running;
  final int? port;

  /// 指纹模板是否就绪：就绪后 dio 的请求才按 WebView 指纹出站。
  final bool templateReady;
  final String? templateSource;
  final String? templatePreset;
  final String templateMode;

  /// 采样时 WebView 的 UA；与当前 UA 不符说明 WebView 升级过，需要重采。
  final String? userAgent;
  final bool webViewMitm;
  final bool systemProxy;

  /// 自启动以来新建的连接数
  final int establishedConnections;

  /// 池中的 HTTP/2 共享连接与空闲 HTTP/1.1 连接
  final int pooledHttp2;
  final int pooledHttp1Idle;

  factory NetCoreStatus.fromJson(Map<String, dynamic> json) {
    final pooled = json['pooled_connections'] as Map<String, dynamic>?;
    return NetCoreStatus(
      running: json['running'] == true,
      port: json['port'] as int?,
      templateReady: json['template_ready'] == true,
      templateSource: json['template_source'] as String?,
      templatePreset: json['template_preset'] as String?,
      templateMode: json['template_mode'] as String? ?? 'auto',
      userAgent: json['user_agent'] as String?,
      webViewMitm: json['webview_mitm'] == true,
      systemProxy: json['system_proxy'] == true,
      establishedConnections: json['established_connections'] as int? ?? 0,
      pooledHttp2: pooled?['http2'] as int? ?? 0,
      pooledHttp1Idle: pooled?['http1_idle'] as int? ?? 0,
    );
  }
}

/// DNS 缓存概览与明细。
@immutable
class NetCoreDnsCache {
  const NetCoreDnsCache({required this.entryCount, required this.records});

  const NetCoreDnsCache.empty() : entryCount = 0, records = const [];

  final int entryCount;
  final List<NetCoreDnsRecord> records;

  factory NetCoreDnsCache.fromJson(Map<String, dynamic> json) {
    final stats = json['stats'] as Map<String, dynamic>? ?? const {};
    final count = ['host_count', 'ip_count', 'ech_count', 'preferred_ip_count']
        .map((key) => stats[key] as int? ?? 0)
        .fold(0, (sum, value) => sum + value);
    return NetCoreDnsCache(
      entryCount: count,
      records: (json['records'] as List<dynamic>? ?? const [])
          .map(
            (item) => NetCoreDnsRecord.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

@immutable
class NetCoreDnsRecord {
  const NetCoreDnsRecord({
    required this.host,
    required this.kind,
    required this.values,
    required this.ttl,
  });

  final String host;
  final String kind;
  final List<String> values;
  final Duration ttl;

  factory NetCoreDnsRecord.fromJson(Map<String, dynamic> json) =>
      NetCoreDnsRecord(
        host: json['host'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        values: (json['values'] as List<dynamic>? ?? const [])
            .map((value) => value.toString())
            .toList(),
        ttl: Duration(milliseconds: json['ttl_ms'] as int? ?? 0),
      );
}
