/// 安全存储中的插件凭证。业务对象和服务授权协议不进入此模型。
class MetaverseCredential {
  const MetaverseCredential(
    this.secret, {
    required this.accountId,
    this.expiresAt,
  });
  final String secret;
  final int? accountId;
  final int? expiresAt;

  bool validFor(int? account) =>
      accountId == account &&
      (expiresAt == null ||
          expiresAt! * 1000 > DateTime.now().millisecondsSinceEpoch);

  Map<String, Object?> toJson() => {
    'secret': secret,
    'accountId': accountId,
    'expiresAt': expiresAt,
  };

  static MetaverseCredential? parse(Object? value) {
    if (value is! Map) return null;
    final secret = value['secret'];
    final account = value['accountId'];
    final expiry = value['expiresAt'];
    if (secret is! String ||
        secret.trim().isEmpty ||
        secret.length > 16384 ||
        secret.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
        (account != null && account is! int) ||
        (expiry != null && expiry is! int)) {
      return null;
    }
    return MetaverseCredential(
      secret,
      accountId: account as int?,
      expiresAt: expiry as int?,
    );
  }
}
