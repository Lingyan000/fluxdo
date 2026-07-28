import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/qr_login_service.dart';

void main() {
  group('QrLoginService payload codec v2', () {
    final service = QrLoginService.instance;

    test('encode/parse roundtrip with expiry', () {
      final exp = DateTime.utc(2030, 1, 2, 3, 4, 5);
      final payload = QrLoginPayload(
        version: 2,
        apiKey: 'abcdef0123456789',
        otp: 'deadbeefcafebabe',
        username: 'alice',
        expiresAt: exp,
      );
      final raw = service.encodePayload(payload);
      expect(raw.startsWith('fluxdo://qr-login?'), isTrue);
      expect(raw.contains('k='), isTrue);
      expect(raw.contains('o='), isTrue);

      final parsed = service.parsePayload(raw);
      expect(parsed, isNotNull);
      expect(parsed!.version, 2);
      expect(parsed.apiKey, 'abcdef0123456789');
      expect(parsed.otp, 'deadbeefcafebabe');
      expect(parsed.username, 'alice');
      expect(parsed.expiresAt!.toUtc(), exp);
      expect(parsed.neverExpires, isFalse);
    });

    test('encode/parse never-expire (exp=0)', () {
      final payload = QrLoginPayload(
        version: 2,
        apiKey: 'key-never',
        otp: 'otp-never',
        username: 'bob',
        expiresAt: null,
      );
      final raw = service.encodePayload(payload);
      expect(raw.contains('exp=0'), isTrue);

      final parsed = service.parsePayload(raw);
      expect(parsed, isNotNull);
      expect(parsed!.neverExpires, isTrue);
      expect(parsed.expiresAt, isNull);
      expect(parsed.isExpired, isFalse);
    });

    test('reject non fluxdo scheme and v1 token payload', () {
      expect(service.parsePayload('https://linux.do/t/1'), isNull);
      expect(service.parsePayload('fluxdo://topic/1'), isNull);
      expect(service.parsePayload('not a uri'), isNull);
      // 旧 v1 `_t` 协议不再接受
      expect(
        service.parsePayload(
          'fluxdo://qr-login?v=1&t=oldtoken&u=alice&exp=9999999999999',
        ),
        isNull,
      );
    });

    test('requireValidPayload rejects expired key', () {
      final exp = DateTime.now().toUtc().subtract(const Duration(seconds: 5));
      final raw = service.encodePayload(
        QrLoginPayload(
          version: 2,
          apiKey: 'key',
          otp: 'otp',
          username: 'bob',
          expiresAt: exp,
        ),
      );
      expect(
        () => service.requireValidPayload(raw),
        throwsA(
          isA<QrLoginException>().having(
            (e) => e.error,
            'error',
            QrLoginError.expired,
          ),
        ),
      );
    });

    test('requireValidPayload rejects bad version', () {
      final raw = service.encodePayload(
        QrLoginPayload(
          version: 99,
          apiKey: 'key',
          otp: 'otp',
          username: 'bob',
          expiresAt: null,
        ),
      );
      expect(
        () => service.requireValidPayload(raw),
        throwsA(
          isA<QrLoginException>().having(
            (e) => e.error,
            'error',
            QrLoginError.unsupportedVersion,
          ),
        ),
      );
    });

    test('requireValidPayload accepts fresh never-expire payload', () {
      final raw = service.encodePayload(
        QrLoginPayload(
          version: 2,
          apiKey: 'key',
          otp: 'otp',
          username: 'bob',
          expiresAt: null,
        ),
      );
      final valid = service.requireValidPayload(raw);
      expect(valid.apiKey, 'key');
      expect(valid.otp, 'otp');
      expect(valid.isExpired, isFalse);
      expect(valid.neverExpires, isTrue);
    });

    test('requireValidPayload accepts future-dated expiry', () {
      final exp = DateTime.now().toUtc().add(const Duration(hours: 1));
      final raw = service.encodePayload(
        QrLoginPayload(
          version: 2,
          apiKey: 'key',
          otp: 'otp',
          username: 'bob',
          expiresAt: exp,
        ),
      );
      final valid = service.requireValidPayload(raw);
      expect(valid.apiKey, 'key');
      expect(valid.isExpired, isFalse);
    });
  });
}
