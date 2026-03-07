import '../utils/time_utils.dart';

class InviteLinkResponse {
  final String inviteLink;
  final InviteLinkDetails? invite;

  const InviteLinkResponse({
    required this.inviteLink,
    this.invite,
  });

  factory InviteLinkResponse.fromJson(Map<String, dynamic> json) {
    return InviteLinkResponse(
      inviteLink: json['invite_link'] as String? ?? '',
      invite: json['invite'] is Map<String, dynamic>
          ? InviteLinkDetails.fromJson(json['invite'] as Map<String, dynamic>)
          : null,
    );
  }
}

class InviteLinkDetails {
  final int? id;
  final String? inviteKey;
  final int? maxRedemptionsAllowed;
  final int? redemptionCount;
  final bool? expired;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  const InviteLinkDetails({
    this.id,
    this.inviteKey,
    this.maxRedemptionsAllowed,
    this.redemptionCount,
    this.expired,
    this.createdAt,
    this.expiresAt,
  });

  factory InviteLinkDetails.fromJson(Map<String, dynamic> json) {
    return InviteLinkDetails(
      id: json['id'] as int?,
      inviteKey: json['invite_key'] as String?,
      maxRedemptionsAllowed: json['max_redemptions_allowed'] as int?,
      redemptionCount: json['redemption_count'] as int?,
      expired: json['expired'] as bool?,
      createdAt: TimeUtils.parseUtcTime(json['created_at'] as String?),
      expiresAt: TimeUtils.parseUtcTime(json['expires_at'] as String?),
    );
  }
}
