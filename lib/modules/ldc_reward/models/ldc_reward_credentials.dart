class LdcRewardCredentials {
  final String clientId;
  final String clientSecret;

  const LdcRewardCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  bool get isValid => clientId.isNotEmpty && clientSecret.isNotEmpty;
}
