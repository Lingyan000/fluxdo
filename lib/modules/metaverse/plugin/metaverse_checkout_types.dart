/// 标准订单协议的两个端点。只支持确认下单和按原提交号查结果。
typedef MetaverseCheckoutEndpoints = ({String create, String lookup});

/// 由服务签发适配器提供；账号标识和计价单位不能由脚本指定。
class MetaverseCheckoutGrant {
  const MetaverseCheckoutGrant(
    this.endpoints, {
    required this.subject,
    required this.unit,
    this.displayName,
  });
  final MetaverseCheckoutEndpoints endpoints;
  final String subject;
  final String unit;
  final String? displayName;

  Map<String, Object?> toJson() => {
    'create': endpoints.create,
    'lookup': endpoints.lookup,
    'subject': subject,
    'unit': unit,
    'displayName': ?displayName,
  };

  static MetaverseCheckoutGrant? parse(Object? raw) {
    if (raw
        case {
          'create': final String create,
          'lookup': final String lookup,
          'subject': final String subject,
          'unit': final String unit,
        }
        when subject.isNotEmpty &&
            subject.length <= 160 &&
            !RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]')
                .hasMatch(subject) &&
            RegExp(r'^[A-Z0-9]{1,12}$').hasMatch(unit)) {
      return MetaverseCheckoutGrant(
        (create: create, lookup: lookup),
        subject: subject,
        unit: unit,
        displayName: raw['displayName'] is String
            ? raw['displayName'] as String
            : null,
      );
    }
    return null;
  }
}

/// 与服务端请求、持久化记录及原生确认界面共用同一份不可变意图。
class MetaverseOrderIntent {
  const MetaverseOrderIntent._(
    this.productId,
    this.quantity,
    this.expectedAmount,
    this.couponClaimId,
  );
  final String productId;
  final int quantity;
  final num expectedAmount;
  final String? couponClaimId;
  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static bool validId(Object? id) => id is String && _id.hasMatch(id);

  static MetaverseOrderIntent? parse(Map raw) {
    final id = raw['productId'],
        quantity = raw['quantity'],
        amount = raw['expectedAmount'],
        coupon = raw['couponClaimId'];
    if (!validId(id) ||
        quantity is! int ||
        quantity < 1 ||
        quantity > 5000 ||
        amount is! num ||
        !amount.isFinite ||
        amount < 0 ||
        amount > 1000000000 ||
        double.parse(amount.toStringAsFixed(2)) != amount ||
        (coupon != null && !validId(coupon))) {
      return null;
    }
    return MetaverseOrderIntent._(
      id as String,
      quantity,
      amount,
      coupon as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'productId': productId,
    'quantity': quantity,
    'expectedAmount': expectedAmount,
    if (couponClaimId != null) 'couponClaimId': couponClaimId,
  };
}
