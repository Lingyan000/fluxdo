import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/modules/cdk/models/cdk_models.dart';
import 'package:fluxdo/modules/cdk/services/cdk_client.dart';
import 'package:fluxdo/modules/cdk/services/cdk_redemption.dart';
import 'package:fluxdo/services/network/exceptions/oauth_exception.dart';

import 'cdk_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CdkFixture api;
  late CdkRedemption flow;
  setUp(() {
    api = CdkFixture();
    flow = CdkRedemption(api.client, 'project-1');
  });
  tearDown(() {
    flow.dispose();
    api.client.dispose();
  });

  test('未验证不能领取，免费领取只提交一次且无支付请求', () async {
    await flow.load();
    await flow.receive('');
    expect(api.requests.where((r) => r.method == 'POST'), isEmpty);
    await flow.receive('fixture-token');
    await flow.receive('fixture-token');
    expect(api.verificationCount, 1);
    expect(flow.delivered, isTrue);
    final writes = api.requests.where((r) => r.method == 'POST').toList();
    expect(writes, hasLength(1));
    expect(writes.single.data, {'captcha_token': 'fixture-token'});
    expect(writes.single.headers['Origin'], CdkClient.origin);
    expect(writes.single.extra['skipRedirect'], isTrue);
  });
  test('付费领取仅建单，LDC 支付提交后等待 CDK 实际交付', () async {
    api.paid = true;
    await flow.load();
    await flow.receive('fixture-token');
    expect(flow.payment!.reference, 'CDK20260101');
    expect(flow.delivered, isFalse);
    flow.markPaymentSubmitted();
    await flow.load();
    expect(flow.delivered, isFalse);
    expect(flow.canReceive, isFalse);
    api.received = true;
    await flow.load();
    expect(flow.delivered, isTrue);
    expect(flow.payment, isNull);
  });
  test('库存为零时仍恢复原待付款单，不再次提交领取', () async {
    api.paid = true;
    api.stock = 0;
    api.hasPending = true;
    await flow.load();
    expect(flow.payment, isNotNull);
    expect(flow.canReceive, isFalse);
    expect(api.requests.every((r) => r.method == 'GET'), isTrue);
  });
  test('领取超时不重放，刷新未确认时仍阻止第二次领取', () async {
    await flow.load();
    api.timeout = true;
    await flow.receive('fixture-token');
    expect(flow.uncertain, isTrue);
    await flow.load();
    await flow.receive('fixture-token-2');
    expect(api.requests.where((r) => r.method == 'POST'), hasLength(1));
    api.received = true;
    await flow.load();
    expect(flow.delivered, isTrue);
    expect(flow.uncertain, isFalse);
  });
  test('并发领取和账号变更不多次提交，旧账号结果不返回', () async {
    await flow.load();
    api.hold = Completer();
    api.entered = Completer();
    final first = flow.receive('fixture-token');
    await api.entered!.future;
    await flow.receive('fixture-token');
    api.active = false;
    api.hold!.complete();
    await first;
    expect(flow.content, isNull);
    expect(flow.error, isA<StateError>());
    expect(api.requests.where((r) => r.method == 'POST'), hasLength(1));
  });
  test('401 保留重新授权语义，资格拒绝显示服务端原因', () async {
    api.status = 401;
    await expectLater(
      api.client.project('project-1'),
      throwsA(isA<OAuthExpiredException>()),
    );
    api.status = 403;
    api.errorMessage = '信任等级不足';
    await expectLater(
      api.client.project('project-1'),
      throwsA(
        isA<CdkApiException>().having((e) => e.message, 'reason', '信任等级不足'),
      ),
    );
  });
  test('列表真实分页，历史搜索与趋势参数传入服务端', () async {
    expect((await api.client.projects()).items, hasLength(20));
    expect((await api.client.projects(page: 2, tag: '工具')).items, hasLength(1));
    expect(api.requests.last.queryParameters, {
      'current': 2,
      'size': 20,
      'tags': '工具',
    });
    await api.client.receipts(search: 'creator');
    expect(api.requests.last.queryParameters['search'], 'creator');
    expect((await api.client.dashboard()).summary['totalReceived'], 5480);
    expect(await api.client.history(days: 7), hasLength(7));
  });
  test('支付域名、金额、原订单号不一致时拒绝', () {
    for (final changed in [
      {...cdkPending(), 'amount': '12.51'},
      {...cdkPending(), 'out_trade_no': 'different'},
      {
        ...cdkPending(),
        'pay_url': 'https://credit.linux.do.evil.test/epay/pay/submit.php?out_trade_no=a&money=12.50',
      },
      {
        ...cdkPending(),
        'pay_url': '${cdkPending()['pay_url']}&out_trade_no=other',
      },
    ]) {
      expect(() => CdkPaymentIntent.fromJson(changed), throwsFormatException);
    }
  });
  test('错误项目路径和空验证码在网络请求前拒绝', () async {
    await expectLater(
      api.client.project('../oauth/logout'),
      throwsFormatException,
    );
    await expectLater(
      api.client.receive('project-1', ''),
      throwsA(isA<CdkApiException>()),
    );
    expect(api.requests, isEmpty);
  });
  test('读取失败后不使用旧资格开放领取', () async {
    await flow.load();
    expect(flow.canReceive, isTrue);
    api.status = 500;
    await flow.load();
    expect(flow.canReceive, isFalse);
    expect(flow.error, isA<DioException>());
  });
}
