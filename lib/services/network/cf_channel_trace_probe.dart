import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../constants.dart';
import '../log/log_writer.dart';
import '../network_logger.dart';
import 'adapters/webview_http_adapter.dart';
import 'cookie/cookie_logger.dart';
import 'core/net_core_http_adapter.dart';
import 'core/net_core_service.dart';
import 'flux_request_spec.dart';

typedef TraceChannelFetcher = Future<CfTraceRawResult> Function(Uri traceUri);

/// 原始 trace 响应（仅内存中使用，严禁直接落盘）。
class CfTraceRawResult {
  const CfTraceRawResult({
    required this.ok,
    this.statusCode,
    this.body,
    this.errorType,
  });

  final bool ok;
  final int? statusCode;
  final String? body;
  final String? errorType;
}

/// 脱敏后的单通道 `/cdn-cgi/trace` 采样结果（不含明文 IP）。
@immutable
class CfTraceChannelSummary {
  const CfTraceChannelSummary({
    required this.ok,
    this.statusCode,
    this.errorType,
    this.ipHash,
    this.ipVersion,
    this.colo,
    this.http,
    this.tls,
    this.kex,
    this.warp,
    this.sni,
  });

  final bool ok;
  final int? statusCode;
  final String? errorType;
  final String? ipHash;
  final String? ipVersion;
  final String? colo;
  final String? http;
  final String? tls;
  final String? kex;
  final String? warp;
  final String? sni;

  Map<String, dynamic> toJson() => {
    'ok': ok,
    if (statusCode != null) 'statusCode': statusCode,
    if (errorType != null) 'errorType': errorType,
    if (ipHash != null) 'ipHash': ipHash,
    if (ipVersion != null) 'ipVersion': ipVersion,
    if (colo != null) 'colo': colo,
    if (http != null) 'http': http,
    if (tls != null) 'tls': tls,
    if (kex != null) 'kex': kex,
    if (warp != null) 'warp': warp,
    if (sni != null) 'sni': sni,
  };
}

/// 双通道 `/cdn-cgi/trace` 对照报告（已脱敏，不含明文 IP）。
@immutable
class CfChannelTraceReport {
  const CfChannelTraceReport({
    required this.triggerPath,
    required this.triggerStatusCode,
    required this.core,
    required this.webview,
    required this.sameIp,
    required this.sameColo,
    required this.sameHttp,
    required this.sameTls,
    required this.sameKex,
  });

  final String triggerPath;
  final int? triggerStatusCode;
  final CfTraceChannelSummary core;
  final CfTraceChannelSummary webview;
  final bool? sameIp;
  final bool? sameColo;
  final bool? sameHttp;
  final bool? sameTls;
  final bool? sameKex;

  Map<String, dynamic> toJson() => {
    'triggerPath': triggerPath,
    if (triggerStatusCode != null) 'triggerStatusCode': triggerStatusCode,
    'sameIp': sameIp,
    'sameColo': sameColo,
    'sameHttp': sameHttp,
    'sameTls': sameTls,
    'sameKex': sameKex,
    'core': core.toJson(),
    'webview': webview.toJson(),
  };
}

/// CF 验证放行但原生通道重试仍 403/429 时的后台对照探针（方案 A）。
///
/// 仅在出现通道分裂异常时触发，平时零额外请求；带强冷却与单飞防并发。
/// 并行向 `https://linux.do/cdn-cgi/trace` 各发一次 `core` 与 `webview` 请求，
/// 脱敏对比两者的出口 IP 哈希、机房（colo）、HTTP 版本、TLS 与密钥交换（kex），
/// 用来直接区分「代理/VPN 出口分流不一致」与「TLS/HTTP 指纹差异」。
class CfChannelTraceProbe {
  CfChannelTraceProbe._()
    : _coreFetcher = null,
      _webViewFetcher = null,
      _canProbeCore = null,
      _now = DateTime.now;

  @visibleForTesting
  CfChannelTraceProbe.forTesting({
    required this._coreFetcher,
    required this._webViewFetcher,
    bool Function()? canProbeCore,
    DateTime Function()? now,
  }) : _canProbeCore = canProbeCore ?? (() => true),
       _now = now ?? DateTime.now;

  static final CfChannelTraceProbe instance = CfChannelTraceProbe._();

  static const Duration cooldown = Duration(minutes: 15);
  static const Duration probeTimeout = Duration(seconds: 6);

  final TraceChannelFetcher? _coreFetcher;
  final TraceChannelFetcher? _webViewFetcher;
  final bool Function()? _canProbeCore;
  final DateTime Function() _now;

  DateTime? _lastProbeAt;
  Future<CfChannelTraceReport?>? _inflight;

  /// 若不在冷却期内且核心可用，则在后台执行一次双通道 trace 对照。
  Future<CfChannelTraceReport?> probeIfNeeded({
    required String triggerPath,
    int? triggerStatusCode,
    bool force = false,
  }) async {
    if (_inflight != null) return null;

    final coreAvailable =
        _canProbeCore?.call() ?? NetCoreService.instance.isRunning;
    if (!coreAvailable) return null;

    final currentTime = _now();
    final last = _lastProbeAt;
    if (!force && last != null && currentTime.difference(last) < cooldown) {
      return null;
    }

    _lastProbeAt = currentTime;
    final task = _runProbe(
      triggerPath: triggerPath,
      triggerStatusCode: triggerStatusCode,
    );
    _inflight = task;
    try {
      return await task;
    } finally {
      if (identical(_inflight, task)) {
        _inflight = null;
      }
    }
  }

  Future<CfChannelTraceReport?> _runProbe({
    required String triggerPath,
    required int? triggerStatusCode,
  }) async {
    try {
      final traceUri = Uri.parse(AppConstants.baseUrl).resolve('/cdn-cgi/trace');
      final coreFuture = (_coreFetcher ?? _fetchViaCore)(traceUri);
      final webViewFuture = (_webViewFetcher ?? _fetchViaWebView)(traceUri);
      final results = await Future.wait([coreFuture, webViewFuture]);
      final coreRaw = results[0];
      final webViewRaw = results[1];

      final coreFields = coreRaw.ok ? parseTraceBody(coreRaw.body) : const <String, String>{};
      final webViewFields = webViewRaw.ok ? parseTraceBody(webViewRaw.body) : const <String, String>{};

      final coreIp = _nonEmpty(coreFields['ip']);
      final webViewIp = _nonEmpty(webViewFields['ip']);

      final coreSummary = _summarize(coreRaw, coreFields);
      final webViewSummary = _summarize(webViewRaw, webViewFields);

      final report = CfChannelTraceReport(
        triggerPath: triggerPath,
        triggerStatusCode: triggerStatusCode,
        core: coreSummary,
        webview: webViewSummary,
        sameIp: _compare(coreIp, webViewIp),
        sameColo: _compare(coreSummary.colo, webViewSummary.colo),
        sameHttp: _compare(coreSummary.http, webViewSummary.http),
        sameTls: _compare(coreSummary.tls, webViewSummary.tls),
        sameKex: _compare(coreSummary.kex, webViewSummary.kex),
      );
      _logReport(report);
      return report;
    } catch (e) {
      debugPrint('[CfTraceProbe] 对照采样异常（已忽略）: ${e.runtimeType}');
      return null;
    }
  }

  static Future<CfTraceRawResult> _fetchViaCore(Uri traceUri) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: probeTimeout,
        receiveTimeout: probeTimeout,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    )..httpClientAdapter = NetCoreHttpAdapter();
    try {
      final ua = await AppConstants.getUserAgent();
      final response = await dio.getUri<String>(
        traceUri,
        options: Options(
          headers: {'User-Agent': ua},
          extra: const {
            FluxRequestKeys.isSilent: true,
            FluxRequestKeys.skipCfChallenge: true,
            FluxRequestKeys.skipCfBlock: true,
            FluxRequestKeys.skipCsrf: true,
            FluxRequestKeys.skipAuthCheck: true,
            FluxRequestKeys.skipSessionStateSync: true,
            FluxRequestKeys.skipScheduler: true,
            FluxRequestKeys.skipNetworkLog: true,
            FluxRequestKeys.noRecovery: true,
            FluxRequestKeys.skipWebViewAdapter: true,
            FluxRequestKeys.requestTag: 'cf-trace-probe-core',
          },
        ),
      );
      return CfTraceRawResult(
        ok: response.statusCode == 200 && response.data != null,
        statusCode: response.statusCode,
        body: response.data,
      );
    } on DioException catch (e) {
      return CfTraceRawResult(
        ok: false,
        statusCode: e.response?.statusCode,
        errorType: e.type.name,
      );
    } catch (e) {
      return CfTraceRawResult(ok: false, errorType: e.runtimeType.toString());
    } finally {
      dio.close(force: false);
    }
  }

  static Future<CfTraceRawResult> _fetchViaWebView(Uri traceUri) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: probeTimeout,
        receiveTimeout: probeTimeout,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
    )..httpClientAdapter = WebViewHttpAdapter();
    try {
      final response = await dio.getUri<String>(
        traceUri,
        options: Options(
          extra: const {
            FluxRequestKeys.isSilent: true,
            FluxRequestKeys.skipCfChallenge: true,
            FluxRequestKeys.skipCfBlock: true,
            FluxRequestKeys.skipCsrf: true,
            FluxRequestKeys.skipAuthCheck: true,
            FluxRequestKeys.skipSessionStateSync: true,
            FluxRequestKeys.skipScheduler: true,
            FluxRequestKeys.skipNetworkLog: true,
            FluxRequestKeys.noRecovery: true,
            WebViewHttpAdapter.cookieModeExtraKey:
                WebViewHttpAdapter.cookieModeNone,
            FluxRequestKeys.requestTag: 'cf-trace-probe-webview',
          },
        ),
      );
      return CfTraceRawResult(
        ok: response.statusCode == 200 && response.data != null,
        statusCode: response.statusCode,
        body: response.data,
      );
    } on DioException catch (e) {
      return CfTraceRawResult(
        ok: false,
        statusCode: e.response?.statusCode,
        errorType: e.type.name,
      );
    } catch (e) {
      return CfTraceRawResult(ok: false, errorType: e.runtimeType.toString());
    } finally {
      dio.close(force: false);
    }
  }

  /// 解析 Cloudflare `/cdn-cgi/trace` 的 `key=value` 文本。
  @visibleForTesting
  static Map<String, String> parseTraceBody(String? body) {
    if (body == null || body.isEmpty) return const {};
    final result = <String, String>{};
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final idx = line.indexOf('=');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim();
      final value = line.substring(idx + 1).trim();
      if (key.isNotEmpty && value.isNotEmpty) {
        result[key] = value;
      }
    }
    return result;
  }

  static CfTraceChannelSummary _summarize(
    CfTraceRawResult raw,
    Map<String, String> fields,
  ) {
    final ip = _nonEmpty(fields['ip']);
    return CfTraceChannelSummary(
      ok: raw.ok,
      statusCode: raw.statusCode,
      errorType: raw.errorType,
      ipHash: CookieLogger.valueHash(ip),
      ipVersion: _ipVersion(ip),
      colo: _nonEmpty(fields['colo']),
      http: _nonEmpty(fields['http']),
      tls: _nonEmpty(fields['tls']),
      kex: _nonEmpty(fields['kex']),
      warp: _nonEmpty(fields['warp']),
      sni: _nonEmpty(fields['sni']),
    );
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  static String? _ipVersion(String? ip) {
    if (ip == null || ip.isEmpty) return null;
    if (ip.contains(':')) return 'v6';
    if (ip.contains('.')) return 'v4';
    return null;
  }

  static bool? _compare(String? a, String? b) {
    if (a == null || b == null) return null;
    return a == b;
  }

  static void _logReport(CfChannelTraceReport report) {
    final summary =
        '[CfTraceProbe] 通道对照: sameIp=${report.sameIp}, '
        'sameColo=${report.sameColo}, sameHttp=${report.sameHttp}, '
        'sameTls=${report.sameTls}, sameKex=${report.sameKex} | '
        'core=(ok=${report.core.ok}, status=${report.core.statusCode}, '
        'colo=${report.core.colo}, http=${report.core.http}, '
        'tls=${report.core.tls}, kex=${report.core.kex}, '
        'ipHash=${report.core.ipHash}) | '
        'webview=(ok=${report.webview.ok}, status=${report.webview.statusCode}, '
        'colo=${report.webview.colo}, http=${report.webview.http}, '
        'tls=${report.webview.tls}, kex=${report.webview.kex}, '
        'ipHash=${report.webview.ipHash})';
    NetworkLogger.log(summary, level: 'info');
    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'info',
      'type': 'network',
      'event': 'cf_channel_trace_compare',
      'message': summary,
      ...report.toJson(),
    });
  }

  @visibleForTesting
  void resetForTesting() {
    _lastProbeAt = null;
    _inflight = null;
  }
}
