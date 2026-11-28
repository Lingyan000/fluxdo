/// 清单翻译只覆盖显示文字，权限、资源路径和稳定标识不能被翻译覆盖。
class MetaverseManifestLocalization {
  static Map<String, int> fields(Map<String, dynamic> manifest) => {
    if (manifest.containsKey('name')) 'name': 40,
    if (manifest.containsKey('description')) 'description': 200,
    for (final page in (manifest['pages'] as List? ?? const [])) ...{
      'pages.${page['id']}.title': 40,
      if (page['navigation'] != null)
        'pages.${page['id']}.navigation.label': 12,
    },
    for (final task in (manifest['tasks'] as List? ?? const []))
      'tasks.${task['id']}.title': 80,
    for (final preference
        in (manifest['preferences'] as List? ?? const [])) ...{
      'preferences.${preference['key']}.title': 80,
      for (final option in (preference['options'] as Map? ?? const {}).keys)
        'preferences.${preference['key']}.options.$option': 80,
    },
  };

  static void validate(Map<String, dynamic> manifest) {
    final raw = manifest['locales'];
    if (raw == null) return;
    if (raw is! Map ||
        raw.length > 16 ||
        !(manifest['requiredFeatures'] as List? ?? const []).contains(
          'manifestLocalization',
        )) {
      throw const FormatException('清单翻译须声明 manifestLocalization，最多 16 种语言');
    }
    validateFields(raw, fields(manifest));
  }

  static void validateFields(Object? raw, Map<String, int> allowed) {
    if (raw == null) return;
    if (raw is! Map || raw.length > 16) {
      throw const FormatException('翻译最多 16 种语言');
    }
    for (final locale in raw.entries) {
      if (locale.key is! String ||
          !RegExp(r'^[a-z]{2,3}(?:[-_][A-Za-z0-9]{2,8}){0,2}$')
              .hasMatch(locale.key) ||
          locale.value is! Map) {
        throw const FormatException('清单翻译语言无效');
      }
      for (final field in (locale.value as Map).entries) {
        final max = allowed[field.key];
        if (max == null ||
            field.value is! String ||
            (field.value as String).trim().isEmpty ||
            (field.value as String).length > max ||
            (field.value as String).contains(RegExp(r'[\x00-\x1f\x7f]'))) {
          throw const FormatException('清单翻译包含未知字段或过长文案');
        }
      }
    }
  }

  static String text(
    Map<String, dynamic> manifest,
    String key,
    String fallback,
    String locale,
  ) {
    final translations = manifest['locales'] as Map? ?? const {};
    final language = locale.replaceAll('_', '-').toLowerCase();
    final candidates = [
      language,
      if (language.startsWith('zh-hant') || language == 'zh-tw') 'zh-tw',
      if (language == 'zh-mo') 'zh-hk',
      language.split('-').first,
    ];
    for (final candidate in candidates) {
      for (final entry in translations.entries) {
        if (entry.key.toString().replaceAll('_', '-').toLowerCase() ==
                candidate &&
            entry.value is Map &&
            (entry.value as Map)[key] is String) {
          return (entry.value as Map)[key] as String;
        }
      }
    }
    return fallback;
  }
}
