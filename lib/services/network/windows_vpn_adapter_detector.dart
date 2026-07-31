import 'dart:io';

import 'package:flutter/foundation.dart';

/// Windows 活跃 VPN/TUN 网卡检测结果。
@immutable
class WindowsVpnAdapterStatus {
  const WindowsVpnAdapterStatus({
    required this.active,
    this.adapterNames = const [],
  });

  static const inactive = WindowsVpnAdapterStatus(active: false);

  final bool active;
  final List<String> adapterNames;
}

/// 补足 `connectivity_plus` 在 Windows 上对部分 TUN 网卡的漏判。
///
/// 很多 Wintun/Clash/sing-box 网卡向系统报告为普通以太网类型，插件因此只会
/// 返回 `ConnectivityResult.ethernet`。这里只在系统报告网络变化时枚举一次
/// 当前活跃接口，不使用常驻轮询。
class WindowsVpnAdapterDetector {
  const WindowsVpnAdapterDetector._();

  static const _vpnMarkers = <String>[
    'vpn',
    'tun',
    'tap',
    'wintun',
    'wireguard',
    'openvpn',
    'clash',
    'sing-box',
    'singbox',
    'v2ray',
    'xray',
    'tailscale',
    'zerotier',
    'nordlynx',
    'mullvad',
    'proton',
    'outline',
    'hysteria',
    'sstap',
    'sstp',
    'l2tp',
    'pptp',
    'ikev2',
    'warp',
    '虚拟专用网络',
  ];

  @visibleForTesting
  static bool looksLikeVpnAdapter(String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return _vpnMarkers.any(normalized.contains);
  }

  static Future<WindowsVpnAdapterStatus> detect() async {
    if (!Platform.isWindows) return WindowsVpnAdapterStatus.inactive;
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.any,
      );
      final names = <String>{
        for (final interface in interfaces)
          if (looksLikeVpnAdapter(interface.name)) interface.name,
      }.toList(growable: false);
      return WindowsVpnAdapterStatus(
        active: names.isNotEmpty,
        adapterNames: names,
      );
    } catch (error) {
      debugPrint('[WindowsVpnAdapterDetector] 枚举网卡失败: $error');
      return WindowsVpnAdapterStatus.inactive;
    }
  }
}
