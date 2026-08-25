import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/flux_request_spec.dart';

/// `FluxRequestSpec` 是请求语义的读取侧单一真相源。
///
/// 迁移期间存量调用方仍在写裸字符串字面量,新代码写 [FluxRequestKeys] 常量——
/// 两者必须指向同一个键,否则会出现"写了没生效"的静默故障。本文件锁住:
/// 键名字面量一致性、缺省语义、以及 showErrorToast 的三态判定。
void main() {
  group('键名与存量字面量一致', () {
    test('常量值就是历史字面量，保证两种写法互通', () {
      expect(FluxRequestKeys.isSilent, 'isSilent');
      expect(FluxRequestKeys.showErrorToast, 'showErrorToast');
      expect(FluxRequestKeys.priority, 'priority');
      expect(FluxRequestKeys.requestTag, 'requestTag');
      expect(FluxRequestKeys.skipCsrf, 'skipCsrf');
      expect(FluxRequestKeys.skipAuthCheck, 'skipAuthCheck');
      expect(FluxRequestKeys.skipRedirect, 'skipRedirect');
      expect(FluxRequestKeys.skipNetworkLog, 'skipNetworkLog');
      expect(FluxRequestKeys.skipSessionStateSync, 'skipSessionStateSync');
      expect(FluxRequestKeys.skipWebViewAdapter, 'skipWebViewAdapter');
      expect(FluxRequestKeys.skipRhttpAdapter, 'skipRhttpAdapter');
      expect(FluxRequestKeys.skipScheduler, 'skipScheduler');
      expect(FluxRequestKeys.allowRedirectSetCookie, 'allowRedirectSetCookie');
      expect(FluxRequestKeys.skipCfChallenge, 'skipCfChallenge');
      expect(FluxRequestKeys.skipCfBlock, 'skipCfBlock');
    });

    test('用字面量写入、用 spec 读取（存量调用方形态）', () {
      final options = _options({'isSilent': true, 'skipCsrf': true});
      expect(options.spec.isSilent, isTrue);
      expect(options.spec.skipCsrf, isTrue);
    });

    test('用常量写入、用 spec 读取（新代码形态）', () {
      final options = _options({
        FluxRequestKeys.isSilent: true,
        FluxRequestKeys.skipCsrf: true,
      });
      expect(options.spec.isSilent, isTrue);
      expect(options.spec.skipCsrf, isTrue);
    });
  });

  group('缺省语义', () {
    test('空 extra 时所有 skip/silent 标记均为 false', () {
      final spec = _options(const {}).spec;
      expect(spec.isSilent, isFalse);
      expect(spec.skipCsrf, isFalse);
      expect(spec.skipAuthCheck, isFalse);
      expect(spec.skipRedirect, isFalse);
      expect(spec.skipNetworkLog, isFalse);
      expect(spec.skipSessionStateSync, isFalse);
      expect(spec.skipWebViewAdapter, isFalse);
      expect(spec.skipRhttpAdapter, isFalse);
      expect(spec.skipScheduler, isFalse);
      expect(spec.allowRedirectSetCookie, isFalse);
      expect(spec.skipCfChallenge, isFalse);
      expect(spec.skipCfBlock, isFalse);
    });

    test('非 true 的值不被当作真（只认布尔 true）', () {
      final spec = _options(const {'isSilent': 'yes', 'skipCsrf': 1}).spec;
      expect(spec.isSilent, isFalse);
      expect(spec.skipCsrf, isFalse);
    });

    test('未指定优先级返回 null，指定后原样读出', () {
      expect(_options(const {}).spec.explicitPriority, isNull);
      expect(
        _options(const {'priority': FluxRequestPriority.low})
            .spec
            .explicitPriority,
        FluxRequestPriority.low,
      );
    });

    test('requestTag 空串按未标注处理', () {
      expect(_options(const {}).spec.requestTag, isNull);
      expect(_options(const {'requestTag': ''}).spec.requestTag, isNull);
      expect(_options(const {'requestTag': 'otp-redeem'}).spec.requestTag,
          'otp-redeem');
    });
  });

  group('showErrorToast 三态', () {
    test('未指定：hasExplicitErrorToast 为 false，由调用方按方法推导', () {
      final spec = _options(const {}).spec;
      expect(spec.hasExplicitErrorToast, isFalse);
      expect(spec.showErrorToast, isFalse);
    });

    test('显式 false 与未指定可区分（这是三态的关键）', () {
      final spec = _options(const {'showErrorToast': false}).spec;
      expect(spec.hasExplicitErrorToast, isTrue);
      expect(spec.showErrorToast, isFalse);
    });

    test('显式 true', () {
      final spec = _options(const {'showErrorToast': true}).spec;
      expect(spec.hasExplicitErrorToast, isTrue);
      expect(spec.showErrorToast, isTrue);
    });
  });
}

RequestOptions _options(Map<String, dynamic> extra) => RequestOptions(
  path: '/latest.json',
  baseUrl: 'https://linux.do',
  extra: Map<String, dynamic>.from(extra),
);
