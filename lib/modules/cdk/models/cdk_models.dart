import 'dart:convert';

import '../../../services/ldc_payment_service.dart';
import '../../../utils/time_utils.dart';

Map<String, dynamic> cdkObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('CDK 响应缺少对象');
  }
  return value;
}

class CdkPage<T> {
  const CdkPage(this.items, this.total);
  final List<T> items;
  final int total;
  factory CdkPage.parse(Object? value, T Function(Map<String, dynamic>) parse) {
    final data = cdkObject(value);
    final rows = data['results'];
    if (rows != null && rows is! List) {
      throw const FormatException('CDK 分页响应无效');
    }
    return CdkPage(
      (rows as List? ?? []).map((v) => parse(cdkObject(v))).toList(),
      (data['total'] as num).toInt(),
    );
  }
}

class CdkProject {
  CdkProject.fromJson(Map<String, dynamic> data)
    : id = data['id'] as String,
      name = data['name'] as String,
      description = data['description'] as String? ?? '',
      price = '${data['price'] ?? '0'}',
      distribution = (data['distribution_type'] as num).toInt(),
      total = (data['total_items'] as num).toInt(),
      available = (data['available_items_count'] as num?)?.toInt(),
      trustLevel = (data['minimum_trust_level'] as num).toInt(),
      minimumScore = 100 - (data['risk_level'] as num).toInt(),
      allowSameIp = data['allow_same_ip'] == true,
      start = TimeUtils.parseUtcTime(data['start_time'] as String?),
      end = TimeUtils.parseUtcTime(data['end_time'] as String?),
      tags = (data['tags'] as List? ?? []).cast<String>(),
      creator = data['creator_username'] as String? ?? '',
      received = data['is_received'] == true,
      content = data['received_content'] as String? ?? '' {
    if (LdcPaymentService.amountCents(price) == null) {
      throw const FormatException('CDK 项目金额无效');
    }
  }
  final String id, name, description, price, creator, content;
  final int distribution, total, trustLevel, minimumScore;
  final int? available;
  final bool allowSameIp, received;
  final DateTime? start, end;
  final List<String> tags;
  bool get paid => LdcPaymentService.amountCents(price)! > 0;
  bool get openNow =>
      start != null &&
      end != null &&
      !DateTime.now().isBefore(start!) &&
      DateTime.now().isBefore(end!);
}

class CdkReceipt {
  CdkReceipt.fromJson(Map<String, dynamic> data)
    : projectId = data['project_id'] as String,
      name = data['project_name'] as String,
      creator = data['project_creator'] as String? ?? '',
      content = data['content'] as String,
      receivedAt = TimeUtils.parseUtcTime(data['received_at'] as String?);
  final String projectId, name, creator, content;
  final DateTime? receivedAt;
}

/// 只接受 CDK 签发的 LDC 易支付链接；最终金额和付款人还会由收银台核验。
/// 设计依据: docs/cdk-integration.md
class CdkPaymentIntent {
  CdkPaymentIntent._(this.url, this.reference, this.amount);
  final Uri url;
  final String reference, amount;
  factory CdkPaymentIntent.fromJson(Map<String, dynamic> data) {
    final uri = Uri.tryParse('${data['pay_url']}');
    final amount = '${data['amount']}';
    final reference =
        data['out_trade_no'] ?? uri?.queryParameters['out_trade_no'];
    if (uri == null ||
        uri.origin != 'https://credit.linux.do' ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        !LdcPaymentService.isSubmitPath(uri.path) ||
        reference is! String ||
        reference.isEmpty ||
        reference.length > 128 ||
        uri.queryParametersAll['out_trade_no']?.length != 1 ||
        uri.queryParameters['out_trade_no'] != reference ||
        uri.queryParametersAll['money']?.length != 1 ||
        LdcPaymentService.amountCents(amount) == null ||
        LdcPaymentService.amountCents(amount)! <= 0 ||
        LdcPaymentService.amountCents(uri.queryParameters['money']) !=
            LdcPaymentService.amountCents(amount)) {
      throw const FormatException('CDK 支付信息不一致');
    }
    return CdkPaymentIntent._(uri, reference, amount);
  }
}

class CdkReceiveResult {
  const CdkReceiveResult({this.content, this.payment});
  final String? content;
  final CdkPaymentIntent? payment;
  factory CdkReceiveResult.parse(Object? value) {
    final data = cdkObject(value);
    if (data['require_payment'] == true) {
      return CdkReceiveResult(payment: CdkPaymentIntent.fromJson(data));
    }
    if (data['itemContent'] is! String) {
      throw const FormatException('CDK 领取结果尚未确认');
    }
    return CdkReceiveResult(content: data['itemContent'] as String);
  }
}

class CdkDashboard {
  CdkDashboard.parse(Object? value) {
    final data = cdkObject(value);
    Object? field(String key) {
      final raw = data[key];
      return raw is String ? jsonDecode(raw) : raw;
    }

    summary = field('summary') == null ? {} : cdkObject(field('summary'));
    activity = (field('activityData') as List? ?? []).map(cdkObject).toList();
    tags = (field('projectTags') as List? ?? []).map(cdkObject).toList();
  }
  late final Map<String, dynamic> summary;
  late final List<Map<String, dynamic>> activity, tags;
}
