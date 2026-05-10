import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/message_bus_service.dart';

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = null;
    MessageBusService().stopAll();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    MessageBusService().stopAll();
  });

  group('MessageBusService iOS realtime guard', () {
    test('subscribe does not start polling on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final service = MessageBusService();

      service.subscribe('/latest', (_) {});

      expect(service.isPolling, isFalse);
    });

    test('subscribeWithMessageId does not start polling on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final service = MessageBusService();

      service.subscribeWithMessageId('/notification/1', (_) {}, 42);

      expect(service.isPolling, isFalse);
    });
  });
}
