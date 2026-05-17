import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/login_ready_coordinator.dart';

void main() {
  group('LoginReadyCoordinator', () {
    test('HTML 预加载可复用时，先复用再广播登录成功', () async {
      final events = <String>[];
      final coordinator = LoginReadyCoordinator(
        hydrateFromHtml: (html) async {
          events.add('hydrate:$html');
          return true;
        },
        refreshPreloadedData: () async {
          events.add('refresh');
        },
        notifyLoginReady: (token) {
          events.add('notify:$token');
        },
      );

      final reused = await coordinator.finalize(
        token: 'token-1',
        pageHtml: '<html />',
      );

      expect(reused, isTrue);
      expect(events, ['hydrate:<html />', 'notify:token-1']);
    });

    test('HTML 不可复用时，refresh 完成后再广播登录成功', () async {
      final events = <String>[];
      final coordinator = LoginReadyCoordinator(
        hydrateFromHtml: (html) async {
          events.add('hydrate:$html');
          return false;
        },
        refreshPreloadedData: () async {
          events.add('refresh');
        },
        notifyLoginReady: (token) {
          events.add('notify:$token');
        },
      );

      final reused = await coordinator.finalize(
        token: 'token-2',
        pageHtml: '<html />',
      );

      expect(reused, isFalse);
      expect(events, ['hydrate:<html />', 'refresh', 'notify:token-2']);
    });

    test('缺少 HTML 时，直接 refresh 后广播登录成功', () async {
      final events = <String>[];
      final coordinator = LoginReadyCoordinator(
        hydrateFromHtml: (_) async {
          events.add('hydrate');
          return true;
        },
        refreshPreloadedData: () async {
          events.add('refresh');
        },
        notifyLoginReady: (token) {
          events.add('notify:$token');
        },
      );

      final reused = await coordinator.finalize(token: 'token-3');

      expect(reused, isFalse);
      expect(events, ['refresh', 'notify:token-3']);
    });
  });
}
