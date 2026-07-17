import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

class DohHostLookupResult {
  const DohHostLookupResult({
    required this.ips,
    required this.ttl,
    this.preferredIp,
    this.echConfig,
  });

  final List<String> ips;
  final String? preferredIp;
  final Uint8List? echConfig;
  final Duration ttl;

  bool get hasData => ips.isNotEmpty || (echConfig?.isNotEmpty ?? false);
}

class DohDnsCacheStats {
  const DohDnsCacheStats({
    required this.resolverCount,
    required this.hostCount,
    required this.ipCount,
    required this.echCount,
    required this.echNegativeCount,
    required this.ipRttCount,
    required this.preferredIpCount,
    required this.totalEntries,
    this.dartEntryCount = 0,
  });

  const DohDnsCacheStats.empty()
    : resolverCount = 0,
      hostCount = 0,
      ipCount = 0,
      echCount = 0,
      echNegativeCount = 0,
      ipRttCount = 0,
      preferredIpCount = 0,
      totalEntries = 0,
      dartEntryCount = 0;

  final int resolverCount;
  final int hostCount;
  final int ipCount;
  final int echCount;
  final int echNegativeCount;
  final int ipRttCount;
  final int preferredIpCount;
  final int totalEntries;
  final int dartEntryCount;

  int get rustVisibleHostEntries {
    final fallbackCount = ipCount + echCount + echNegativeCount;
    return hostCount > 0 ? hostCount : fallbackCount;
  }

  int get visibleHostEntries => rustVisibleHostEntries > dartEntryCount
      ? rustVisibleHostEntries
      : dartEntryCount;

  DohDnsCacheStats copyWith({
    int? resolverCount,
    int? hostCount,
    int? ipCount,
    int? echCount,
    int? echNegativeCount,
    int? ipRttCount,
    int? preferredIpCount,
    int? totalEntries,
    int? dartEntryCount,
  }) {
    return DohDnsCacheStats(
      resolverCount: resolverCount ?? this.resolverCount,
      hostCount: hostCount ?? this.hostCount,
      ipCount: ipCount ?? this.ipCount,
      echCount: echCount ?? this.echCount,
      echNegativeCount: echNegativeCount ?? this.echNegativeCount,
      ipRttCount: ipRttCount ?? this.ipRttCount,
      preferredIpCount: preferredIpCount ?? this.preferredIpCount,
      totalEntries: totalEntries ?? this.totalEntries,
      dartEntryCount: dartEntryCount ?? this.dartEntryCount,
    );
  }

  factory DohDnsCacheStats.fromJson(Map<String, dynamic> json) {
    return DohDnsCacheStats(
      resolverCount: (json['resolver_count'] as num?)?.toInt() ?? 0,
      hostCount: (json['host_count'] as num?)?.toInt() ?? 0,
      ipCount: (json['ip_count'] as num?)?.toInt() ?? 0,
      echCount: (json['ech_count'] as num?)?.toInt() ?? 0,
      echNegativeCount: (json['ech_negative_count'] as num?)?.toInt() ?? 0,
      ipRttCount: (json['ip_rtt_count'] as num?)?.toInt() ?? 0,
      preferredIpCount: (json['preferred_ip_count'] as num?)?.toInt() ?? 0,
      totalEntries: (json['total_entries'] as num?)?.toInt() ?? 0,
    );
  }
}

class DohDnsCacheRecord {
  const DohDnsCacheRecord({
    required this.host,
    required this.kind,
    required this.values,
    required this.ttl,
  });

  final String host;
  final String kind;
  final List<String> values;
  final Duration ttl;

  factory DohDnsCacheRecord.fromJson(Map<String, dynamic> json) {
    final values = json['values'];
    return DohDnsCacheRecord(
      host: json['host']?.toString() ?? '',
      kind: json['kind']?.toString() ?? '',
      values: values is List
          ? values
                .map((value) => value.toString())
                .where((value) => value.isNotEmpty)
                .toList()
          : const [],
      ttl: Duration(milliseconds: (json['ttl_ms'] as num?)?.toInt() ?? 0),
    );
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'kind': kind,
    'values': values,
    'ttl_ms': ttl.inMilliseconds,
  };
}

/// DOH Proxy FFI bindings
///
/// This provides direct FFI bindings to the Rust DOH proxy library
/// for Android and iOS platforms.
class DohProxyFfi {
  DohProxyFfi._();
  static final DohProxyFfi instance = DohProxyFfi._();

  DynamicLibrary? _lib;
  bool _initialized = false;

  // FFI function types（使用 late 而非 late final，允许重新初始化）
  late int Function(Pointer<Utf8> configJson) _dohProxyStartWithConfigJson;
  late void Function() _dohProxyStop;
  late int Function() _dohProxyIsRunning;
  late int Function() _dohProxyGetPort;
  late void Function() _dohProxyInitLogging;
  late Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)
  _dohProxyLookupEchConfig;
  late Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int)
  _dohProxyLookupIp;
  late Pointer<Utf8> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    int,
  )
  _dohProxyLookupHost;
  late int Function() _dohProxyClearDnsCache;
  late int Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
  )
  _dohProxyRecordHostSuccess;
  late int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int)
  _dohProxyClearPreferredHostIp;
  Pointer<Utf8> Function()? _dohProxyDnsCacheStats;
  Pointer<Utf8> Function()? _dohProxyDnsCacheRecords;
  Pointer<Utf8> Function()? _dohProxyGenerateCa;
  Pointer<Utf8> Function()? _dohProxyGetEmbeddedCaPem;
  late void Function(Pointer<Utf8>) _dohProxyFreeString;

  /// Initialize FFI bindings
  bool initialize() {
    if (_initialized) return true;

    try {
      _lib = _loadLibrary();
      if (_lib == null) return false;

      // Load function pointers
      _dohProxyStartWithConfigJson = _lib!
          .lookup<NativeFunction<Int32 Function(Pointer<Utf8>)>>(
            'doh_proxy_start_with_config_json',
          )
          .asFunction();

      _dohProxyStop = _lib!
          .lookup<NativeFunction<Void Function()>>('doh_proxy_stop')
          .asFunction();

      _dohProxyIsRunning = _lib!
          .lookup<NativeFunction<Int32 Function()>>('doh_proxy_is_running')
          .asFunction();

      _dohProxyGetPort = _lib!
          .lookup<NativeFunction<Int32 Function()>>('doh_proxy_get_port')
          .asFunction();

      _dohProxyInitLogging = _lib!
          .lookup<NativeFunction<Void Function()>>('doh_proxy_init_logging')
          .asFunction();

      _dohProxyLookupEchConfig = _lib!
          .lookup<
            NativeFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>
          >('doh_proxy_lookup_ech_config')
          .asFunction();

      _dohProxyLookupIp = _lib!
          .lookup<
            NativeFunction<
              Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Int32)
            >
          >('doh_proxy_lookup_ip')
          .asFunction();

      _dohProxyLookupHost = _lib!
          .lookup<
            NativeFunction<
              Pointer<Utf8> Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
                Int32,
                Int32,
              )
            >
          >('doh_proxy_lookup_host')
          .asFunction();

      _dohProxyClearDnsCache = _lib!
          .lookup<NativeFunction<Int32 Function()>>('doh_proxy_clear_dns_cache')
          .asFunction();

      _dohProxyRecordHostSuccess = _lib!
          .lookup<
            NativeFunction<
              Int32 Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
                Int32,
                Pointer<Utf8>,
              )
            >
          >('doh_proxy_record_host_success')
          .asFunction();

      _dohProxyClearPreferredHostIp = _lib!
          .lookup<
            NativeFunction<
              Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32)
            >
          >('doh_proxy_clear_preferred_host_ip')
          .asFunction();

      try {
        _dohProxyDnsCacheStats = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_dns_cache_stats',
            )
            .asFunction();
      } catch (_) {
        _dohProxyDnsCacheStats = null;
      }

      try {
        _dohProxyDnsCacheRecords = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_dns_cache_records',
            )
            .asFunction();
      } catch (_) {
        _dohProxyDnsCacheRecords = null;
      }

      // doh_proxy_generate_ca 是新增符号，旧版本库可能没有，可选绑定
      try {
        _dohProxyGenerateCa = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_generate_ca',
            )
            .asFunction();
      } catch (_) {
        _dohProxyGenerateCa = null;
        debugPrint('[DOH FFI] doh_proxy_generate_ca 未找到，per-device CA 不可用');
      }

      // doh_proxy_get_embedded_ca_pem 是新增符号，可选绑定
      try {
        _dohProxyGetEmbeddedCaPem = _lib!
            .lookup<NativeFunction<Pointer<Utf8> Function()>>(
              'doh_proxy_get_embedded_ca_pem',
            )
            .asFunction();
      } catch (_) {
        _dohProxyGetEmbeddedCaPem = null;
      }

      _dohProxyFreeString = _lib!
          .lookup<NativeFunction<Void Function(Pointer<Utf8>)>>(
            'doh_proxy_free_string',
          )
          .asFunction();

      _initialized = true;
      return true;
    } catch (e) {
      lastInitError = '初始化 FFI 绑定失败: $e';
      debugPrint('[DOH FFI] $lastInitError');
      return false;
    }
  }

  DynamicLibrary? _loadLibrary() {
    try {
      if (Platform.isAndroid) {
        return DynamicLibrary.open('libdoh_proxy.so');
      } else if (Platform.isIOS) {
        // iOS uses static linking, so we use the process itself
        return DynamicLibrary.process();
      } else if (Platform.isWindows) {
        return _loadWindowsLibrary();
      } else if (Platform.isMacOS) {
        return _loadMacOSLibrary();
      } else if (Platform.isLinux) {
        return DynamicLibrary.open('libdoh_proxy.so');
      }
    } catch (e) {
      lastInitError = '加载原生库失败: $e';
      debugPrint('[DOH FFI] $lastInitError');
    }
    return null;
  }

  DynamicLibrary? _loadWindowsLibrary() {
    const libName = 'doh_proxy.dll';
    final execPath = Platform.resolvedExecutable;
    final execDir = File(execPath).parent.path;
    final projectRoot = _projectRootFromBuildPath(execPath);
    final candidates = <String>[
      '$execDir/native/$libName',
      if (projectRoot != null) '$projectRoot/windows/runner/native/$libName',
      if (projectRoot != null)
        '$projectRoot/core/doh_proxy/target/release/$libName',
      if (projectRoot != null)
        '$projectRoot/core/doh_proxy/target/debug/$libName',
      '${Directory.current.path}/windows/runner/native/$libName',
      '${Directory.current.path}/core/doh_proxy/target/release/$libName',
      '${Directory.current.path}/core/doh_proxy/target/debug/$libName',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        debugPrint('[DOH FFI] 加载 Windows 库: $path');
        return DynamicLibrary.open(path);
      }
    }

    return DynamicLibrary.open(libName);
  }

  DynamicLibrary? _loadMacOSLibrary() {
    const libName = 'libdoh_proxy.dylib';
    final execPath = Platform.resolvedExecutable;
    final execDir = File(execPath).parent.path;
    final projectRoot = _projectRootFromBuildPath(execPath);
    final candidates = <String>[
      '$execDir/../Frameworks/$libName',
      '$execDir/../Resources/native/$libName',
      if (projectRoot != null) '$projectRoot/macos/Runner/native/$libName',
      if (projectRoot != null)
        '$projectRoot/core/doh_proxy/target/release/$libName',
      if (projectRoot != null)
        '$projectRoot/core/doh_proxy/target/debug/$libName',
      '${Directory.current.path}/macos/Runner/native/$libName',
      '${Directory.current.path}/core/doh_proxy/target/release/$libName',
      '${Directory.current.path}/core/doh_proxy/target/debug/$libName',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        debugPrint('[DOH FFI] 加载 macOS 库: $path');
        return DynamicLibrary.open(path);
      }
    }
    // 最后尝试系统搜索路径
    return DynamicLibrary.open(libName);
  }

  String? _projectRootFromBuildPath(String execPath) {
    final normalized = execPath.replaceAll('\\', '/');
    final buildIndex = normalized.indexOf('/build/');
    if (buildIndex <= 0) {
      return null;
    }
    return normalized.substring(0, buildIndex);
  }

  /// 最近一次初始化失败的原因
  String? lastInitError;

  /// Start the DOH proxy server
  /// Returns the port number on success, or -1 on failure
  ///
  /// [port] - Port to bind (0 for auto-select)
  /// [preferIpv6] - Whether to prefer IPv6 addresses
  /// [dohServer] - DOH server URL (null for default Cloudflare)
  int start({
    int port = 0,
    bool enableDoh = true,
    bool preferIpv6 = false,
    bool gatewayMode = false,
    String? dohServer,
    String? dohServerEch,
    String? serverIp,
    String? upstreamProtocol,
    String? upstreamHost,
    int? upstreamPort,
    String? upstreamUsername,
    String? upstreamPassword,
    String? upstreamCipher,
    String? caCertPem,
    String? caKeyPem,
    bool mitmConnect = true,
    bool h2Mitm = false,
  }) {
    if (!_initialized && !initialize()) {
      return -1;
    }

    final configJson = jsonEncode({
      'bind_addr': '127.0.0.1',
      'bind_port': port,
      'enable_doh': enableDoh,
      'gateway_mode': gatewayMode,
      'mitm_connect': mitmConnect,
      'h2_mitm': h2Mitm,
      'doh_server': dohServer ?? 'cloudflare',
      'prefer_ipv6': preferIpv6,
      'timeout_secs': 30,
      if (dohServerEch != null && dohServerEch.isNotEmpty)
        'doh_server_ech': dohServerEch,
      if (serverIp != null && serverIp.isNotEmpty) 'server_ip': serverIp,
      if (upstreamHost != null &&
          upstreamHost.isNotEmpty &&
          upstreamPort != null &&
          upstreamPort > 0)
        'upstream_proxy': {
          'protocol': upstreamProtocol ?? 'http',
          'host': upstreamHost,
          'port': upstreamPort,
          if (upstreamCipher != null && upstreamCipher.isNotEmpty)
            'cipher': upstreamCipher,
          if (upstreamUsername != null && upstreamUsername.isNotEmpty)
            'username': upstreamUsername,
          if (upstreamPassword != null && upstreamPassword.isNotEmpty)
            'password': upstreamPassword,
        },
      if (caCertPem != null && caCertPem.isNotEmpty) 'ca_cert_pem': caCertPem,
      if (caKeyPem != null && caKeyPem.isNotEmpty) 'ca_key_pem': caKeyPem,
    });
    final configPtr = configJson.toNativeUtf8();
    try {
      return _dohProxyStartWithConfigJson(configPtr);
    } finally {
      calloc.free(configPtr);
    }
  }

  /// 生成新的 CA 证书，返回 (certPem, keyPem)，失败返回 null
  ({String certPem, String keyPem})? generateCa() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyGenerateCa;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final jsonStr = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);

    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (map['ok'] == true &&
        map['cert_pem'] is String &&
        map['key_pem'] is String) {
      return (
        certPem: map['cert_pem'] as String,
        keyPem: map['key_pem'] as String,
      );
    }
    debugPrint('[DOH FFI] generateCa: ${map['error'] ?? 'unknown error'}');
    return null;
  }

  /// 获取编译时嵌入的 CA 证书 PEM
  ///
  /// 返回 Rust 库中通过 include_str! 嵌入的 CA PEM，保证和代理实际使用的 CA 一致
  String? getEmbeddedCaPem() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyGetEmbeddedCaPem;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final pem = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);
    return pem;
  }

  /// Lookup ECH config for a host via DOH DNS HTTPS record.
  /// Returns raw ECH config bytes, or null if not available.
  Uint8List? lookupEchConfig(String host, String dohServer) {
    if (!_initialized && !initialize()) return null;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    try {
      final resultPtr = _dohProxyLookupEchConfig(hostPtr, dohPtr);
      if (resultPtr == nullptr) return null;

      final jsonStr = resultPtr.toDartString();
      _dohProxyFreeString(resultPtr);

      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (map['ok'] == true && map['data'] is String) {
        return base64Decode(map['data'] as String);
      }
      debugPrint('[DOH FFI] ECH lookup: ${map['error'] ?? 'unknown error'}');
      return null;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
    }
  }

  /// Lookup IP addresses for a host via DOH A/AAAA records.
  /// Returns ordered IP strings, or null on failure.
  List<String>? lookupIp(
    String host,
    String dohServer, {
    bool preferIpv6 = false,
  }) {
    if (!_initialized && !initialize()) return null;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    try {
      final resultPtr = _dohProxyLookupIp(hostPtr, dohPtr, preferIpv6 ? 1 : 0);
      if (resultPtr == nullptr) return null;

      final jsonStr = resultPtr.toDartString();
      _dohProxyFreeString(resultPtr);

      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (map['ok'] == true && map['data'] is List) {
        return (map['data'] as List)
            .map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList();
      }
      debugPrint('[DOH FFI] IP lookup: ${map['error'] ?? 'unknown error'}');
      return null;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
    }
  }

  DohHostLookupResult? lookupHost(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
    bool forceRefresh = false,
  }) {
    if (!_initialized && !initialize()) return null;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    final hasEchPtr = dohServerEch != null && dohServerEch.isNotEmpty;
    final echPtr = hasEchPtr
        ? dohServerEch.toNativeUtf8()
        : nullptr.cast<Utf8>();
    try {
      final resultPtr = _dohProxyLookupHost(
        hostPtr,
        dohPtr,
        echPtr,
        preferIpv6 ? 1 : 0,
        forceRefresh ? 1 : 0,
      );
      if (resultPtr == nullptr) return null;

      final jsonStr = resultPtr.toDartString();
      _dohProxyFreeString(resultPtr);

      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (map['ok'] == true) {
        final ips = ((map['ips'] as List?) ?? const [])
            .map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList();
        final ttlSecs = (map['ttl_secs'] as num?)?.toInt() ?? 300;
        final echBase64 = map['ech']?.toString();
        return DohHostLookupResult(
          ips: ips,
          preferredIp: map['preferred_ip']?.toString(),
          echConfig: echBase64 != null && echBase64.isNotEmpty
              ? base64Decode(echBase64)
              : null,
          ttl: Duration(seconds: ttlSecs),
        );
      }
      debugPrint('[DOH FFI] Host lookup: ${map['error'] ?? 'unknown error'}');
      return null;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
      if (hasEchPtr) {
        calloc.free(echPtr);
      }
    }
  }

  bool clearDnsCache() {
    if (!_initialized && !initialize()) return false;
    return _dohProxyClearDnsCache() != 0;
  }

  DohDnsCacheStats? dnsCacheStats() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyDnsCacheStats;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final jsonStr = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);

    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (map['ok'] == true) {
      return DohDnsCacheStats.fromJson(map);
    }
    debugPrint('[DOH FFI] DNS cache stats: ${map['error'] ?? 'unknown error'}');
    return null;
  }

  List<DohDnsCacheRecord>? dnsCacheRecords() {
    if (!_initialized && !initialize()) return null;
    final fn = _dohProxyDnsCacheRecords;
    if (fn == null) return null;

    final resultPtr = fn();
    if (resultPtr == nullptr) return null;

    final jsonStr = resultPtr.toDartString();
    _dohProxyFreeString(resultPtr);

    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    if (map['ok'] == true && map['records'] is List) {
      return (map['records'] as List)
          .whereType<Map>()
          .map(
            (record) =>
                DohDnsCacheRecord.fromJson(record.cast<String, dynamic>()),
          )
          .where((record) => record.host.isNotEmpty && record.kind.isNotEmpty)
          .toList();
    }
    debugPrint(
      '[DOH FFI] DNS cache records: ${map['error'] ?? 'unknown error'}',
    );
    return null;
  }

  bool recordHostSuccess(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
    required String ip,
  }) {
    if (!_initialized && !initialize()) return false;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    final hasEchPtr = dohServerEch != null && dohServerEch.isNotEmpty;
    final echPtr = hasEchPtr
        ? dohServerEch.toNativeUtf8()
        : nullptr.cast<Utf8>();
    final ipPtr = ip.toNativeUtf8();
    try {
      return _dohProxyRecordHostSuccess(
            hostPtr,
            dohPtr,
            echPtr,
            preferIpv6 ? 1 : 0,
            ipPtr,
          ) !=
          0;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
      calloc.free(ipPtr);
      if (hasEchPtr) {
        calloc.free(echPtr);
      }
    }
  }

  bool clearPreferredHostIp(
    String host,
    String dohServer, {
    String? dohServerEch,
    bool preferIpv6 = false,
  }) {
    if (!_initialized && !initialize()) return false;

    final hostPtr = host.toNativeUtf8();
    final dohPtr = dohServer.toNativeUtf8();
    final hasEchPtr = dohServerEch != null && dohServerEch.isNotEmpty;
    final echPtr = hasEchPtr
        ? dohServerEch.toNativeUtf8()
        : nullptr.cast<Utf8>();
    try {
      return _dohProxyClearPreferredHostIp(
            hostPtr,
            dohPtr,
            echPtr,
            preferIpv6 ? 1 : 0,
          ) !=
          0;
    } finally {
      calloc.free(hostPtr);
      calloc.free(dohPtr);
      if (hasEchPtr) {
        calloc.free(echPtr);
      }
    }
  }

  /// Stop the DOH proxy server
  void stop() {
    if (!_initialized) return;
    _dohProxyStop();
  }

  /// Check if the DOH proxy is running
  bool isRunning() {
    if (!_initialized) return false;
    return _dohProxyIsRunning() != 0;
  }

  /// Get the DOH proxy port
  int getPort() {
    if (!_initialized) return 0;
    return _dohProxyGetPort();
  }

  /// Initialize logging
  void initLogging() {
    if (!_initialized && !initialize()) return;
    _dohProxyInitLogging();
  }

  /// Check if FFI is available on this platform
  static bool get isAvailable {
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows;
  }

  /// 桌面平台 FFI 失败时可以回退到进程模式
  static bool get canFallbackToProcess {
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }
}

/// Backwards compatibility alias
@Deprecated('Use DohProxyFfi instead')
typedef EchProxyFfi = DohProxyFfi;
