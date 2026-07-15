import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/vpn_auto_toggle_service.dart';
import 'package:fluxdo/services/network/windows_vpn_adapter_detector.dart';

void main() {
  group('Windows VPN/TUN 网卡识别', () {
    test('识别常见 TUN 与 VPN 网卡', () {
      expect(WindowsVpnAdapterDetector.looksLikeVpnAdapter('FlClash'), isTrue);
      expect(
        WindowsVpnAdapterDetector.looksLikeVpnAdapter('Meta Tunnel'),
        isTrue,
      );
      expect(
        WindowsVpnAdapterDetector.looksLikeVpnAdapter('WireGuard Tunnel'),
        isTrue,
      );
      expect(
        WindowsVpnAdapterDetector.looksLikeVpnAdapter('Tailscale'),
        isTrue,
      );
    });

    test('不把普通虚拟交换网卡当成 VPN', () {
      expect(
        WindowsVpnAdapterDetector.looksLikeVpnAdapter(
          'vEthernet (Default Switch)',
        ),
        isFalse,
      );
      expect(
        WindowsVpnAdapterDetector.looksLikeVpnAdapter('VMware Network Adapter'),
        isFalse,
      );
      expect(WindowsVpnAdapterDetector.looksLikeVpnAdapter('WLAN'), isFalse);
    });

    test('把 Windows TUN 网卡并入既有 VPN 判定', () {
      expect(
        VpnAutoToggleService.resolveVpnActive(
          connectivityResults: const [ConnectivityResult.ethernet],
          hasWindowsVpnAdapter: true,
        ),
        isTrue,
      );
      expect(
        VpnAutoToggleService.resolveVpnActive(
          connectivityResults: const [ConnectivityResult.ethernet],
          hasWindowsVpnAdapter: false,
        ),
        isFalse,
      );
    });
  });
}
