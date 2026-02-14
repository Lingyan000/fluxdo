// 话题投票相关数据模型
import '../utils/url_helper.dart';

/// 投票响应数据
class VoteResponse {
  final bool canVote;
  final int voteLimit;
  final int voteCount;
  final int votesLeft;
  final bool alert;
  final List<VotedUser>? whoVoted;

  VoteResponse({
    required this.canVote,
    required this.voteLimit,
    required this.voteCount,
    required this.votesLeft,
    required this.alert,
    this.whoVoted,
  });

  factory VoteResponse.fromJson(Map<String, dynamic> json) {
    return VoteResponse(
      canVote: json['can_vote'] as bool? ?? false,
      voteLimit: json['vote_limit'] as int? ?? 0,
      voteCount: json['vote_count'] as int? ?? 0,
      votesLeft: json['votes_left'] as int? ?? 0,
      alert: json['alert'] as bool? ?? false,
      whoVoted: json['who_voted'] != null
          ? (json['who_voted'] as List<dynamic>)
              .map((e) => VotedUser.fromJson(e as Map<String, dynamic>))
              .toList()
          : null,
    );
  }
}

/// 投票用户信息
class VotedUser {
  final int id;
  final String username;
  final String? name;
  final String avatarTemplate;

  VotedUser({
    required this.id,
    required this.username,
    this.name,
    required this.avatarTemplate,
  });

  factory VotedUser.fromJson(Map<String, dynamic> json) {
    return VotedUser(
      id: json['id'] as int,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String? ?? '',
    );
  }

  String getAvatarUrl({int size = 40}) {
    return UrlHelper.resolveAvatarUrl(avatarTemplate: avatarTemplate, size: size);
  }
}
