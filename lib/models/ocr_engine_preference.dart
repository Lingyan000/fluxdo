/// 图片文字识别引擎偏好（仅在支持系统原生 Vision 引擎的 macOS / iOS 上生效）。
enum OcrEnginePreference {
  /// 系统内置引擎（macOS / iOS 使用 Apple Vision 硬件加速，免模型下载）。
  system,

  /// 跨平台离线模型（PP-OCR + LiteRT）。
  litert;

  static OcrEnginePreference parse(String? value) {
    for (final item in values) {
      if (item.name == value) return item;
    }
    return OcrEnginePreference.system;
  }
}
