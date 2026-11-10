import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  late LinuxInAppWebViewController controller;
  ServerTrustChallenge? received;
  ServerTrustAuthResponse? response;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    received = null;
    response = ServerTrustAuthResponse(
      action: ServerTrustAuthResponseAction.CANCEL,
    );
    controller = LinuxInAppWebViewController(
      PlatformInAppWebViewControllerCreationParams(
        id: 'trust-test',
        webviewParams: PlatformWebViewCreationParams(
          onReceivedServerTrustAuthRequest: (_, challenge) async {
            received = challenge;
            return response;
          },
        ),
      ),
    );
  });

  tearDown(() {
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  Future<dynamic> send(Map<String, dynamic>? error) async {
    final result = Completer<dynamic>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'com.pichillilorenzo/flutter_inappwebview_trust-test',
      codec.encodeMethodCall(
        MethodCall('onReceivedServerTrustAuthRequest', {
          'protectionSpace': {
            'host': 'example.test',
            'port': 8443,
            'protocol': 'https',
            'authenticationMethod': 'NSURLAuthenticationMethodServerTrust',
            'sslCertificate': null,
            'sslError': error,
          },
        }),
      ),
      (data) {
        try {
          result.complete(data == null ? null : codec.decodeEnvelope(data));
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      },
    );
    return result.future;
  }

  for (final entry in {
    'NOT_YET_VALID': SslErrorType.NOT_YET_VALID,
    'EXPIRED': SslErrorType.EXPIRED,
    'IDMISMATCH': SslErrorType.IDMISMATCH,
    'UNTRUSTED': SslErrorType.UNTRUSTED,
    'REVOKED': SslErrorType.REVOKED,
    'INVALID': SslErrorType.INVALID,
    'INSECURE': SslErrorType.INVALID,
    'FUTURE_ERROR': SslErrorType.INVALID,
    null: SslErrorType.INVALID,
  }.entries) {
    test('decodes WPE ${entry.key} and returns CANCEL', () async {
      expect(await send({'code': entry.key, 'message': 'TLS diagnostic'}), {
        'action': 0,
      });
      final space = received!.protectionSpace;
      expect(space.sslError!.code, entry.value);
      expect(space.sslError!.message, 'TLS diagnostic');
      expect(space.host, 'example.test');
      expect(space.port, 8443);
      expect(space.protocol, 'https');
      expect(
        space.authenticationMethod,
        URLProtectionSpaceAuthenticationMethod
            .NSURL_AUTHENTICATION_METHOD_SERVER_TRUST,
      );
    });
  }

  test(
    'returns PROCEED only when the application explicitly chooses it',
    () async {
      response = ServerTrustAuthResponse(
        action: ServerTrustAuthResponseAction.PROCEED,
      );
      expect(await send({'code': 'UNTRUSTED'}), {'action': 1});
    },
  );

  test('preserves absent error and a null callback response', () async {
    response = null;
    expect(await send(null), isNull);
    expect(received!.protectionSpace.sslError, isNull);
  });
}
