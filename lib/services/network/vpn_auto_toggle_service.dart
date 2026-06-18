import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'doh/network_settings_service.dart';
import 'proxy/proxy_settings_service.dart';

/// VPN 自动切换服务
///
/// 检测到 VPN 开启时自动关闭 DOH 和上游代理，VPN 关闭后自动恢复。
/// 采用"压制标记"模式：通过 SharedPreferences 标记哪些项是被 VPN 自动关闭的，
/// VPN 关闭后根据标记恢复，不修改 NetworkSettingsService / ProxySettingsService 内部逻辑。
class VpnAutoToggleService {
  VpnAutoToggleService._();
  static final VpnAutoToggleService instance = VpnAutoToggleService._();

  static const _keyEnabled = 'vpn_auto_toggle_enabled';
  static const _keySuppressedDoh = 'vpn_suppressed_doh';
  static const _keySuppressedProxy = 'vpn_suppressed_proxy';

  late SharedPreferences _prefs;

  /// 功能是否启用
  final enabledNotifier = ValueNotifier<bool>(false);

  /// 当前是否检测到 VPN
  final vpnActiveNotifier = ValueNotifier<bool>(false);

  /// 压制标记变化通知（UI 据此刷新"VPN 断开后是否启用"的意图显示）
  final suppressionNotifier = ValueNotifier<int>(0);

  /// 防重入标记
  bool _isSuppressing = false;

  void _bumpSuppression() => suppressionNotifier.value++;

  bool get enabled => enabledNotifier.value;
  bool get vpnActive => vpnActiveNotifier.value;

  /// DOH 是否被 VPN 压制
  bool get isDohSuppressed => _prefs.getBool(_keySuppressedDoh) ?? false;

  /// 代理是否被 VPN 压制
  bool get isProxySuppressed => _prefs.getBool(_keySuppressedProxy) ?? false;

  void initialize(SharedPreferences prefs) {
    _prefs = prefs;
    enabledNotifier.value = prefs.getBool(_keyEnabled) ?? false;
  }

  /// 开关控制
  Future<void> setEnabled(bool value) async {
    enabledNotifier.value = value;
    await _prefs.setBool(_keyEnabled, value);

    if (!value) {
      // 关闭功能时，如果有活跃压制则立即恢复
      await _restore();
    } else if (vpnActive) {
      // 开启功能且当前 VPN 活跃，立即压制
      await _suppress();
    }
  }

  /// 由 ConnectivityService 调用
  void handleConnectivityChanged(List<ConnectivityResult> results) {
    final hasVpn = results.contains(ConnectivityResult.vpn);
    vpnActiveNotifier.value = hasVpn;

    if (!enabled) return;

    if (hasVpn) {
      _suppress();
    } else {
      _restore();
    }
  }

  /// 启动时同步一次 VPN 状态，避免首个请求发出后再切换网络配置。
  Future<void> syncInitialState(List<ConnectivityResult> results) async {
    final hasVpn = results.contains(ConnectivityResult.vpn);
    vpnActiveNotifier.value = hasVpn;

    if (!enabled) return;

    if (hasVpn) {
      await _suppress();
    } else {
      await _restore();
    }
  }

  /// VPN 开启时压制 DOH 和代理
  Future<void> _suppress() async {
    if (_isSuppressing) return;
    _isSuppressing = true;

    try {
      final dohService = NetworkSettingsService.instance;
      final proxyService = ProxySettingsService.instance;

      // 检查 DOH 是否开启，开启则压制
      if (dohService.notifier.value.dohEnabled) {
        await _prefs.setBool(_keySuppressedDoh, true);
        await dohService.setDohEnabled(false);
        debugPrint('[VpnAutoToggle] 压制 DOH');
      }

      // 检查代理是否开启，开启则压制
      if (proxyService.notifier.value.enabled) {
        await _prefs.setBool(_keySuppressedProxy, true);
        await proxyService.setEnabled(false);
        debugPrint('[VpnAutoToggle] 压制上游代理');
      }
    } finally {
      _isSuppressing = false;
      _bumpSuppression();
    }
  }

  /// VPN 关闭后恢复被压制的项
  Future<void> _restore() async {
    if (_isSuppressing) return;
    _isSuppressing = true;

    try {
      // 恢复 DOH
      if (isDohSuppressed) {
        await _prefs.remove(_keySuppressedDoh);
        await NetworkSettingsService.instance.setDohEnabled(true);
        debugPrint('[VpnAutoToggle] 恢复 DOH');
      }

      // 恢复代理
      if (isProxySuppressed) {
        await _prefs.remove(_keySuppressedProxy);
        await ProxySettingsService.instance.setEnabled(true);
        debugPrint('[VpnAutoToggle] 恢复上游代理');
      }
    } finally {
      _isSuppressing = false;
      _bumpSuppression();
    }
  }

  /// 当用户在 VPN 活跃期间手动开启被压制的项时，清除对应标记
  ///
  /// 由 UI 层在检测到手动开启时调用
  void clearDohSuppression() {
    _prefs.remove(_keySuppressedDoh);
    debugPrint('[VpnAutoToggle] 清除 DOH 压制标记（用户手动开启）');
  }

  void clearProxySuppression() {
    _prefs.remove(_keySuppressedProxy);
    debugPrint('[VpnAutoToggle] 清除代理压制标记（用户手动开启）');
  }

  /// VPN 活跃期间用户拨动开关：仅记录"VPN 断开后是否启用"的意图，
  /// 不改动实际设置、不立即生效（UI 与功能分离）。
  Future<void> setDohSuppressed(bool wantEnabled) async {
    if (wantEnabled) {
      await _prefs.setBool(_keySuppressedDoh, true);
    } else {
      await _prefs.remove(_keySuppressedDoh);
    }
    _bumpSuppression();
  }

  Future<void> setProxySuppressed(bool wantEnabled) async {
    if (wantEnabled) {
      await _prefs.setBool(_keySuppressedProxy, true);
    } else {
      await _prefs.remove(_keySuppressedProxy);
    }
    _bumpSuppression();
  }
}
