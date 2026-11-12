import 'metaverse_checkout_types.dart';

/// 由可信宿主保存的服务会话。查询和建单授权彼此独立。
/// 此对象及其序列化内容不交给插件脚本。
class MetaverseServiceSession {
  MetaverseServiceSession(
    this.token, {
    Iterable<String> queryUrls = const [],
    this.checkout,
  }) : queryUrls = Set.unmodifiable(queryUrls);

  final String token;
  final Set<String> queryUrls;
  final MetaverseCheckoutGrant? checkout;

  Map<String, Object> toJson() => {
    'token': token,
    'queries': queryUrls.toList(),
    if (checkout != null) 'checkout': checkout!.toJson(),
  };

  static MetaverseServiceSession? parse(Object? value) {
    if (value case {'token': final String token, 'queries': final List urls}
        when token.isNotEmpty && urls.every((u) => u is String)) {
      return MetaverseServiceSession(
        token,
        queryUrls: urls.cast<String>(),
        checkout: MetaverseCheckoutGrant.parse(value['checkout']),
      );
    }
    return null;
  }
}
