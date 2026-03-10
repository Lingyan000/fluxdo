import '../utils/time_utils.dart';

class InviteLinkResponse {
  final String inviteLink;
  final InviteLinkDetails? invite;

  const InviteLinkResponse({
    required this.inviteLink,
    this.invite,
  });

  factory InviteLinkResponse.fromJson(Map<String, dynamic> json) {
    final linkValue =
        json['invite_link'] ??
        json['invite_url'] ??
        json['url'] ??
        json['link'];
    final inviteLink = linkValue is String ? linkValue : '';
    InviteLinkDetails? invite;
    final inviteJson = json['invite'];
    if (inviteJson is Map<String, dynamic>) {
      invite = InviteLinkDetails.fromJson(inviteJson);
    } else if (json.containsKey('invite_key') ||
        json.containsKey('expires_at') ||
        json.containsKey('max_redemptions_allowed')) {
      invite = InviteLinkDetails.fromJson(json);
    }
    return InviteLinkResponse(
      inviteLink: inviteLink,
      invite: invite,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'invite_link': inviteLink,
      if (invite != null) 'invite': invite!.toJson(),
    };
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

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      if (inviteKey != null) 'invite_key': inviteKey,
      if (maxRedemptionsAllowed != null)
        'max_redemptions_allowed': maxRedemptionsAllowed,
      if (redemptionCount != null) 'redemption_count': redemptionCount,
      if (expired != null) 'expired': expired,
      if (createdAt != null) 'created_at': createdAt!.toUtc().toIso8601String(),
      if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
    };
  }
}
