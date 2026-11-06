import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../constants.dart';
import '../../network_logger.dart';
import '../../windows_webview_environment_service.dart';

/// 指纹模板采样服务。
///
/// 核心按 WebView 的指纹出站（TLS 握手、HTTP/2 早期帧、fetch 请求头）。直连模式下
/// WebView 不经过核心，模板只能靠探针采样：隐藏 WebView 访问
/// `https://localhost:<核心端口>/fluxdo-probe`，核心记录它的握手与请求特征并落盘缓存。
/// 模板缺失或采样时的 UA 与当前不符（WebView 升级过）时重新采样。
///
/// 系统代理不影响采样：核心自己跟随系统代理出站，WebView 访问 localhost 不走代理。
class FingerprintTemplateService {
  FingerprintTemplateService._();

  @visibleForTesting
  FingerprintTemplateService.forTesting({
    required Future<Map<String, dynamic>?> Function(int) status,
    required Future<void> Function(int, Future<void>) probe,
    required Future<String> Function() userAgent,
  }) : _testStatus = status,
       _testProbe = probe,
       _testUserAgent = userAgent;

  Future<Map<String, dynamic>?> Function(int)? _testStatus;
  Future<void> Function(int, Future<void>)? _testProbe;
  Future<String> Function()? _testUserAgent;

  static final FingerprintTemplateService instance =
      FingerprintTemplateService._();

  static const _probePath = '/fluxdo-probe';
  static const _probeDoneTitle = 'fluxdo-probe-done';
  static const _probeTimeout = Duration(seconds: 15);
  static const _statusTimeout = Duration(seconds: 3);

  /// 指纹模板已就绪（dio 按 WebView 指纹出站）。
  final ValueNotifier<bool> templateReady = ValueNotifier(false);

  int? _port;
  Future<void>? _inflight;
  Completer<void>? _cancelProbe;
  int _generation = 0;

  /// 核心启动后调用：检查模板，必要时采样。并发调用合并为一次。
  Future<void> ensure(int port) {
    if (_port == port && _inflight != null) return _inflight!;
    final previous = _inflight;
    _port = port;
    final generation = ++_generation;
    _cancelProbe?.complete();
    final cancel = _cancelProbe = Completer<void>();
    late final Future<void> task;
    task =
        (() async {
          // 先销毁旧探针，再启动新探针；快速切换网络也最多一个隐藏 WebView。
          if (previous != null) await previous;
          if (!_isCurrent(port, generation)) return;
          try {
            await _ensure(port, generation, cancel.future);
          } catch (error) {
            NetworkLogger.log('[Fingerprint] 模板检查失败: $error', level: 'warning');
          }
        })().whenComplete(() {
          if (identical(_inflight, task)) _inflight = null;
          if (identical(_cancelProbe, cancel)) _cancelProbe = null;
        });
    return _inflight = task;
  }

  bool _isCurrent(int port, int generation) =>
      _port == port && _generation == generation;

  /// 核心停止时撤销探针，已完成的旧任务不能覆盖新一代状态。
  void reset() {
    _port = null;
    _generation++;
    _cancelProbe?.complete();
    _cancelProbe = null;
    templateReady.value = false;
  }

  Future<void> _ensure(int port, int generation, Future<void> cancelled) async {
    var status = await _status(port);
    if (!_isCurrent(port, generation)) return;
    if (status == null) {
      templateReady.value = false;
      return;
    }
    final userAgent =
        await (_testUserAgent?.call() ?? AppConstants.getUserAgent());
    if (!_isCurrent(port, generation)) return;
    if (!status.ready || status.userAgent != userAgent) {
      templateReady.value = false;
      NetworkLogger.log(
        '[Fingerprint] ${status.ready ? 'WebView 已升级' : '模板缺失'}，开始探针采样',
      );
      final elapsed = Stopwatch()..start();
      if (_testProbe != null) {
        await _testProbe!(port, cancelled);
      } else {
        await _probe(port, cancelled);
      }
      if (!_isCurrent(port, generation)) return;
      status = await _status(port);
      NetworkLogger.log(
        '[Fingerprint] 探针采样结束，耗时 ${elapsed.elapsedMilliseconds}ms，'
        '模板${status?.ready == true ? '已就绪' : '仍未就绪'}',
        level: status?.ready == true ? 'info' : 'warning',
      );
    }
    if (_isCurrent(port, generation)) {
      templateReady.value =
          status != null && status.ready && status.userAgent == userAgent;
    }
  }

  /// 隐藏 WebView 访问探针页，等页面内 fetch 完成（标题变化）或超时。
  Future<void> _probe(int port, Future<void> cancelled) async {
    final done = Completer<void>();
    HeadlessInAppWebView? webView;
    try {
      webView = HeadlessInAppWebView(
        webViewEnvironment:
            WindowsWebViewEnvironmentService.instance.environment,
        initialUrlRequest: URLRequest(
          url: WebUri('https://localhost:$port$_probePath'),
        ),
        initialSettings: InAppWebViewSettings(
          userAgent: AppConstants.webViewUserAgentOverride,
          cacheEnabled: false,
        ),
        // 只放行核心的自签证书：限定 localhost（部分平台不提供端口，有端口时再核对）
        onReceivedServerTrustAuthRequest: (controller, challenge) async {
          final space = challenge.protectionSpace;
          final trusted =
              space.host == 'localhost' &&
              (space.port == null || space.port == port);
          return ServerTrustAuthResponse(
            action: trusted
                ? ServerTrustAuthResponseAction.PROCEED
                : ServerTrustAuthResponseAction.CANCEL,
          );
        },
        onTitleChanged: (controller, title) {
          if (title == _probeDoneTitle && !done.isCompleted) {
            done.complete();
          }
        },
      );
      await webView.run().timeout(_probeTimeout);
      await Future.any([done.future, cancelled]).timeout(_probeTimeout);
    } on TimeoutException {
      NetworkLogger.log('[Fingerprint] 探针采样超时', level: 'warning');
    } catch (e) {
      NetworkLogger.log('[Fingerprint] 探针采样失败: $e', level: 'warning');
    } finally {
      await webView?.dispose();
    }
  }

  Future<_TemplateStatus?> _status(int port) async {
    if (_testStatus != null) {
      final value = await _testStatus!(port);
      return value == null
          ? null
          : _TemplateStatus(
              ready: value['ready'] == true,
              userAgent: value['user_agent'] as String?,
            );
    }
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final request = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/__fluxdo/template'))
          .timeout(_statusTimeout);
      final response = await request.close().timeout(_statusTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_statusTimeout);
      final json = jsonDecode(body) as Map<String, dynamic>;
      return _TemplateStatus(
        ready: json['ready'] == true,
        userAgent: json['user_agent'] as String?,
      );
    } catch (e) {
      NetworkLogger.log('[Fingerprint] 读取模板状态失败: $e', level: 'warning');
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

class _TemplateStatus {
  const _TemplateStatus({required this.ready, required this.userAgent});

  final bool ready;
  final String? userAgent;
}
