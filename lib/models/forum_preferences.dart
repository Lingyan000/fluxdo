import 'package:flutter/foundation.dart';

enum ForumPreferenceSection {
  account,
  security,
  profile,
  notifications,
  emails,
  tracking,
  users,
  chat,
  apps,
  calendar,
}

enum ForumPreferenceKind {
  text,
  multiline,
  toggle,
  choice,
  flair,
  categories,
  tags,
  tagNames,
  theme,
  usernames,
  image,
  schedule,
  multiChoice,
  birthday,
}

/// 字段同时描述读取位置与 API 的序列化方式，保存时只提交修改项。
class ForumPreferenceField {
  const ForumPreferenceField({
    required this.key,
    required this.label,
    this.kind = ForumPreferenceKind.text,
    this.container,
    this.choices = const {},
    this.help,
    this.required = false,
    this.emptyValue,
    this.uploadType,
    this.group = '',
    this.enabledBy,
  });

  final String key;
  final String label;
  final ForumPreferenceKind kind;
  final String? container;
  final Map<Object, String> choices;
  final String? help;
  final bool required;
  final Object? emptyValue;
  final String? uploadType;
  final String group;
  final String? enabledBy;

  String get id => '${container ?? "user"}.$key';

  dynamic read(Map<String, dynamic> user) {
    final value = container == null
        ? user[key]
        : (user[container] as Map?)?[key];
    return switch (kind) {
      ForumPreferenceKind.flair => value ?? 0,
      ForumPreferenceKind.tags ||
      ForumPreferenceKind.tagNames => _tagNames(value),
      ForumPreferenceKind.categories ||
      ForumPreferenceKind.theme ||
      ForumPreferenceKind.usernames ||
      ForumPreferenceKind.multiChoice =>
        value is List
            ? List<Object>.from(value)
            : value is String && value.isNotEmpty
            ? value.split(',').map((item) => item.trim()).toList()
            : <Object>[],
      ForumPreferenceKind.text ||
      ForumPreferenceKind.multiline ||
      ForumPreferenceKind.image => value?.toString() ?? '',
      ForumPreferenceKind.schedule => Map<String, dynamic>.from(
        value as Map? ?? {},
      ),
      _ => value,
    };
  }

  // Discourse 返回标签对象，旧数据也可能是名称列表或逗号分隔字符串。
  static List<String> _tagNames(dynamic value) {
    final items = value is List
        ? value
        : value is String
        ? value.split(',')
        : const [];
    return items
        .map((item) => item is Map ? item['name'] : item)
        .whereType<String>()
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  dynamic serialize(dynamic value) {
    if (kind == ForumPreferenceKind.flair && value == 0) return '';
    if (container == 'user_fields' &&
        kind == ForumPreferenceKind.multiChoice &&
        (value as List).isEmpty) {
      return null;
    }
    if (container == 'user_fields' && kind == ForumPreferenceKind.toggle) {
      return value == true ? 'true' : 'false';
    }
    if (kind == ForumPreferenceKind.tags) {
      return _tagNames(value).join(',');
    }
    if (kind == ForumPreferenceKind.tagNames) {
      final names = _tagNames(value);
      return names.isEmpty ? null : names;
    }
    if (kind == ForumPreferenceKind.categories && (value as List).isEmpty) {
      return emptyValue;
    }
    if (kind == ForumPreferenceKind.usernames) {
      return (value as List).join(',');
    }
    return value;
  }
}

class ForumPreferences {
  ForumPreferences({
    required this.user,
    required this.site,
    required this.settings,
  });

  final Map<String, dynamic> user;
  final Map<String, dynamic> site;
  final Map<String, dynamic> settings;

  String get username => user['username'] as String;
  Map<String, dynamic> get options =>
      Map<String, dynamic>.from(user['user_option'] as Map? ?? {});
  bool get canEdit => user['can_edit'] == true && user['user_option'] is Map;

  List<Map<String, dynamic>> records(String key) => (user[key] as List? ?? [])
      .whereType<Map>()
      .map(Map<String, dynamic>.from)
      .toList();
}

class ForumPreferenceDraft {
  ForumPreferenceDraft(this.fields, this.user)
    : values = {for (final field in fields) field.id: field.read(user)};

  final List<ForumPreferenceField> fields;
  final Map<String, dynamic> user;
  final Map<String, dynamic> values;

  bool isChanged(ForumPreferenceField field) =>
      !_equal(field.read(user), values[field.id]);

  bool get dirty => fields.any(isChanged);

  void update(ForumPreferenceField field, dynamic value) {
    values[field.id] = value;
    if (field.kind != ForumPreferenceKind.categories &&
        field.kind != ForumPreferenceKind.tags) {
      return;
    }
    // 同一分类或标签只能属于一个通知级别，迁移时同时提交旧级别的移除。
    final selected = (value as List).toSet();
    for (final other in fields) {
      if (other.id == field.id || other.kind != field.kind) continue;
      values[other.id] = (values[other.id] as List)
          .where((item) => !selected.contains(item))
          .toList();
    }
  }

  Map<String, dynamic> get payload {
    final result = <String, dynamic>{};
    for (final field in fields.where(isChanged)) {
      final value = field.serialize(values[field.id]);
      final container = field.container;
      if (container == null || container == 'user_option') {
        result[field.key] = value;
      } else {
        final nested = result.putIfAbsent(
          container,
          () => <String, dynamic>{},
        ) as Map<String, dynamic>;
        nested[field.key] = value;
      }
    }
    return result;
  }

  static bool _equal(dynamic left, dynamic right) {
    if (left is List && right is List) return listEquals(left, right);
    if (left is Map && right is Map) return mapEquals(left, right);
    return left == right;
  }
}
