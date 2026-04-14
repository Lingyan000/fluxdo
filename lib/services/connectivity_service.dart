import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'network/discourse_dio.dart';
import 'network/vpn_auto_toggle_service.dart';

/// 网络连通性检测服务
///
/// 参考 Discourse `NetworkConnectivity` 服务：
/// - 监听设备网络状态变化（WiFi/移动数据断开/恢复）
/// - 可选通过 ping `/srv/status` 验证服务器可达性
/// - 断开时定时重试，恢复后通知订阅者
class ConnectivityService {
  static final ConnectivityService _instance = ConnectivityService._internal();
  factory ConnectivityService() => _instance;
  ConnectivityService._internal();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _retryTimer;
  Timer? _disconnectDebounce;
  bool _retryInFlight = false;
  int _retryBackoffSeconds = 1;
  static const int _maxRetryBackoffSeconds = 30;

  bool _isConnected = true;
  bool _initialized = false;
  final _controller = StreamController<bool>.broadcast();

  /// 是否启用服务器 ping 验证，false 时仅依赖本地网络状态检测
  static const bool enableServerPing = false;

  /// 连接状态流（true = 已连接，false = 已断开）
  Stream<bool> get connectionStream => _controller.stream;

  /// 当前是否已连接
  bool get isConnected => _isConnected;

  /// 使用项目统一 Dio（含平台适配器、Cookie 等），
  /// 但关闭重试、CF 验证、并发限制，避免 ping 请求被干扰或排队
  late final Dio _pingDio = DiscourseDio.create(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    maxConcurrent: null,
    enableRetry: false,
    enableCfChallenge: false,
  );

  static bool get _isFlatpakSandbox =>
      Platform.isLinux && Platform.environment.containsKey('FLATPAK_ID');

  static bool get _hasSystemBusSocket =>
      File('/var/run/dbus/system_bus_socket').existsSync();

  static bool get _canUseConnectivityPlugin =>
      !_isFlatpakSandbox || _hasSystemBusSocket;

  static Future<List<ConnectivityResult>> safeCheckConnectivity() async {
    if (!_canUseConnectivityPlugin) {
      debugPrint(
        '[Connectivity] Flatpak sandbox without system bus, fallback to connected state',
      );
      return const [ConnectivityResult.other];
    }

    try {
      return await Connectivity().checkConnectivity();
    } catch (e) {
      debugPrint('[Connectivity] checkConnectivity 失败，fallback to connected state: $e');
      return const [ConnectivityResult.other];
    }
  }

  /// 初始化服务
  void init() {
    if (_initialized) return;
    _initialized = true;

    if (!_canUseConnectivityPlugin) {
      debugPrint(
        '[Connectivity] Flatpak sandbox missing system bus, skip connectivity_plus subscription',
      );
      _setConnected(true);
      return;
    }

    // 监听网络变化事件
    _connectivitySub = _connectivity.onConnectivityChanged.listen(
      _onConnectivityChanged,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[Connectivity] 监听网络状态失败，fallback to connected state: $error');
        _setConnected(true);
      },
    );

    // 启动时检查一次
    _checkInitial();
  }

  Future<void> _checkInitial() async {
    try {
      final result = await safeCheckConnectivity();
      await _onConnectivityChanged(result);
    } catch (e) {
      debugPrint('[Connectivity] 初始检查失败: $e');
    }
  }

  Future<void> _onConnectivityChanged(List<ConnectivityResult> results) async {
    debugPrint('[Connectivity] onConnectivityChanged: $results');
    VpnAutoToggleService.instance.handleConnectivityChanged(results);
    final hasNetwork = results.isNotEmpty &&
        !results.every((r) => r == ConnectivityResult.none);

    if (!hasNetwork) {
      // connectivity_plus 在启动/恢复时可能先发一个瞬态 [none]，
      // 防抖 500ms 避免假断开通知。
      _disconnectDebounce?.cancel();
      _disconnectDebounce = Timer(const Duration(milliseconds: 500), () {
        _setConnected(false);
      });
      return;
    }

    // 有网络事件到达，取消待定的断开防抖
    _disconnectDebounce?.cancel();

    if (enableServerPing) {
      final reachable = await pingServer();
      _setConnected(reachable);
    } else {
      _setConnected(true);
    }
  }

  /// ping 服务器验证可达性
  /// 返回 true 表示服务器可达
  ///
  /// 参考 Discourse 实现：响应状态码为 200 且内容为 "ok" 才算可达。
  Future<bool> pingServer() async {
    try {
      final response = await _pingDio.get(
        '/srv/status',
        options: Options(validateStatus: (_) => true),
      );
      return response.statusCode == 200 &&
          response.data?.toString().trim() == 'ok';
    } on DioException catch (e) {
      if (e.response != null) {
        return e.response!.statusCode == 200 &&
            e.response!.data?.toString().trim() == 'ok';
      }
      debugPrint('[Connectivity] ping 失败: ${e.type}');
      return false;
    } catch (e) {
      debugPrint('[Connectivity] ping 异常: $e');
      return false;
    }
  }

  void _setConnected(bool connected) {
    // ping 确认已连接时，取消待定的断开防抖（即使状态未变也要取消）
    if (connected) _disconnectDebounce?.cancel();
    if (_isConnected == connected) return;
    _isConnected = connected;
    _controller.add(connected);
    debugPrint('[Connectivity] 连接状态变更: ${connected ? "已连接" : "已断开"}');

    if (!connected) {
      _startRetry();
    } else {
      _stopRetry();
    }
  }

  /// 断开时使用指数退避检查设备网络状态（1s → 2s → 4s → ... → 30s）
  void _startRetry() {
    _stopRetry();
    _retryBackoffSeconds = 1;
    _scheduleNextRetry();
  }

  void _scheduleNextRetry() {
    _retryTimer = Timer(Duration(seconds: _retryBackoffSeconds), () async {
      if (_isConnected) return; // 已恢复，无需继续
      if (_retryInFlight) return; // 上一次检查尚未完成，跳过
      _retryInFlight = true;
      try {
        final result = await safeCheckConnectivity();
        final hasNetwork = result.isNotEmpty &&
            !result.every((r) => r == ConnectivityResult.none);
        if (hasNetwork) {
          if (enableServerPing) {
            final reachable = await pingServer();
            if (reachable) _setConnected(true); // _setConnected(true) 内部会调用 _stopRetry
          } else {
            _setConnected(true);
          }
        } else {
          debugPrint('[Connectivity] 设备无网络，${_retryBackoffSeconds}s 后重试');
        }
      } finally {
        _retryInFlight = false;
      }
      // 仍未恢复，增大退避间隔并继续重试
      if (!_isConnected) {
        _retryBackoffSeconds = (_retryBackoffSeconds * 2).clamp(1, _maxRetryBackoffSeconds);
        _scheduleNextRetry();
      }
    });
  }

  void _stopRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryInFlight = false;
    _retryBackoffSeconds = 1;
  }

  /// 手动触发一次检查（如 App 回到前台时）
  Future<void> check() async {
    if (enableServerPing) {
      final reachable = await pingServer();
      _setConnected(reachable);
    } else {
      final result = await safeCheckConnectivity();
      final hasNetwork = result.isNotEmpty &&
          !result.every((r) => r == ConnectivityResult.none);
      _setConnected(hasNetwork);
    }
  }

  void dispose() {
    _connectivitySub?.cancel();
    _disconnectDebounce?.cancel();
    _stopRetry();
    _controller.close();
    _initialized = false;
  }
}
