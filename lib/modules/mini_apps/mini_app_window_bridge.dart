import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

import '../../constants.dart';
import '../../providers/core_providers.dart';
import '../../services/auth_session.dart';
import '../../services/network/cookie/webview_cookie_priming.dart';
import '../../services/network/doh/network_settings_service.dart';
import '../../services/network/core/net_core_bindings.dart';
import '../../services/windows_webview_environment_service.dart';
import 'mini_app.dart';
import 'mini_app_engine.dart';
import 'mini_app_launch_report.dart';
import 'mini_app_runtime_cache.dart';
import '../../services/log/log_writer.dart';
import 'mini_app_providers.dart';
import 'mini_app_task_icon.dart';
import 'mini_app_url.dart';
import 'mini_app_window_session.dart';

class _WindowSession {
  _WindowSession(
    this.details,
    this.entry,
    this.container,
    this.community,
    this.engine,
  );
  final MiniAppEngine engine;
  final MiniAppDetails details;
  Uri entry;
  final ProviderContainer container;
  final Future<void> Function(String) community;
  final generation = AuthSession().generation;
  final key = const Uuid().v4();
  final launchClock = Stopwatch()..start();
  WindowController? window;
  final ready = Completer<void>();
}

/// 系统宿主只管理窗口。资料与操作通过主引擎认证、限域并回传结果。
class MiniAppWindowBridge {
  static const channel = MethodChannel('com.fluxdo/mini_app_windows');
  static const desktopChannel = WindowMethodChannel(
    'com.fluxdo/mini_app_host',
    mode: ChannelMode.unidirectional,
  );
  static final updates = StreamController<String>.broadcast();
  static final _sessions = <String, _WindowSession>{};
  static final _opening = <String, Future<bool>>{};
  static Future<void>? _initialized;
  static bool get desktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<void> _initialize() async {
    AuthSession().generationChanges.addListener(_invalidate);
    if (desktop) {
      // 0.3.1 只在首次 invokeMethod 时安装 Dart 接收器；仅注册 handler
      // 会让第一个子窗口的 bootstrap 永久等候。先激活传输再注册宿主。
      try {
        await desktopChannel.invokeMethod<void>('ping');
      } catch (_) {}
      await desktopChannel.setMethodCallHandler(_handle);
      onWindowsChanged.listen((_) async {
        final live = (await WindowController.getAll())
            .map((w) => w.windowId)
            .toSet();
        for (final s in _sessions.values.toList()) {
          if (s.window != null && !live.contains(s.window!.windowId)) {
            _sessions.remove(s.details.app.id);
            updates.add(s.details.app.id);
          }
        }
      });
    } else {
      channel.setMethodCallHandler(_handle);
    }
  }

  static Future<bool> open(
    MiniAppDetails details,
    Uri uri, {
    required ProviderContainer container,
    required Future<void> Function(String) community,
    Brightness iconBrightness = Brightness.light,
    MiniAppEngine engine = MiniAppEngine.lightweight,
  }) {
    final id = details.app.id;
    return _opening.putIfAbsent(
      id,
      () => _open(details, uri, container, community, iconBrightness, engine)
          .whenComplete(() {
            _opening.remove(id);
          }),
    );
  }

  static Future<bool> _open(
    MiniAppDetails details,
    Uri uri,
    ProviderContainer container,
    Future<void> Function(String) community,
    Brightness iconBrightness,
    MiniAppEngine engine,
  ) async {
    await (_initialized ??= _initialize());
    final entry = MiniAppUrl.embed(
      uri.toString(),
      details.app.id,
      AppConstants.baseUrl,
    );
    final s = _sessions.putIfAbsent(
      details.app.id,
      () => _WindowSession(details, entry, container, community, engine),
    );
    s.entry = entry;
    try {
      // 先创建加载窗口；运行页在 WebView 创建后通过 prime 请求对齐 Cookie，
      // 不在这里重复同步并阻塞子引擎启动。
      if (!AuthSession().isValid(s.generation)) {
        throw StateError('Session changed');
      }
      if (desktop) {
        if (s.window != null) {
          await s.ready.future.timeout(const Duration(seconds: 20));
          if (!AuthSession().isValid(s.generation)) return false;
          await s.window!.invokeMethod('activate', entry.toString());
        } else {
          s.window = await WindowController.create(
            WindowConfiguration(
              hiddenAtLaunch: true,
              arguments: jsonEncode({'type': 'miniApp', 'key': s.key}),
            ),
          );
          LogWriter.instance.write({
            'type': 'mini_app',
            'event': 'mini_app_window_created',
            'level': 'info',
            'appId': details.app.id,
            'engine': engine.name,
            'elapsedMs': s.launchClock.elapsedMilliseconds,
            'buildMode': kDebugMode
                ? 'debug'
                : (kProfileMode ? 'profile' : 'release'),
          });
        }
        if (!AuthSession().isValid(s.generation)) {
          await s.window?.invokeMethod('revoke');
          return false;
        }
        return true;
      }
      final opened = await channel.invokeMethod<bool>('open', {
        'id': details.app.id,
        'name': details.app.name,
        'url': entry.toString(),
        'key': s.key,
      });
      if (opened != true) {
        _sessions.remove(details.app.id);
      } else if (Platform.isAndroid) {
        // 图标下载不能阻塞窗口首帧；全屏打开也不依赖工具栏截图。
        unawaited(_updateTaskIcon(s, iconBrightness));
      }
      return opened == true;
    } catch (_) {
      if (identical(_sessions[details.app.id], s)) {
        _sessions.remove(details.app.id);
      }
      rethrow;
    }
  }

  static Future<void> _updateTaskIcon(
    _WindowSession session,
    Brightness brightness,
  ) async {
    final icon = await MiniAppTaskIcon.load(
      session.details.app.iconUrl,
      brightness,
    );
    final id = session.details.app.id;
    if (icon == null ||
        !identical(_sessions[id], session) ||
        !AuthSession().isValid(session.generation)) {
      return;
    }
    try {
      await channel.invokeMethod<void>('updateIcon', {
        'id': id,
        'key': session.key,
        'icon': icon,
      });
    } catch (_) {
      // 关闭或注销后的迟到图片不能恢复旧任务。
    }
  }

  static Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'updated' && call.arguments is String) {
      updates.add(call.arguments as String);
      return null;
    }
    final args = miniAppWindowMap(call.arguments);
    final matches = _sessions.values.where((s) => s.key == args['key']);
    if (matches.isEmpty) throw PlatformException(code: 'SESSION_REVOKED');
    final s = matches.first;
    if (call.method == 'closed') {
      _sessions.remove(s.details.app.id);
      updates.add(s.details.app.id);
      return null;
    }
    if (!AuthSession().isValid(s.generation)) {
      throw PlatformException(code: 'SESSION_REVOKED');
    }
    final service = s.container.read(miniAppServiceProvider);
    final id = s.details.app.id;
    final body = miniAppWindowMap(args['args'] ?? {});
    // 操作的应用、地址和运行版本由主引擎决定，子窗口不可指定任意 HTTP 请求。
    try {
      Object? value;
      switch (call.method) {
        case 'ping':
          return true;
        case 'bootstrap':
          if (!s.ready.isCompleted) s.ready.complete();
          final user = s.container.read(currentUserProvider).value;
          return {
            'details': s.details.toJson(),
            'engine': s.engine.name,
            'entry': s.entry.toString(),
            'user': user == null
                ? null
                : {
                    'id': user.id,
                    'username': user.username,
                    'name': user.name,
                    'avatar_template': user.avatarTemplate,
                  },
            'userAgent': AppConstants.webViewUserAgentOverride,
            'proxy': WindowsWebViewEnvironmentService.instance.activeProxyUrl,
          };
        case 'prime':
          await WebViewCookiePriming.instance.prime(s.entry.toString());
          return null;
        case 'runtimeAsset':
          final result = await MiniAppRuntimeCache.instance.handle(body);
          return AuthSession().isValid(s.generation) ? result : null;
        case 'verifyCertificate':
          return NetworkSettingsService.instance.webViewUsesCoreMitm &&
              NetCoreBindings.instance.verifyWebViewCertificate(
                Uint8List.fromList((body['der'] as List).cast<int>()),
                body['host'] as String,
              );
        case 'record':
          s.container.read(miniAppRecentsProvider).record(s.details.app);
          return null;
        case 'launchReport':
          final entry = MiniAppLaunchReport.fromWindow(body, id);
          if (entry == null) {
            throw const FormatException('Invalid launch report');
          }
          LogWriter.instance.write({
            ...entry,
            'windowElapsedMs': s.launchClock.elapsedMilliseconds,
            'buildMode': kDebugMode
                ? 'debug'
                : (kProfileMode ? 'profile' : 'release'),
          });
          return null;
        case 'community':
          final path = body['path'] as String;
          if (!RegExp(r'^/(t/\d+|u/[^/?#]+)$').hasMatch(path)) {
            throw const FormatException('Invalid community link');
          }
          await s.community(path);
          if (desktop) {
            await windowManager.show();
            await windowManager.focus();
          }
          return null;
        case 'details':
          if (body['id'] != id) throw const FormatException('App mismatch');
          value = (await service.details(id)).toJson();
        case 'favorite':
          value = await service.favorite(s.details, body['value'] as bool);
        case 'rate':
          await service.rate(s.details, body['score'] as int);
        case 'tipStatus':
          value = await service.tipStatus(s.details);
        case 'tip':
          value = await service.tip(
            s.details,
            body['amount'] as int,
            body['requestId'] as String,
          );
        case 'reportTypes':
          value = await service.reportTypes();
        case 'report':
          if (body['releaseId'] != s.details.feedback['release_id']) {
            throw const FormatException('Release mismatch');
          }
          await service.report(
            s.details,
            body['flagType'] as int,
            body['message'] as String,
          );
        default:
          throw MissingPluginException(call.method);
      }
      if (!AuthSession().isValid(s.generation)) {
        throw PlatformException(code: 'SESSION_REVOKED');
      }
      if ({'favorite', 'rate', 'tip', 'report'}.contains(call.method)) {
        updates.add(id);
      }
      return {'value': value};
    } on DioException catch (e) {
      // 保留业务错误码供原评分/打赏面板显示，不传请求头和凭据。
      return {
        'error': {
          'status': e.response?.statusCode,
          'data': e.response?.data,
          'message': e.message,
        },
      };
    }
  }

  static void _invalidate() {
    final old = _sessions.values.toList();
    _sessions.clear();
    if (!desktop) {
      unawaited(channel.invokeMethod<void>('invalidate').catchError((_) {}));
    }
    for (final s in old) {
      if (!s.ready.isCompleted) s.ready.complete();
      unawaited(
        s.window?.invokeMethod('revoke').catchError((_) => null) ??
            Future.value(),
      );
    }
  }
}
