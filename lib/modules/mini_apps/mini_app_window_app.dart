import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../../main.dart' show MainApp;
import '../../l10n/s.dart';
import '../../models/user.dart';
import '../../providers/core_providers.dart';
import '../../providers/theme_provider.dart';
import '../../services/auth_session.dart';
import '../../services/webview_settings.dart';
import '../../services/windows_webview_environment_service.dart';
import '../../utils/time_utils.dart';
import '../../utils/image_decode_gate.dart' show FluxdoWidgetsBinding;
import 'mini_app.dart';
import 'mini_app_engine.dart';
import 'mini_app_fullscreen.dart';
import 'mini_app_providers.dart';
import 'mini_app_runner_page.dart';
import 'mini_app_url.dart';
import 'mini_app_window_bridge.dart';
import 'mini_app_window_session.dart';
import 'mini_app_window_startup.dart';

const _controls = MethodChannel('com.fluxdo/mini_app_window_controls');
const _startupTimeout = Duration(seconds: 15);

Future<void> _closeWindow() async {
  if (Platform.isWindows || !MiniAppWindowBridge.desktop) {
    await _controls.invokeMethod<void>('close');
  } else {
    await windowManager.close();
  }
}

/// 移动端自建引擎使用此入口，桌面子窗口由 main 分流至同一启动链。
@pragma('vm:entry-point')
Future<void> miniAppWindowMain() async {
  FluxdoWidgetsBinding.ensureInitialized();
  // 不等待 getLaunch、偏好或 bootstrap 才 runApp，否则异常发生在首帧之前。
  runApp(
    MiniAppWindowStartup(
      onClose: _closeWindow,
      initialize: () async {
        final key = await MiniAppWindowBridge.channel
            .invokeMethod<String>('getLaunch')
            .timeout(_startupTimeout);
        if (key == null || key.isEmpty) {
          throw PlatformException(code: 'SESSION_REVOKED');
        }
        return _initializeWindow(key, null);
      },
    ),
  );
}

class _WindowUser extends CurrentUserNotifier {
  _WindowUser(this.user);
  final User? user;
  @override
  FutureOr<User?> build() => user;
}

Future<bool> startMiniAppWindow() async {
  WindowController? desktop;
  String? key;
  if (MiniAppWindowBridge.desktop) {
    desktop = await WindowController.fromCurrentEngine();
    if (desktop.arguments.isEmpty) return false;
    final args = jsonDecode(desktop.arguments) as Map;
    if (args['type'] != 'miniApp') return false;
    key = args['key'] as String;
  } else {
    try {
      key = await MiniAppWindowBridge.channel.invokeMethod<String>('getLaunch');
    } on MissingPluginException {
      return false;
    }
    if (key == null) return false;
  }
  runApp(
    MiniAppWindowStartup(
      onClose: _closeWindow,
      initialize: () async {
        if (desktop != null) {
          // 桌面同样先展示加载首帧，初始化失败的错误页不能藏在隐藏窗口中。
          if (!Platform.isWindows) {
            await windowManager.ensureInitialized().timeout(_startupTimeout);
          }
          await WidgetsBinding.instance.waitUntilFirstFrameRasterized.timeout(
            const Duration(seconds: 2),
            onTimeout: () {},
          );
          if (Platform.isWindows) {
            await _controls.invokeMethod<void>('show').timeout(_startupTimeout);
          } else {
            await windowManager.show().timeout(_startupTimeout);
            await windowManager.focus().timeout(_startupTimeout);
          }
        }
        return _initializeWindow(key!, desktop);
      },
    ),
  );
  return true;
}

Future<Widget> _initializeWindow(
  String capability,
  WindowController? desktop,
) async {
  final session = MiniAppWindowSession((method, args) async {
    final message = {'key': capability, 'args': args};
    return MiniAppWindowBridge.desktop
        ? MiniAppWindowBridge.desktopChannel.invokeMethod(method, message)
        : MiniAppWindowBridge.channel.invokeMethod(method, message);
  });
  MiniAppWindowSession.current = session;
  final prefs = await SharedPreferences.getInstance().timeout(_startupTimeout);
  await prefs.reload().timeout(_startupTimeout);
  final locale = prefs.getString('pref_locale');
  if (locale == null || locale == 'system') {
    await LocaleSettings.useDeviceLocale().timeout(_startupTimeout);
  } else {
    await LocaleSettings.setLocaleRaw(locale).timeout(_startupTimeout);
  }
  await Future.wait([TimeUtils.initialize(), WebViewSettings.preloadPolyfill()])
      .timeout(_startupTimeout);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
      .timeout(_startupTimeout);

  if (Platform.isWindows) {
    MiniAppFullscreen.windowIsFullscreen = () async =>
        await _controls.invokeMethod<bool>('isFullscreen') ?? false;
    MiniAppFullscreen.windowSetFullscreen = (value) =>
        _controls.invokeMethod<void>('fullscreen', value);
  } else if (MiniAppWindowBridge.desktop) {
    await windowManager.ensureInitialized().timeout(_startupTimeout);
  }

  final entry = ValueNotifier<Uri?>(null);
  var revoked = false;
  Future<void> revoke() async {
    if (revoked) return;
    revoked = true;
    AuthSession().advance();
    await _closeWindow();
  }

  Future<Object?> control(MethodCall call) async {
    if (call.method == 'revoke') {
      await revoke();
      return null;
    }
    if (call.method == 'activate') {
      final value = Uri.parse(call.arguments as String);
      if (entry.value != null &&
          MiniAppUrl.appId(value) != MiniAppUrl.appId(entry.value!)) {
        return null;
      }
      entry.value = value;
      if (Platform.isWindows) {
        await _controls.invokeMethod<void>('show');
      } else if (MiniAppWindowBridge.desktop) {
        await windowManager.show();
        await windowManager.focus();
      }
    }
    return null;
  }

  if (desktop != null) {
    await desktop.setWindowMethodHandler(control).timeout(_startupTimeout);
  } else {
    MiniAppWindowBridge.channel.setMethodCallHandler(control);
  }

  final data = miniAppWindowMap(
    await session.request('bootstrap', {}).timeout(_startupTimeout),
  );
  if (revoked) throw PlatformException(code: 'SESSION_REVOKED');
  final details = MiniAppDetails.fromJson(miniAppWindowMap(data['details']));
  entry.value = Uri.parse(data['entry'] as String);
  session.userAgent = data['userAgent'] as String?;
  if (Platform.isWindows) {
    await WindowsWebViewEnvironmentService.instance
        .setProxy(data['proxy'] as String?)
        .timeout(_startupTimeout);
    await _controls
        .invokeMethod<void>('configure', details.app.name)
        .timeout(_startupTimeout);
  } else if (MiniAppWindowBridge.desktop) {
    await windowManager.setTitle(details.app.name).timeout(_startupTimeout);
    await windowManager.setSize(const Size(1000, 760)).timeout(_startupTimeout);
    await windowManager
        .setMinimumSize(const Size(420, 320))
        .timeout(_startupTimeout);
    await windowManager.center().timeout(_startupTimeout);
  }
  if (revoked) throw PlatformException(code: 'SESSION_REVOKED');
  final application = ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      currentUserProvider.overrideWith(
        () => _WindowUser(
          data['user'] == null
              ? null
              : User.fromJson(miniAppWindowMap(data['user'])),
        ),
      ),
      authStateProvider.overrideWith((ref) => const Stream<void>.empty()),
      miniAppServiceProvider.overrideWithValue(MiniAppWindowService(session)),
    ],
    child: MainApp(
      windowTitle: details.app.name,
      windowHome: ValueListenableBuilder<Uri?>(
        valueListenable: entry,
        builder: (context, uri, _) => MiniAppRunnerPage(
          key: ValueKey(uri),
          details: details,
          initialEngine: MiniAppEngine.parse(data['engine'] as String?),
          launchUri: uri,
          independentWindow: true,
          onCloseWindow: _closeWindow,
        ),
      ),
    ),
  );
  // 宿主销毁或账户撤销后不能留下可继续操作的孤儿窗口。
  var checking = false;
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    if (revoked) {
      timer.cancel();
      return;
    }
    if (checking) return;
    checking = true;
    try {
      await session.request('ping', {}).timeout(const Duration(seconds: 10));
    } catch (_) {
      timer.cancel();
      await revoke();
    } finally {
      checking = false;
    }
  });
  return application;
}
