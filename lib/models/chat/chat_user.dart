import '../../utils/url_helper.dart';

/// Chat 消息/频道成员的轻量用户模型
class ChatUser {
  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;

  const ChatUser({
    required this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
  });

  factory ChatUser.fromJson(Map<String, dynamic> json) {
    return ChatUser(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
    );
  }

  String getAvatarUrl({int size = 96}) {
    if (avatarTemplate == null) return '';
    final template = avatarTemplate!.replaceAll('{size}', size.toString());
    return UrlHelper.resolveUrlWithCdn(template);
  }
}
