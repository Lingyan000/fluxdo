import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../doh/network_settings_service.dart';
import '../proxy/proxy_settings_service.dart';

/// rhttp 引擎使用模式
enum RhttpMode {
  /// 始终使用 rhttp
  always,

  /// 仅在启用代理/DOH 时使用
  proxyOnly,
}

/// rhttp 引擎设置
class RhttpSettings {
  const RhttpSettings({
    this.enabled = false,
    this.mode = RhttpMode.always,
    this.forceDisabled = false,
  });

  final bool enabled;
  final RhttpMode mode;

  /// 运行时强制禁用标志（不持久化，仅当前进程有效）
  /// 当 rhttp Rust 引擎初始化失败时由 forceDisable() 置为 true，
  /// 下次启动自动恢复为 false 并重新尝试初始化
  final bool forceDisabled;

  RhttpSettings copyWith({
    bool? enabled,
    RhttpMode? mode,
    bool? forceDisabled,
  }) {
    return RhttpSettings(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      forceDisabled: forceDisabled ?? this.forceDisabled,
    );
  }
}

/// rhttp 引擎设置管理服务
class RhttpSettingsService {
  RhttpSettingsService._internal();

  static final RhttpSettingsService instance = RhttpSettingsService._internal();

  static const _enabledKey = 'rhttp_enabled';
  static const _modeKey = 'rhttp_mode';

  final ValueNotifier<RhttpSettings> notifier = ValueNotifier(
    const RhttpSettings(),
  );

  SharedPreferences? _prefs;
  int _version = 0;

  int get version => _version;
  RhttpSettings get current => notifier.value;

  Future<void> initialize(SharedPreferences prefs) async {
    if (_prefs != null) return;
    _prefs = prefs;
    final enabled = prefs.getBool(_enabledKey) ?? false;
    final modeIndex = prefs.getInt(_modeKey) ?? 0;
    final mode = modeIndex < RhttpMode.values.length
        ? RhttpMode.values[modeIndex]
        : RhttpMode.always;
    notifier.value = RhttpSettings(enabled: enabled, mode: mode);
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(enabled: enabled);
    await prefs.setBool(_enabledKey, enabled);
    _touch();
  }

  Future<void> setMode(RhttpMode mode) async {
    final prefs = _prefs;
    if (prefs == null) return;
    notifier.value = notifier.value.copyWith(mode: mode);
    await prefs.setInt(_modeKey, mode.index);
    _touch();
  }

  /// 强制禁用（Rhttp.init() 失败时调用）
  ///
  /// 仅修改运行时内存状态，不持久化到 SharedPreferences，
  /// 确保下次启动仍会重新尝试初始化 rhttp 引擎。
  Future<void> forceDisable() async {
    if (_prefs == null) return;
    notifier.value = notifier.value.copyWith(forceDisabled: true);
    _touch();
    debugPrint('[rhttp] 已强制禁用（初始化失败）');
  }

  /// 综合判断当前是否应该使用 rhttp
  bool shouldUseRhttp(NetworkSettings ns, ProxySettings ps) {
    if (!current.enabled) return false;
    if (current.forceDisabled) return false;
    // rhttp fork 已支持 ECH（通过 TlsSettings.echConfigList），不再排除
    // proxyOnly 模式：仅代理/DOH 启用时使用
    if (current.mode == RhttpMode.proxyOnly) {
      return ns.dohEnabled || ps.isValid;
    }
    return true; // always 模式
  }

  /// 重置单例内部状态，仅用于测试，使 initialize() 可重新执行。
  @visibleForTesting
  void resetForTest() {
    _prefs = null;
    _version = 0;
  }

  void _touch() {
    _version++;
    notifier.value = notifier.value.copyWith();
  }
}
