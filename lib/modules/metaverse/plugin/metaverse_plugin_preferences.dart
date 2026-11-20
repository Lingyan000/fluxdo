/// 插件偏好只声明普通设置，凭证继续使用宿主安全存储。
class MetaversePreference {
  const MetaversePreference(
    this.key,
    this.title,
    this.type,
    this.defaultValue,
    this.options,
  );
  final String key, title, type;
  final Object defaultValue;
  final Map<String, String> options;
  bool accepts(Object? value) => switch (type) {
    'toggle' => value is bool,
    'choice' => value is String && options.containsKey(value),
    _ => value is String && value.length <= 512,
  };
  static List<MetaversePreference> parse(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > 24) {
      throw const FormatException('偏好设置须为至多 24 项的数组');
    }
    final keys = <String>{}, result = <MetaversePreference>[];
    for (final field in raw) {
      if (field is! Map ||
          field['key'] is! String ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$')
              .hasMatch(field['key'] as String) ||
          !keys.add(field['key'] as String) ||
          field['title'] is! String ||
          (field['title'] as String).trim().isEmpty ||
          (field['title'] as String).length > 80 ||
          !['toggle', 'text', 'choice'].contains(field['type'])) {
        throw const FormatException('偏好设置声明无效');
      }
      final options = field['options'] ?? <String, String>{};
      if (options is! Map ||
          options.length > 32 ||
          options.entries.any(
            (e) =>
                e.key is! String ||
                e.value is! String ||
                (e.key as String).length > 128 ||
                (e.value as String).length > 80,
          )) {
        throw const FormatException('偏好选项无效');
      }
      final preference = MetaversePreference(
        field['key'] as String,
        field['title'] as String,
        field['type'] as String,
        field['default'] ?? (field['type'] == 'toggle' ? false : ''),
        options.cast<String, String>(),
      );
      if (!preference.accepts(preference.defaultValue)) {
        throw const FormatException('偏好默认值无效');
      }
      result.add(preference);
    }
    return List.unmodifiable(result);
  }
}
