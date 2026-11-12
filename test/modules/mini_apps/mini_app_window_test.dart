import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as webview;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/modules/mini_apps/mini_app.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_engine.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_providers.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_service.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_window_bridge.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_window_session.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/services/auth_session.dart';

import '../../support/cf_test_platform.dart';

const app = MiniApp(
  id: '01a1b3ac-b68b-7d49-883d-51d49c784168',
  name: '测试',
  releaseNotes: '当前版本说明',
  discussionTopicId: 42,
);
final launchDetails = MiniAppDetails(
  app,
  'https://linux.do/apps/${app.id}?embed_mode=true',
  configuration: const {'channel': 'production'},
  feedback: const {'release_id': 12, 'can_rate': true, 'can_tip': true},
);

class _Me extends CurrentUserNotifier {
  @override
  User? build() => User(id: 2, username: 'me', trustLevel: 1);
}

class _Service extends MiniAppService {
  _Service() : super(dio: Dio());
  final scores = <int>[];
  final tips = <(int, String)>[];
  @override
  Future<MiniAppDetails> details(String id) async => detailsForTest;
  MiniAppDetails get detailsForTest => launchDetails;
  @override
  Future<void> rate(MiniAppDetails details, int score) async {
    scores.add(score);
  }

  @override
  Future<Map<String, dynamic>> tip(
    MiniAppDetails details,
    int amount,
    String requestId,
  ) async {
    tips.add((amount, requestId));
    return {'success': true};
  }

  @override
  Future<bool> favorite(MiniAppDetails details, bool value) async => value;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  const windows = MethodChannel('mixin.one/desktop_multi_window');
  const channels = MethodChannel('mixin.one/desktop_multi_window/channels');

  test('完整 Flutter 窗口复用入口，通过宿主执行反馈并在账户撤销后拒绝请求', () async {
    final folder = await Directory.systemTemp.createTemp(
      'mini-app-window-test',
    );
    final platform = CfTestPlatform();
    await platform.initialize(cookieDirectory: folder.path);
    final service = _Service();
    final container = ProviderContainer(
      overrides: [
        miniAppServiceProvider.overrideWithValue(service),
        currentUserProvider.overrideWith(_Me.new),
      ],
    );
    addTearDown(container.dispose);
    final definitions = <Map<String, dynamic>>[];
    final controls = <String>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, (
      call,
    ) async {
      if (call.method == 'createWindow') {
        definitions.add(Map<String, dynamic>.from(call.arguments as Map));
        return 'child';
      }
      if (call.method == 'getAllWindows') return [];
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channels, (
      call,
    ) async {
      if (call.method == 'invokeMethod') {
        controls.add((call.arguments as Map)['method'] as String);
      }
      return null;
    });
    addTearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, null);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channels, null);
    });
    final launch = Uri.parse('${launchDetails.embedUrl}&room=42');
    final cookiesReady = Completer<List<webview.Cookie>>();
    final cookieReadStarted = Completer<void>();
    var cookieReads = 0;
    platform.cookies.readSnapshot = () {
      cookieReads++;
      if (!cookieReadStarted.isCompleted) cookieReadStarted.complete();
      return cookiesReady.future;
    };
    const rawCookies = MethodChannel('com.fluxdo/raw_cookie');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(rawCookies, (
      call,
    ) async {
      if (call.method == 'getAllCookieInfos') {
        await platform.cookies.snapshot();
        return [];
      }
      return null;
    });
    addTearDown(() {
      if (!cookiesReady.isCompleted) cookiesReady.complete([]);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(rawCookies, null);
    });
    await MiniAppWindowBridge.open(
      launchDetails,
      launch,
      engine: MiniAppEngine.lightweight,
      container: container,
      community: (_) async {},
    ).timeout(const Duration(seconds: 3));
    expect(cookieReads, 0, reason: '创建窗口不能等待 Cookie 同步');
    final arguments =
        jsonDecode(definitions.single['arguments'] as String) as Map;
    expect(arguments['type'], 'miniApp');
    expect(arguments.keys, unorderedEquals(['type', 'key']));

    Future<Object?> request(
      String method,
      Map<String, dynamic> args, {
      String? key,
    }) async {
      final done = Completer<Object?>();
      binding.defaultBinaryMessenger.handlePlatformMessage(
        channels.name,
        codec.encodeMethodCall(
          MethodCall('methodCall', {
            'channel': 'com.fluxdo/mini_app_host',
            'method': method,
            'arguments': {'key': key ?? arguments['key'], 'args': args},
          }),
        ),
        (reply) {
          try {
            done.complete(codec.decodeEnvelope(reply!));
          } catch (e, st) {
            done.completeError(e, st);
          }
        },
      );
      return done.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw StateError('窗口请求未完成: $method'),
      );
    }

    final bootstrap = miniAppWindowMap(await request('bootstrap', {}));
    expect(bootstrap['engine'], 'lightweight');
    var primed = false;
    final priming = request('prime', {}).then((_) => primed = true);
    await cookieReadStarted.future.timeout(const Duration(seconds: 3));
    expect(cookieReads, greaterThan(0));
    expect(primed, isFalse, reason: '运行页加载仍须等待 Cookie 对齐');
    cookiesReady.complete([]);
    await priming;
    platform.cookies.readSnapshot = null;
    const source = 'export const runtimeVersion = 1;';
    final hash = sha256.convert(utf8.encode(source)).toString();
    expect(
      await request('runtimeAsset', {
        'action': 'write',
        'hash': hash,
        'source': source,
      }),
      true,
    );
    expect(
      await request('runtimeAsset', {'action': 'read', 'hash': hash}),
      source,
    );
    await request('launchReport', {
      'appId': app.id,
      'engine': 'lightweight',
      'status': 'ready',
      'loaderStartMs': 40,
      'loaderDurationMs': 320,
      'packageSource': 'persistent',
    });
    await expectLater(
      request('launchReport', {
        'appId': 'other',
        'engine': 'lightweight',
        'status': 'ready',
        'loaderStartMs': 40,
        'loaderDurationMs': 320,
      }),
      throwsA(isA<PlatformException>()),
    );
    await MiniAppWindowBridge.open(
      launchDetails,
      launch,
      container: container,
      community: (_) async {},
    );
    expect(definitions, hasLength(1));
    expect(controls, contains('activate'));
    expect(bootstrap['entry'], launch.toString());
    final restored = MiniAppDetails.fromJson(
      miniAppWindowMap(bootstrap['details']),
    );
    expect(restored.app.releaseNotes, app.releaseNotes);
    expect(restored.app.discussionTopicId, 42);
    expect(restored.feedback['can_tip'], true);
    final client = MiniAppWindowService(MiniAppWindowSession(request));
    final changed = MiniAppWindowBridge.updates.stream.first;
    await client.rate(restored, 4);
    expect(await changed, app.id);
    expect(service.scores, [4]);
    await client.tip(restored, 3, 'stable-request-id');
    expect(service.tips.single, (3, 'stable-request-id'));
    expect(await client.favorite(restored, true), true);
    await expectLater(
      request('bootstrap', {}, key: 'another-window'),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      request('details', {'id': 'another-app'}),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      request('http', {'url': 'https://example.com'}),
      throwsA(anything),
    );
    await expectLater(
      request('report', {'releaseId': 99}),
      throwsA(isA<PlatformException>()),
    );
    // 关闭后立即撤销旧能力；再次打开必须建立新会话，不能复用旧版本资料。
    await request('closed', {});
    await expectLater(
      request('runtimeAsset', {'action': 'read', 'hash': hash}),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      request('bootstrap', {}),
      throwsA(isA<PlatformException>()),
    );
    await MiniAppWindowBridge.open(
      launchDetails,
      launch,
      container: container,
      community: (_) async {},
    );
    expect(definitions, hasLength(2));
    expect(
      (jsonDecode(definitions.last['arguments'] as String) as Map)['key'],
      isNot(arguments['key']),
    );
    AuthSession().advance();
    await Future<void>.delayed(Duration.zero);
    expect(controls, contains('revoke'));
    await expectLater(
      request('rate', {'score': 5}),
      throwsA(isA<PlatformException>()),
    );
    expect(service.scores, [4]);
  }, skip: Platform.isAndroid || Platform.isIOS);

  test('独立窗口保留反馈业务错误与打赏请求 ID，不自动重试写操作', () async {
    var calls = 0;
    final client = MiniAppWindowService(
      MiniAppWindowSession((method, args) async {
        calls++;
        expect(args['requestId'], 'same-id');
        return {
          'error': {
            'status': 429,
            'data': {'error': 'cooldown'},
            'message': '请稍后重试',
          },
        };
      }),
    );
    await expectLater(
      client.tip(launchDetails, 3, 'same-id'),
      throwsA(
        isA<DioException>()
            .having((e) => e.response?.statusCode, '状态码', 429)
            .having((e) => e.response?.data, '业务错误', {'error': 'cooldown'}),
      ),
    );
    expect(calls, 1);
  });
}
