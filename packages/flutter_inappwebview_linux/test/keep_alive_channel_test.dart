import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_linux/flutter_inappwebview_linux.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const manager = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_manager',
  );
  const nativeView = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_42',
  );
  const platformView = MethodChannel(
    'com.pichillilorenzo/custom_platform_view_42',
  );
  const events = MethodChannel(
    'com.pichillilorenzo/custom_platform_view_42_events',
  );

  testWidgets(
    'retained view uses its native channel for commands and callbacks',
    (tester) async {
      final token = InAppWebViewKeepAlive();
      final creations = <Map>[];
      final commands = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(manager, (
        call,
      ) async {
        if (call.method == 'createInAppWebView') {
          creations.add(call.arguments as Map);
          return 42; // Linux returns the retained texture ID on both mounts.
        }
        return null;
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(nativeView, (
        call,
      ) async {
        commands.add(call.method);
        return call.method == 'getUrl' ? 'https://example.test/app' : true;
      });
      for (final channel in [platformView, events]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async => null,
        );
      }
      addTearDown(() {
        for (final channel in [manager, nativeView, platformView, events]) {
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
        }
      });

      for (var mount = 0; mount < 2; mount++) {
        PlatformInAppWebViewController? controller;
        String? loadedUrl;
        final view = LinuxInAppWebViewWidget(
          PlatformInAppWebViewWidgetCreationParams(
            keepAlive: token,
            onWebViewCreated: (value) =>
                controller = value as PlatformInAppWebViewController,
            onLoadStop: (_, url) => loadedUrl = url?.toString(),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Builder(builder: view.build)),
          ),
        );
        await tester.pump();
        expect(controller, isNotNull);
        await controller!.loadData(
          data: '<title>Mini app</title>',
          baseUrl: WebUri('https://example.test/app'),
        );
        expect(await controller!.getUrl(), WebUri('https://example.test/app'));
        const codec = StandardMethodCodec();
        final reply = Completer<void>();
        await binding.defaultBinaryMessenger.handlePlatformMessage(
          nativeView.name,
          codec.encodeMethodCall(
            const MethodCall('onLoadStop', {'url': 'https://example.test/app'}),
          ),
          (_) => reply.complete(),
        );
        await reply.future;
        expect(loadedUrl, 'https://example.test/app');
        view.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
      expect(creations.map((args) => args['keepAliveId']), [
        token.id,
        token.id,
      ]);
      expect(commands, ['loadData', 'getUrl', 'loadData', 'getUrl']);
    },
  );
}
