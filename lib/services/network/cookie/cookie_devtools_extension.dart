import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'cookie_full_info.dart';
import 'cookie_jar_service.dart';
import 'raw_cookie_writer.dart';
import 'session_cookie_sentinel.dart';
import 'webview_cookie_priming.dart';

/// Cookie 引擎的 DevTools service extension 桥。
///
/// 注册 6 类 `ext.fluxdo.cookie.*` service extensions 供
/// `extension/devtools/` 子 app（Flutter DevTools Extension）通过
/// vm_service 调用。
///
/// 仅在 debug / profile mode 注册（release mode 下 dart:developer
/// 编译期被剔除，零开销且安全）。
///
/// 设计依据：`docs/cookie-sync-design-v0.4.0.md` §11.4
///
/// Phase 6a 实现 service extension; Phase 6b 实现 DevTools extension UI。
class CookieDevtoolsExtension {
  CookieDevtoolsExtension._();
  static final CookieDevtoolsExtension instance = CookieDevtoolsExtension._();

  static const String _prefix = 'ext.fluxdo.cookie';

  /// SweepEvent 桥接订阅，登出时 cancel 避免泄漏（实际上 Sentinel 是单例，
  /// 主进程生命周期内只订阅一次）。
  StreamSubscription<SweepEvent>? _sweepEventSub;
  bool _registered = false;

  /// 在 main 启动早期（CookieJarService.initialize 之后）调用一次。
  /// 重复调用幂等。
  void register() {
    if (_registered) return;
    _registered = true;

    developer.registerExtension('$_prefix.dump', _handleDump);
    developer.registerExtension('$_prefix.sweep', _handleSweep);
    developer.registerExtension(
      '$_prefix.nuclearReset',
      _handleNuclearReset,
    );
    developer.registerExtension(
      '$_prefix.invalidatePriming',
      _handleInvalidatePriming,
    );
    developer.registerExtension('$_prefix.config', _handleConfig);
    developer.registerExtension('$_prefix.criticalNames', _handleCriticalNames);

    // 桥接 SweepEvent 到 developer.postEvent (DevTool 可订阅)
    _sweepEventSub = SessionCookieSentinel.instance.events.listen(_postSweepEvent);

    debugPrint('[CookieDevtoolsExtension] 已注册 6 个 service extensions');
  }

  /// 测试用：取消订阅。
  @visibleForTesting
  void disposeForTest() {
    _sweepEventSub?.cancel();
    _sweepEventSub = null;
    _registered = false;
  }

  // ---------------------------------------------------------------------------
  // Service extension handlers
  // ---------------------------------------------------------------------------

  /// `ext.fluxdo.cookie.dump` — 返回 jar + WV cookie 完整快照。
  ///
  /// 可选参数 `url`：默认为 `AppConstants.baseUrl`。
  Future<developer.ServiceExtensionResponse> _handleDump(
    String method,
    Map<String, String> parameters,
  ) async {
    try {
      final url = parameters['url'] ?? _defaultUrl();
      final data = await _dump(url);
      return _okResult(data);
    } catch (e, s) {
      return _errorResult('dump failed: $e\n$s');
    }
  }

  /// `ext.fluxdo.cookie.sweep` — 手动触发 sweep。
  ///
  /// 参数：
  /// - `url` (必填)：sweep 作用的 URL
  /// - `name` (必填)：cookie 名（必须 ∈ criticalCookieNames）
  /// - `intent` (可选)：`ensureUnique` (默认) | `delete`
  Future<developer.ServiceExtensionResponse> _handleSweep(
    String method,
    Map<String, String> parameters,
  ) async {
    try {
      final url = parameters['url'];
      final name = parameters['name'];
      if (url == null || name == null) {
        return _errorResult('url and name are required');
      }
      final intentStr = parameters['intent'] ?? 'ensureUnique';
      final intent = intentStr == 'delete'
          ? SweepIntent.delete
          : SweepIntent.ensureUnique;
      final result = await SessionCookieSentinel.instance.sweep(
        url,
        name,
        intent: intent,
      );
      return _okResult({
        'name': result.name,
        'status': result.status.name,
        'variantsBefore': result.variantsBefore,
        'variantsAfter': result.variantsAfter,
        'winnerSource': result.winnerSource,
        'elapsedMs': result.elapsed.inMilliseconds,
      });
    } catch (e, s) {
      return _errorResult('sweep failed: $e\n$s');
    }
  }

  /// `ext.fluxdo.cookie.nuclearReset` — 手动触发 Nuclear Reset。
  Future<developer.ServiceExtensionResponse> _handleNuclearReset(
    String method,
    Map<String, String> parameters,
  ) async {
    try {
      final url = parameters['url'] ?? _defaultUrl();
      final result = await SessionCookieSentinel.instance.nuclearReset(url);
      return _okResult({
        'success': result.success,
        'elapsedMs': result.elapsed.inMilliseconds,
        'primingDurationMs': result.primingDuration?.inMilliseconds,
        'error': result.error?.toString(),
      });
    } catch (e, s) {
      return _errorResult('nuclearReset failed: $e\n$s');
    }
  }

  /// `ext.fluxdo.cookie.invalidatePriming` — 强制 Priming 重新执行。
  Future<developer.ServiceExtensionResponse> _handleInvalidatePriming(
    String method,
    Map<String, String> parameters,
  ) async {
    try {
      WebViewCookiePriming.instance.invalidate();
      return _okResult({'invalidated': true});
    } catch (e, s) {
      return _errorResult('invalidatePriming failed: $e\n$s');
    }
  }

  /// `ext.fluxdo.cookie.config` — 当前配置 / 状态。
  Future<developer.ServiceExtensionResponse> _handleConfig(
    String method,
    Map<String, String> parameters,
  ) async {
    try {
      return _okResult({
        'criticalNames': SessionCookieSentinel.criticalCookieNames.toList(),
        'sessionNames': CookieJarService.sessionCookieNames.toList(),
        'isPrimed': WebViewCookiePriming.instance.isPrimed,
        'jarInitialized': CookieJarService().isInitialized,
        'rawWriterSupported': RawCookieWriter.instance.isSupported,
      });
    } catch (e, s) {
      return _errorResult('config failed: $e\n$s');
    }
  }

  /// `ext.fluxdo.cookie.criticalNames` — 仅返回 critical cookie 名集合。
  Future<developer.ServiceExtensionResponse> _handleCriticalNames(
    String method,
    Map<String, String> parameters,
  ) async {
    return _okResult({
      'criticalNames': SessionCookieSentinel.criticalCookieNames.toList(),
    });
  }

  // ---------------------------------------------------------------------------
  // 数据收集
  // ---------------------------------------------------------------------------

  /// 收集 jar 和 WV 中指定 url 下 critical cookies 的完整快照。
  Future<Map<String, dynamic>> _dump(String url) async {
    final uri = Uri.parse(url);
    final jar = CookieJarService();
    final writer = RawCookieWriter.instance;

    // jar 视图
    final jarCookies = jar.isInitialized
        ? await jar.loadCanonicalCookiesForRequest(uri)
        : <dynamic>[];

    final jarSnapshot = jarCookies
        .where((c) => true)
        .map(
          (c) => {
            'name': c.name,
            'valueLength': c.value.length,
            'domain': c.domain,
            'path': c.path,
            'hostOnly': c.hostOnly,
            'secure': c.secure,
            'httpOnly': c.httpOnly,
            'expiresAt': c.expiresAt?.toIso8601String(),
            'isCritical':
                SessionCookieSentinel.criticalCookieNames.contains(c.name),
          },
        )
        .toList(growable: false);

    // WV 视图
    final wvCookieInfos = await writer.getAllCookieInfos(url);
    final wvSnapshot = wvCookieInfos
        .map((c) => _cookieInfoToMap(c))
        .toList(growable: false);

    // 按 critical name 分组统计变体数
    final criticalVariantsCount = <String, int>{};
    for (final name in SessionCookieSentinel.criticalCookieNames) {
      final count = await writer.countCookiesByName(url, name);
      criticalVariantsCount[name] = count;
    }

    return {
      'url': url,
      'timestamp': DateTime.now().toIso8601String(),
      'jar': {
        'initialized': jar.isInitialized,
        'cookies': jarSnapshot,
      },
      'webview': {
        'cookies': wvSnapshot,
        'criticalVariantsCount': criticalVariantsCount,
      },
      'priming': {
        'isPrimed': WebViewCookiePriming.instance.isPrimed,
      },
    };
  }

  Map<String, dynamic> _cookieInfoToMap(CookieFullInfo c) => {
        'name': c.name,
        'valueLength': c.value.length,
        'domain': c.domain,
        'path': c.path,
        'hostOnly': c.isHostOnly,
        'secure': c.isSecure,
        'httpOnly': c.isHttpOnly,
        'expiresMillis': c.expiresMillis,
        'isCritical':
            SessionCookieSentinel.criticalCookieNames.contains(c.name),
      };

  // ---------------------------------------------------------------------------
  // 事件桥接
  // ---------------------------------------------------------------------------

  /// 把 SweepEvent 转发到 dart:developer postEvent，供 DevTool 监听。
  ///
  /// DevTool 端通过 `eventStream.where((e) => e.event == 'fluxdo.cookie.sweepEvent')` 监听。
  void _postSweepEvent(SweepEvent event) {
    final payload = <String, dynamic>{
      'type': event.runtimeType.toString(),
      'timestamp': DateTime.now().toIso8601String(),
    };
    switch (event) {
      case SweepInvoked():
        payload['url'] = event.url;
        payload['name'] = event.name;
        payload['intent'] = event.intent.name;
      case SweepCompleted():
        payload['result'] = {
          'name': event.result.name,
          'status': event.result.status.name,
          'variantsBefore': event.result.variantsBefore,
          'variantsAfter': event.result.variantsAfter,
          'winnerSource': event.result.winnerSource,
          'elapsedMs': event.result.elapsed.inMilliseconds,
        };
      case SweepCancelled():
        payload['url'] = event.url;
        payload['name'] = event.name;
        payload['entryGeneration'] = event.entryGeneration;
        payload['currentGeneration'] = event.currentGeneration;
    }
    developer.postEvent('fluxdo.cookie.sweepEvent', payload);
  }

  // ---------------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------------

  String _defaultUrl() => 'https://linux.do';

  developer.ServiceExtensionResponse _okResult(Object data) {
    return developer.ServiceExtensionResponse.result(jsonEncode(data));
  }

  developer.ServiceExtensionResponse _errorResult(String message) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      jsonEncode({'error': message}),
    );
  }
}
