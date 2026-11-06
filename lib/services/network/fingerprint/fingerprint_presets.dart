/// 仅包含名称与稳定 ID；TLS/H2 数据只存于原生核心。与原生 manifest 做一致性回归。
class FingerprintPreset {
  const FingerprintPreset(this.id, this.label);
  final String id;
  final String label;

  static const automatic = 'auto';
  static const values = [
    FingerprintPreset('android-webview133', 'Android · WebView 133'),
    FingerprintPreset('android-chrome149', 'Android · Chrome 149'),
    FingerprintPreset('ios-safari17', 'iOS · Safari 17'),
    FingerprintPreset('ios-safari18', 'iOS · Safari 18'),
    FingerprintPreset('ios-safari26', 'iOS · Safari 26'),
    FingerprintPreset('macos-safari18', 'macOS · Safari 18'),
    FingerprintPreset('macos-safari26', 'macOS · Safari 26'),
    FingerprintPreset('windows-edge152', 'Windows · Edge 152'),
    FingerprintPreset('windows-edge153', 'Windows · Edge 153'),
    FingerprintPreset('windows-edge154', 'Windows · Edge 154'),
  ];

  static String normalize(String? value) =>
      values.any((preset) => preset.id == value) ? value! : automatic;

  static String? labelFor(String? id) {
    for (final preset in values) {
      if (preset.id == id) return preset.label;
    }
    return null;
  }
}
