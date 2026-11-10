import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/mini_apps/mini_app.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_engine.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_host_adapter.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_runner_page.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_tab_session.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:m3e_ui/m3e_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/cf_test_platform.dart';

const _id = '01a1b3ac-b68b-7d49-883d-51d49c784168';
final _entry = Uri.parse('https://linux.do/apps/$_id?embed_mode=true');
final _details = MiniAppDetails(
  const MiniApp(id: _id, name: 'Test'),
  _entry.toString(),
);
const _ready = {
  'compatible': true,
  'engineMounted': true,
  'ready': true,
  'loading': false,
  'muted': true,
};

class _Guest extends CurrentUserNotifier {
  @override
  User? build() => null;
}

class _Platform extends CfTestPlatform {
  late final _controller = _Controller(cookies);
  @override
  _Controller get controller => _controller;

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      controller;
}

class _Controller extends CfTestController {
  _Controller(super.cookies);
  Completer<Object?>? pending;
  int reads = 0;

  @override
  Future<WebUri?> getUrl() async => WebUri(_entry.toString());

  @override
  Future<void> injectCSSCode({required String source}) async {}

  @override
  Future<void> disposeKeepAlive(InAppWebViewKeepAlive keepAlive) async {}

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (source == MiniAppHostAdapter.snapshot) {
      reads++;
      return pending == null ? _ready : pending!.future;
    }
    return super.evaluateJavascript(source: source, contentWorld: contentWorld);
  }
}

void main() {
  for (final closeBeforeCompletion in [false, true]) {
    testWidgets('慢状态读取保持单个在途调用且可安全恢复/关闭 ($closeBeforeCompletion)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final previousPlatform = InAppWebViewPlatform.instance;
      final platform = _Platform();
      InAppWebViewPlatform.instance = platform;
      PlatformUtils.debugDesktopOverride = false;
      final messages = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) messages.add(message);
        previousPrint(message, wrapWidth: wrapWidth);
      };
      addTearDown(() {
        debugPrint = previousPrint;
        PlatformUtils.debugDesktopOverride = null;
        if (previousPlatform != null) {
          InAppWebViewPlatform.instance = previousPlatform;
        }
      });
      try {
        final session =
            MiniAppTabSession(
                details: _details,
                entry: _entry,
                engine: MiniAppEngine.lightweight,
              )
              ..initialLoadRequested = true
              ..recorded = true;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              currentUserProvider.overrideWith(_Guest.new),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                theme: ThemeData(extensions: const [M3eFlags()]),
                localizationsDelegates: const [
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                supportedLocales: AppLocaleUtils.supportedLocales,
                home: MiniAppRunnerPage(
                  details: _details,
                  tabSession: session,
                  initialEngine: session.engine,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        platform.webView!.params.onWebViewCreated!(platform.controller.wrapped);
        await tester.pump();
        expect(platform.controller.reads, 1);

        final pending = platform.controller.pending = Completer<Object?>();
        await tester.pump(const Duration(milliseconds: 250));
        final reads = platform.controller.reads;
        await tester.pump(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 4));
        expect(platform.controller.reads, reads, reason: '超时不能发起第二个尚未完成的 IPC');
        final reports = messages
            .where((message) => message.contains('mini_app_state_read_failed'))
            .toList();
        expect(reports, hasLength(1));
        expect(reports.single, contains('"hostReady":true'));
        expect(reports.single, contains('"operation":"evaluate_js"'));
        expect(
          messages.any(
            (message) => message.contains('mini_app_native_boot_failed'),
          ),
          false,
        );

        if (closeBeforeCompletion) await tester.pumpWidget(const SizedBox());
        platform.controller.pending = null;
        pending.complete(_ready);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
        if (!closeBeforeCompletion) {
          expect(platform.controller.reads, greaterThan(reads));
          await tester.pumpWidget(const SizedBox());
        }
        await tester.pump(const Duration(milliseconds: 1));
      } finally {
        debugPrint = previousPrint;
      }
    });
  }
}
