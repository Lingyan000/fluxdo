import 'topic.dart';

/// `/assign/suggestions` 响应:指定弹窗的候选用户 + 允许指定的群组列表。
/// 核对过插件源码 AssignController#suggestions。
class AssignSuggestions {
  final List<TopicUser> suggestions;
  final List<String> assignAllowedGroups;
  final List<String> assignAllowedForGroups;

  AssignSuggestions({
    required this.suggestions,
    required this.assignAllowedGroups,
    required this.assignAllowedForGroups,
  });

  factory AssignSuggestions.fromJson(Map<String, dynamic> json) {
    return AssignSuggestions(
      suggestions: (json['suggestions'] as List<dynamic>? ?? const [])
          .map((e) => TopicUser.fromJson(e as Map<String, dynamic>))
          .toList(),
      assignAllowedGroups:
          (json['assign_allowed_on_groups'] as List<dynamic>? ?? const [])
              .cast<String>(),
      assignAllowedForGroups:
          (json['assign_allowed_for_groups'] as List<dynamic>? ?? const [])
              .cast<String>(),
    );
  }
}
