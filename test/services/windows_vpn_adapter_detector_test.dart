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

    test('TUN 补充信号不扩大自动压制范围', () {
      expect(
        VpnAutoToggleService.shouldAutoSuppress(const [
          ConnectivityResult.ethernet,
        ]),
        isFalse,
      );
      expect(
        VpnAutoToggleService.shouldAutoSuppress(const [ConnectivityResult.vpn]),
        isTrue,
      );
    });

    test('VPN 判定模式可覆盖自动检测结果', () {
      expect(
        VpnAutoToggleService.resolveDetection(
          automaticValue: false,
          mode: VpnDetectionMode.automatic,
        ),
        isFalse,
      );
      expect(
        VpnAutoToggleService.resolveDetection(
          automaticValue: false,
          mode: VpnDetectionMode.forceActive,
        ),
        isTrue,
      );
      expect(
        VpnAutoToggleService.resolveDetection(
          automaticValue: true,
          mode: VpnDetectionMode.forceInactive,
        ),
        isFalse,
      );
    });

    test('未知持久化值回退为自动判定', () {
      expect(
        VpnDetectionMode.fromString('forceActive'),
        VpnDetectionMode.forceActive,
      );
      expect(
        VpnDetectionMode.fromString('unknown'),
        VpnDetectionMode.automatic,
      );
      expect(VpnDetectionMode.fromString(null), VpnDetectionMode.automatic);
    });
  });
}
