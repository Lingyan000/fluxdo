import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/ldc_user_info.dart';

void main() {
  const legacyUserInfo = <String, dynamic>{
    'id': 12345,
    'username': 'test_user',
    'nickname': '测试用户',
    'trust_level': 2,
    'avatar_url': 'https://linux.do/avatar.png',
    'total_receive': '100.25',
    'total_payment': '10',
    'total_transfer': '5',
    'total_community': '80.5',
    'community_balance': '80.5',
    'available_balance': '85.25',
    'pay_score': 100,
    'is_pay_key': false,
    'is_admin': false,
    'remain_quota': '1000',
    'pay_level': 0,
    'daily_limit': 1000,
  };

  group('LdcUserInfo.fromJson', () {
    test('兼容旧接口和缓存中的整数 ID', () {
      final info = LdcUserInfo.fromJson(legacyUserInfo);

      expect(info.id, 12345);
      expect(info.dailyLimit, 1000);
      expect(info.availableBalance, '85.25');
      expect(info.toJson(), legacyUserInfo);
    });

    test('支持上游接口的字符串 ID', () {
      final info = LdcUserInfo.fromJson({...legacyUserInfo, 'id': '12345'});

      expect(info.id, 12345);
      expect(info.availableBalance, '85.25');
      expect(info.communityBalance, '80.5');
    });

    test('每日限额为 null 时仍能加载余额', () {
      final info = LdcUserInfo.fromJson({
        ...legacyUserInfo,
        'daily_limit': null,
        'remain_quota': '-1',
      });

      expect(info.dailyLimit, isNull);
      expect(info.remainQuota, '-1');
      expect(info.availableBalance, '85.25');
    });

    test('新版响应写入缓存后可完整还原，保留大整数 ID 和空限额', () {
      final info = LdcUserInfo.fromJson({
        ...legacyUserInfo,
        'id': '9007199254740993',
        'daily_limit': null,
        'remain_quota': '-1',
      });
      final cached =
          jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>;
      final restored = LdcUserInfo.fromJson(cached);

      expect(restored.id, 9007199254740993);
      expect(restored.dailyLimit, isNull);
      expect(restored.availableBalance, '85.25');
      expect(restored.toJson(), info.toJson());
    });
  });
}
