import 'dart:async';
import 'dart:io';

import '../../network_logger.dart';
import 'bootstrap_doh_client.dart';

class DohResolver {
  DohResolver({
    required String serverUrl,
    List<String> bootstrapIps = const [],
    this.enableFallback = true,
    bool preferIPv6 = false,
  })  : _serverUrl = serverUrl,
        _bootstrapIps = bootstrapIps,
        _preferIPv6 = preferIPv6 {
    _initClient();
  }

  String _serverUrl;
  List<String> _bootstrapIps;
  late BootstrapDohClient _client;

  /// 是否启用系统 DNS 回退
  final bool enableFallback;

  /// 是否优先使用 IPv6（用于绕过 SNI 阻断）
  bool _preferIPv6;

  /// TTL 感知缓存
  final Map<String, _DohCacheEntryAll> _cacheAll = {};

  /// Inflight 去重：同域名并发查询共享同一个 Future
  final Map<String, Future<List<InternetAddress>>> _inflight = {};

  /// 缓存上限
  static const _maxCacheSize = 500;

  /// 缓存清理计数器
  int _queryCount = 0;
  static const _cleanupInterval = 50;

  void _initClient() {
    _client = BootstrapDohClient(
      serverUrl: _serverUrl,
      bootstrapIps: _bootstrapIps,
      timeout: const Duration(seconds: 5),
      preferIPv6: _preferIPv6,
    );
  }

  void updateServer(String serverUrl,
      {List<String> bootstrapIps = const []}) {
    if (_serverUrl == serverUrl && _listEquals(_bootstrapIps, bootstrapIps)) {
      return;
    }
    _serverUrl = serverUrl;
    _bootstrapIps = bootstrapIps;
    _cacheAll.clear();
    _inflight.clear();
    _client.close();
    _initClient();
  }

  /// 设置是否优先使用 IPv6
  set preferIPv6(bool value) {
    if (_preferIPv6 != value) {
      _preferIPv6 = value;
      _client.preferIPv6 = value;
      _cacheAll.clear();
    }
  }

  bool get preferIPv6 => _preferIPv6;

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 解析单个地址（兼容旧 API）
  Future<InternetAddress?> resolve(String host) async {
    final addresses = await resolveAll(host);
    return addresses.isNotEmpty ? addresses.first : null;
  }

  /// 解析所有地址
  Future<List<InternetAddress>> resolveAll(String host) async {
    if (host.isEmpty) return [];

    // 检查是否是 IP 地址
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) return [parsed];

    // 检查缓存
    final cached = _cacheAll[host];
    if (cached != null && !cached.isExpired) {
      return cached.addresses;
    }

    // 定期清理过期缓存
    _maybeCleanup();

    // Inflight 去重：如果同域名正在查询，共享结果
    if (_inflight.containsKey(host)) {
      return _inflight[host]!;
    }

    final future = _doResolveAll(host);
    _inflight[host] = future;

    try {
      return await future;
    } finally {
      _inflight.remove(host);
    }
  }

  /// 实际执行解析
  Future<List<InternetAddress>> _doResolveAll(String host) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await _client.lookupAllWithTtl(host);
      stopwatch.stop();

      if (result.addresses.isEmpty) {
        NetworkLogger.logDoh(
          host: host,
          durationMs: stopwatch.elapsedMilliseconds,
          error: 'empty response',
        );
        return await _fallbackResolveAll(host);
      }

      // 根据设置排序地址（IPv6 优先 / IPv4 优先）
      final sorted = _sortAddresses(result.addresses);

      NetworkLogger.logDoh(
        host: host,
        durationMs: stopwatch.elapsedMilliseconds,
        resolvedIp: sorted.map((a) => a.address).join(', '),
      );

      // 使用 DNS TTL 缓存结果
      _putCache(host, _DohCacheEntryAll(
        addresses: sorted,
        expiresAt:
            DateTime.now().add(Duration(seconds: result.minTtl)),
      ));

      return sorted;
    } catch (e) {
      stopwatch.stop();
      NetworkLogger.logDoh(
        host: host,
        durationMs: stopwatch.elapsedMilliseconds,
        error: e.toString(),
      );
      return _fallbackResolveAll(host);
    }
  }

  /// 系统 DNS 回退解析（全部）
  Future<List<InternetAddress>> _fallbackResolveAll(String host) async {
    if (!enableFallback) return [];

    try {
      final addresses = await InternetAddress.lookup(host);
      if (addresses.isEmpty) return [];

      final sorted = _sortAddresses(addresses);

      NetworkLogger.log(
          '[DOH] 系统 DNS 回退成功: $host -> ${sorted.map((a) => a.address).join(', ')}');

      // 回退结果缓存时间短一些（2 分钟）
      _putCache(host, _DohCacheEntryAll(
        addresses: sorted,
        expiresAt: DateTime.now().add(const Duration(minutes: 2)),
      ));

      return sorted;
    } catch (e) {
      NetworkLogger.log('[DOH] 系统 DNS 回退也失败: $host | $e');
      return [];
    }
  }

  /// 测试 DoH 服务器延迟
  ///
  /// 测量 TCP + TLS 握手时间，反映真实网络延迟。
  /// 不发送 HTTP 请求，因此不受 HTTP/1.1 vs HTTP/2 限制。
  /// 部分服务器（如 Canadian Shield、Quad9）要求 HTTP/2，
  /// Dart 原生不支持 HTTP/2，所以只测连接层延迟。
  Future<int?> testLatency(String host) async {
    final uri = Uri.parse(_serverUrl);
    final serverHost = uri.host;
    final port = uri.port == 0 ? 443 : uri.port;

    // 获取 Bootstrap IP 或通过系统 DNS 解析
    final bootstrapIps = _client.bootstrapIps;
    List<InternetAddress> targets;

    if (bootstrapIps.isNotEmpty) {
      targets = bootstrapIps
          .map((ip) => InternetAddress(ip))
          .toList();
    } else {
      try {
        targets = await InternetAddress.lookup(serverHost)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        return null;
      }
    }

    if (targets.isEmpty) return null;

    // 逐个尝试，返回第一个成功的延迟
    for (final addr in targets) {
      try {
        final stopwatch = Stopwatch()..start();

        // TCP 连接
        final rawSocket = await Socket.connect(
          addr,
          port,
          timeout: const Duration(seconds: 5),
        );

        // TLS 握手（SNI 使用原始域名）
        final secureSocket = await SecureSocket.secure(
          rawSocket,
          host: serverHost,
        ).timeout(const Duration(seconds: 5));

        stopwatch.stop();
        final latency = stopwatch.elapsedMilliseconds;

        // 关闭连接
        secureSocket.destroy();

        return latency;
      } catch (_) {
        continue;
      }
    }

    return null;
  }

  /// 根据 preferIPv6 设置排序地址
  List<InternetAddress> _sortAddresses(List<InternetAddress> addresses) {
    if (_preferIPv6) {
      return <InternetAddress>[
        ...addresses.where((a) => a.type == InternetAddressType.IPv6),
        ...addresses.where((a) => a.type != InternetAddressType.IPv6),
      ];
    } else {
      return <InternetAddress>[
        ...addresses.where((a) => a.type == InternetAddressType.IPv4),
        ...addresses.where((a) => a.type != InternetAddressType.IPv4),
      ];
    }
  }

  /// 写入缓存，超过上限时淘汰最旧的条目
  void _putCache(String key, _DohCacheEntryAll entry) {
    _cacheAll[key] = entry;

    if (_cacheAll.length > _maxCacheSize) {
      // 淘汰过期条目
      _cacheAll.removeWhere((_, v) => v.isExpired);

      // 仍然超限，淘汰最早过期的条目
      if (_cacheAll.length > _maxCacheSize) {
        final sortedKeys = _cacheAll.keys.toList()
          ..sort((a, b) =>
              _cacheAll[a]!.expiresAt.compareTo(_cacheAll[b]!.expiresAt));
        final removeCount = _cacheAll.length - _maxCacheSize + _maxCacheSize ~/ 10;
        for (var i = 0; i < removeCount && i < sortedKeys.length; i++) {
          _cacheAll.remove(sortedKeys[i]);
        }
      }
    }
  }

  /// 定期清理过期缓存
  void _maybeCleanup() {
    _queryCount++;
    if (_queryCount >= _cleanupInterval) {
      _queryCount = 0;
      _cacheAll.removeWhere((_, v) => v.isExpired);
    }
  }

  void dispose() {
    _client.close();
    _inflight.clear();
  }
}

class _DohCacheEntryAll {
  _DohCacheEntryAll({required this.addresses, required this.expiresAt});

  final List<InternetAddress> addresses;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
