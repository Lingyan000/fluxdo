import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'system_proxy_detector.dart';

/// Windows 系统代理跟随服务。
///
/// 背景:WebView2 默认跟随系统代理(如 Clash「系统代理」模式),而 Dio/rhttp
/// 走直连。两者出口 IP 不一致时,验证 WebView 铸出的 cf_clearance 绑定的是
/// 代理节点 IP,对 Dio 的直连请求永远无效 → CF 验证无限循环。
///
/// 本服务周期读取注册表系统代理(仅 Windows):
/// - 已启用固定代理 → [effectiveProxyUrl] 返回代理地址,Dio 跟随,与
///   WebView2 保持同一出口;代理进程若已死,请求显式失败(与 WebView 一致),
///   不做可达性探测——探测无法区分翻墙代理与校园网等普通代理,不能作为
///   任何语义判定依据。
/// - 未启用 / PAC-only(无法在 Dart 侧求值)/ 非 Windows → 直连。
///
/// VPN 虚拟网卡(TUN)模式不写系统代理,Dio 与 WebView 都经 TUN 出站,
/// 天然一致,无需本服务干预。
class SystemProxyService {
  SystemProxyService._();

  static final instance = SystemProxyService._();

  static const _refreshInterval = Duration(seconds: 10);

  /// 状态版本号。effectiveProxyUrl 变化时自增,RhttpAdapter 据此重建 client。
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  String? _effectiveProxyUrl;
  SystemProxyConfig _lastConfig = const SystemProxyConfig();
  Timer? _refreshTimer;
  bool _started = false;

  /// 当前系统代理地址(注册表已启用的固定代理),未启用时为 null。
  String? get effectiveProxyUrl {
    _ensureStarted();
    return _effectiveProxyUrl;
  }

  /// 注册表层面的系统代理配置,供诊断 UI 展示。
  SystemProxyConfig get registryConfig => _lastConfig;

  /// 启动周期刷新。非 Windows 平台为 no-op。
  void start() => _ensureStarted();

  void _ensureStarted() {
    if (_started || !Platform.isWindows) return;
    _started = true;
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => refresh());
    refresh();
  }

  /// 立即重读注册表。
  void refresh() {
    if (!Platform.isWindows) return;
    final config = SystemProxyDetector.read();
    _lastConfig = config;

    final effective = config.proxyUrl;
    if (effective != _effectiveProxyUrl) {
      debugPrint(
        '[SystemProxy] 系统代理变化: ${_effectiveProxyUrl ?? 'direct'} -> '
        '${effective ?? 'direct'}',
      );
      _effectiveProxyUrl = effective;
      version.value++;
    }
  }

  @visibleForTesting
  void resetForTest() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _started = false;
    _effectiveProxyUrl = null;
    _lastConfig = const SystemProxyConfig();
  }
}
