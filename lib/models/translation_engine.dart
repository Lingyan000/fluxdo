/// 翻译服务的持久化标识，已有 AI 翻译偏好仍沿用原来的存储键。
enum TranslationEngine {
  google,
  bing,
  bilibili,
  ai;

  static TranslationEngine? tryParse(String? value) {
    for (final engine in values) {
      if (engine.name == value) return engine;
    }
    return null;
  }
}
