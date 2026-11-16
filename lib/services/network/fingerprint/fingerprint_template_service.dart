import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../constants.dart';
import '../../network_logger.dart';
import '../../windows_webview_environment_service.dart';
import 'h3_calibration_status.dart';
import 'windows_h3_probe_environment.dart';

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

  /// TLS/H2 模板采样校准已就绪；不代表全协议指纹已验证或 CF 一定放行。
  final ValueNotifier<bool> templateReady = ValueNotifier(false);

  /// 当前代采样任务完成（包括 H3 失败）；与 TLS/H2 提前就绪分别通知。
  final ValueNotifier<int> calibrationRevision = ValueNotifier(0);

  int? _port;
  Future<void>? _inflight;
  Future<void>? _tcpValidation;
  Completer<void>? _cancelProbe;
  int _generation = 0;
  String? _h3Attempted;

  /// 核心启动后调用：检查模板，必要时采样。并发调用合并为一次。
  Future<void> ensure(int port, {bool waitForH3 = true}) {
    if (_port == port && _inflight != null) {
      return waitForH3 ? _inflight! : _tcpValidation!;
    }
    final previous = _inflight;
    _port = port;
    final generation = ++_generation;
    _cancelProbe?.complete();
    final cancel = _cancelProbe = Completer<void>();
    final tcpValidation = Completer<void>();
    _tcpValidation = tcpValidation.future;
    late final Future<void> task;
    task =
        (() async {
          // 先销毁旧探针，再启动新探针；快速切换网络也最多一个隐藏 WebView。
          if (previous != null) await previous;
          if (!_isCurrent(port, generation)) return;
          try {
            await _ensure(port, generation, cancel.future, tcpValidation);
          } catch (error) {
            NetworkLogger.log('[Fingerprint] 模板检查失败: $error', level: 'warning');
          }
        })().whenComplete(() {
          if (!tcpValidation.isCompleted) tcpValidation.complete();
          if (identical(_inflight, task)) _inflight = null;
          if (identical(_cancelProbe, cancel)) _cancelProbe = null;
          if (_isCurrent(port, generation)) calibrationRevision.value++;
        });
    _inflight = task;
    return waitForH3 ? task : tcpValidation.future;
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
    _h3Attempted = null;
  }

  Future<void> _ensure(
    int port,
    int generation,
    Future<void> cancelled,
    Completer<void> tcpValidation,
  ) async {
    var status = await _status(port);
    if (!_isCurrent(port, generation)) return;
    if (status == null) {
      templateReady.value = false;
      return;
    }
    final userAgent =
        await (_testUserAgent?.call() ?? AppConstants.getUserAgent());
    if (!_isCurrent(port, generation)) return;
    if (!status.ready ||
        status.needsRevalidation ||
        status.userAgent != userAgent) {
      templateReady.value = false;
      NetworkLogger.log(
        '[Fingerprint] 校准模板：ready=${status.ready}, '
        'revalidate=${status.needsRevalidation}, cache=${status.cacheState}',
      );
      final elapsed = Stopwatch()..start();
      // 同一主版本也可能被实验开关改变 TLS 扩展顺序，因此由两次独立
      // 握手校准，不使用版本阈值。核心在 done 后关闭采样连接。
      for (var attempt = 0; attempt < 2; attempt++) {
        if (_testProbe != null) {
          await _testProbe!(port, cancelled);
        } else {
          await _probe(port, cancelled);
        }
        if (!_isCurrent(port, generation)) return;
        status = await _status(port);
        if (!_isCurrent(port, generation)) return;
        if (status == null ||
            status.userAgent != userAgent ||
            (status.ready && !status.needsRevalidation)) {
          break;
        }
        if (attempt == 0) {
          await Future.any([
            Future<void>.delayed(const Duration(milliseconds: 150)),
            cancelled,
          ]);
          if (!_isCurrent(port, generation)) return;
        }
      }
      if (!_isCurrent(port, generation)) return;
      NetworkLogger.log(
        '[Fingerprint] 探针采样结束，耗时 ${elapsed.elapsedMilliseconds}ms，'
        '模板${status?.ready == true ? '已就绪' : '仍未就绪'}',
        level: status?.ready == true ? 'info' : 'warning',
      );
    }
    if (_isCurrent(port, generation)) {
      templateReady.value =
          status != null &&
          status.ready &&
          !status.needsRevalidation &&
          status.userAgent == userAgent;
    }
    // 启动阶段只需要等待 TLS/H2 校验；可选 H3 采样继续使用同一个串行任务。
    // 不能让未启用 QUIC 的 WebView 将首次业务请求额外阻塞两个探针超时。
    tcpValidation.complete();
    if (!_isCurrent(port, generation) || !templateReady.value || status == null) return;
    // 同 UA/端口的 TLS 配置变化也会使核心清空 H3；只抑制同一代、同一证书的重复失败。
    final h3Identity = jsonEncode([port, userAgent, status.h3Epoch,
      for (final probePort in status.h3Ports) [probePort, status.h3Spki[probePort]]]);
    if (status.h3.state != H3CalibrationState.sampled &&
        status.h3Ports.length == 2 &&
        _h3Attempted != h3Identity) {
      _h3Attempted = h3Identity;
      for (final probePort in status.h3Ports) {
        if (!_isCurrent(port, generation)) return;
        if (_testProbe != null) {
          await _testProbe!(probePort, cancelled);
        } else {
          await _probe(probePort, cancelled, path: '/fluxdo-h3', spki: status.h3Spki[probePort]);
        }
      }
      if (!_isCurrent(port, generation)) return;
      final finalStatus = await _status(port);
      if (!_isCurrent(port, generation)) return;
      final h3 = finalStatus?.h3 ?? H3CalibrationStatus.fromJson(null);
      NetworkLogger.log('[Fingerprint] H3 独立校准：state=${h3.state.name}，'
          'reason=${h3.reason}；仅表示本地采样，不代表业务请求使用 H3 或 CF 放行');
    }
  }

  /// 隐藏 WebView 访问探针页，等页面内 fetch 完成（标题变化）或超时。
  Future<void> _probe(int port, Future<void> cancelled, {String path = _probePath, String? spki}) async {
    final done = Completer<void>();
    HeadlessInAppWebView? webView;
    Future<void>? started;
    WindowsH3ProbeEnvironment? h3Environment;
    final isolatedH3 = Platform.isWindows && path == '/fluxdo-h3';
    var stopped = false;
    unawaited(cancelled.then((_) => stopped = true));
    try {
      if (isolatedH3) {
        h3Environment = await WindowsH3ProbeEnvironment.create(
          port: port, spki: spki ?? '', cancelled: cancelled,
        );
        if (stopped) return;
      }
      webView = HeadlessInAppWebView(
        webViewEnvironment:
            h3Environment?.environment ?? WindowsWebViewEnvironmentService.instance.environment,
        initialUrlRequest: URLRequest(
          url: WebUri('https://localhost:$port$path'),
        ),
        initialSettings: InAppWebViewSettings(
          userAgent: AppConstants.webViewUserAgentOverride,
          cacheEnabled: false,
          useShouldOverrideUrlLoading: true,
        ),
        shouldOverrideUrlLoading: (controller, action) async {
          final uri = action.request.url;
          return uri != null && uri.scheme == 'https' && uri.host == 'localhost' &&
                  uri.port == port && (uri.path == path || uri.path.startsWith('$path/'))
              ? NavigationActionPolicy.ALLOW : NavigationActionPolicy.CANCEL;
        },
        // Windows H3 只允许精确 SPKI；证书回调不能兜底放行另一把密钥。
        // 只放行核心的自签证书：限定 localhost（部分平台不提供端口，有端口时再核对）
        onReceivedServerTrustAuthRequest: (controller, challenge) async {
          final space = challenge.protectionSpace;
          final trusted =
              !isolatedH3 && space.host == 'localhost' &&
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
      started = webView.run();
      await Future.any([started, cancelled]).timeout(_probeTimeout);
      if (stopped) return;
      await Future.any([done.future, cancelled]).timeout(_probeTimeout);
    } on TimeoutException {
      NetworkLogger.log('[Fingerprint] 探针采样超时', level: 'warning');
    } catch (e) {
      NetworkLogger.log('[Fingerprint] 探针采样失败: $e', level: 'warning');
    } finally {
      await disposeProbeResources(
        started: started,
        disposeView: () async => webView?.dispose(),
        disposeEnvironment: h3Environment?.dispose,
      );
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
              needsRevalidation: value['needs_revalidation'] == true,
              cacheState: value['cache_state'] as String?,
              h3: H3CalibrationStatus.fromJson(value['h3']),
              h3Epoch: _h3Epoch(value['h3']?['epoch']),
              h3Ports: _h3Ports(value['h3']?['probe_ports']),
              h3Spki: _h3Spki(value['h3']?['probe_spki']),
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
        needsRevalidation: json['needs_revalidation'] == true,
        cacheState: json['cache_state'] as String?,
        h3: H3CalibrationStatus.fromJson(json['h3']),
        h3Epoch: _h3Epoch(json['h3']?['epoch']),
        h3Ports: _h3Ports(json['h3']?['probe_ports']),
        h3Spki: _h3Spki(json['h3']?['probe_spki']),
      );
    } catch (e) {
      NetworkLogger.log('[Fingerprint] 读取模板状态失败: $e', level: 'warning');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static int _h3Epoch(dynamic value) => value is int && value >= 0 ? value : 0;

  static Map<int, String> _h3Spki(dynamic value) => value is Map
      ? {for (final entry in value.entries)
          if (int.tryParse(entry.key.toString()) case final int port)
            if (entry.value is String) port: entry.value as String}
      : const {};

  static List<int> _h3Ports(dynamic value) => value is List
      ? value.whereType<int>().where((port) => port > 0 && port <= 65535).toSet().take(2).toList()
      : const [];
}

class _TemplateStatus {
  const _TemplateStatus({
    required this.ready,
    required this.userAgent,
    required this.needsRevalidation,
    this.cacheState,
    required this.h3,
    this.h3Epoch = 0,
    this.h3Ports = const [],
    this.h3Spki = const {},
  });

  final bool ready;
  final String? userAgent;
  final bool needsRevalidation;
  final String? cacheState;
  final H3CalibrationStatus h3;
  final int h3Epoch;
  final List<int> h3Ports;
  final Map<int, String> h3Spki;
}
