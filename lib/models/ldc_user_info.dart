class LdcUserInfo {
  final int id;
  final String username;
  final String nickname;
  final int trustLevel;
  final String avatarUrl;
  final String totalReceive;
  final String totalPayment;
  final String totalTransfer;
  final String totalCommunity;
  final String communityBalance;
  final String availableBalance;
  final int payScore;
  final bool isPayKey;
  final bool isAdmin;
  final String remainQuota;
  final int payLevel;

  /// null 表示不限额，与 LDC 接口保持一致。
  final int? dailyLimit;

  LdcUserInfo({
    required this.id,
    required this.username,
    required this.nickname,
    required this.trustLevel,
    required this.avatarUrl,
    required this.totalReceive,
    required this.totalPayment,
    required this.totalTransfer,
    required this.totalCommunity,
    required this.communityBalance,
    required this.availableBalance,
    required this.payScore,
    required this.isPayKey,
    required this.isAdmin,
    required this.remainQuota,
    required this.payLevel,
    required this.dailyLimit,
  });

  factory LdcUserInfo.fromJson(Map<String, dynamic> json) {
    return LdcUserInfo(
      // 上游以字符串返回 ID，同时兼容旧接口和本地缓存中的整数。
      id: json['id'] is String
          ? int.parse(json['id'] as String)
          : json['id'] as int,
      username: json['username'] as String,
      nickname: json['nickname'] as String,
      trustLevel: json['trust_level'] as int,
      avatarUrl: json['avatar_url'] as String,
      totalReceive: json['total_receive'] as String,
      totalPayment: json['total_payment'] as String,
      totalTransfer: json['total_transfer'] as String,
      totalCommunity: json['total_community'] as String,
      communityBalance: json['community_balance'] as String,
      availableBalance: json['available_balance'] as String,
      payScore: json['pay_score'] as int,
      isPayKey: json['is_pay_key'] as bool,
      isAdmin: json['is_admin'] as bool,
      remainQuota: json['remain_quota'] as String,
      payLevel: json['pay_level'] as int,
      dailyLimit: json['daily_limit'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'nickname': nickname,
      'trust_level': trustLevel,
      'avatar_url': avatarUrl,
      'total_receive': totalReceive,
      'total_payment': totalPayment,
      'total_transfer': totalTransfer,
      'total_community': totalCommunity,
      'community_balance': communityBalance,
      'available_balance': availableBalance,
      'pay_score': payScore,
      'is_pay_key': isPayKey,
      'is_admin': isAdmin,
      'remain_quota': remainQuota,
      'pay_level': payLevel,
      'daily_limit': dailyLimit,
    };
  }
}
