import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'windows_h3_probe_environment.dart';

// 最小 Flutter 宿主直接使用生产环境管理类，主控制器在探针创建/销毁期间保持存活。
void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: SizedBox.shrink()));
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => unawaited(runProbe(arguments)),
  );
}

Future<void> runProbe(List<String> arguments) async {
  final result = <String, dynamic>{
    'engine': 'Flutter WebView2 production probe environment',
    'full_flutter_app': false,
    'main_survived': false,
  };
  HeadlessInAppWebView? mainView;
  HeadlessInAppWebView? probeView;
  WebViewEnvironment? mainEnvironment;
  WindowsH3ProbeEnvironment? probeEnvironment;
  Directory? mainDirectory;
  Future<void>? mainStarted;
  Future<void>? probeStarted;
  final cancellation = Completer<void>();
  try {
    final uri = Uri.parse(
      arguments.firstWhere((arg) => arg.startsWith('https://')),
    );
    final trustedHost = Platform.environment['FLUXDO_TRUSTED_PROBE_HOST'];
    final trusted =
        trustedHost != null &&
        RegExp(r'^[a-z0-9][a-z0-9-]*\.[a-z0-9-]+\.ts\.net$')
            .hasMatch(trustedHost) &&
        uri.host == trustedHost;
    result['trusted_certificate_required'] = trusted;
    result['ssl_error_count'] = 0;
    result['ssl_errors_proceeded'] = 0;
    result['udp_relay'] = false;
    if ((uri.host != 'localhost' && !trusted) ||
        !['/fluxdo-h3', '/fluxdo-probe'].contains(uri.path)) {
      throw ArgumentError('not a probe URL');
    }
    mainDirectory = await Directory.systemTemp.createTemp('fluxdo-main-check-');
    final netlog = Platform.environment['FLUXDO_NATIVE_NETLOG_PATH'];
    if (netlog != null && (netlog.contains('"') || netlog.contains('\n'))) {
      throw ArgumentError('invalid NetLog path');
    }
    final flags = trusted && netlog != null ? '--log-net-log="$netlog"' : null;
    mainEnvironment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: mainDirectory.path,
        additionalBrowserArguments: flags,
      ),
    );
    result['environment_kind'] = 'shared_main';
    result['configured_browser_arguments'] = flags ?? '';
    mainView = HeadlessInAppWebView(
      webViewEnvironment: mainEnvironment,
      initialData: InAppWebViewInitialData(data: '<title>main-alive</title>'),
    );
    mainStarted = mainView.run();
    await mainStarted.timeout(const Duration(seconds: 20));
    result['version'] = await WebViewEnvironment.getAvailableVersion();
    result['native_user_agent'] = await mainView.webViewController!
        .evaluateJavascript(source: 'navigator.userAgent');
    var spki = Platform.environment['FLUXDO_NATIVE_PROBE_SPKI'];
    final wrongPin = Platform.environment['FLUXDO_PROBE_WRONG_PIN'] == '1';
    result['negative_pin_control'] = wrongPin;
    if (wrongPin) {
      if (Platform.environment['GITHUB_ACTIONS'] != 'true') {
        throw StateError('negative control requires CI');
      }
      spki = base64Encode(List<int>.filled(32, 0));
    }
    if (trusted && spki != null) {
      throw StateError('trusted origin forbids SPKI override');
    }
    if (spki != null) {
      probeEnvironment = await WindowsH3ProbeEnvironment.create(
        port: uri.port,
        spki: spki,
        cancelled: cancellation.future,
      );
    }
    result['isolated_h3_environment'] = probeEnvironment != null;
    result['diagnostic_force_quic'] = probeEnvironment != null;
    final done = Completer<void>();
    probeView = HeadlessInAppWebView(
      webViewEnvironment: probeEnvironment?.environment ?? mainEnvironment,
      initialUrlRequest: URLRequest(url: WebUri(uri.toString())),
      initialSettings: InAppWebViewSettings(
        cacheEnabled: false,
        useShouldOverrideUrlLoading: true,
      ),
      shouldOverrideUrlLoading: (_, action) async =>
          action.request.url?.origin == uri.origin
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL,
      onReceivedServerTrustAuthRequest: (_, challenge) async {
        result['ssl_error_count'] = (result['ssl_error_count'] as int) + 1;
        final allow =
            !trusted &&
            probeEnvironment == null &&
            challenge.protectionSpace.host == 'localhost' &&
            (challenge.protectionSpace.port == null ||
                challenge.protectionSpace.port == uri.port);
        if (allow) {
          result['ssl_errors_proceeded'] =
              (result['ssl_errors_proceeded'] as int) + 1;
        }
        if (trusted) {
          result['certificate_rejected'] = true;
          if (!done.isCompleted) {
            done.completeError(StateError('certificate rejected'));
          }
        }
        return ServerTrustAuthResponse(
          action: allow
              ? ServerTrustAuthResponseAction.PROCEED
              : ServerTrustAuthResponseAction.CANCEL,
        );
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true && !done.isCompleted) {
          done.completeError(StateError(error.description));
        }
      },
      onTitleChanged: (_, title) {
        if (title == 'fluxdo-probe-done' && !done.isCompleted) done.complete();
      },
    );
    // 先订阅错误，避免原生回调早于 run 返回时成为未处理异常。
    probeStarted = probeView.run();
    final completion = Future.wait([probeStarted, done.future])
        .timeout(const Duration(seconds: 45));
    await completion;
    await probeView.dispose();
    probeView = null;
    await probeEnvironment?.dispose();
    result['probe_profile_removed'] =
        probeEnvironment == null || !await probeEnvironment.directory.exists();
    result['main_survived'] =
        (await mainView.webViewController!.evaluateJavascript(source: '1+1'))
            .toString() ==
        '2';
    result['success'] =
        result['main_survived'] == true &&
        result['probe_profile_removed'] == true;
  } catch (error, stack) {
    result['success'] = false;
    result['error'] = error.toString();
    stderr.writeln(stack);
  } finally {
    cancellation.complete();
    try {
      if (mainView?.webViewController != null) {
        result['main_survived'] =
            (await mainView!.webViewController!
                    .evaluateJavascript(source: '1+1')
                    .timeout(const Duration(seconds: 5)))
                .toString() ==
            '2';
      }
    } catch (error) {
      result['main_survived'] = false;
      result['main_check_error'] = error.toString();
    }
    if (result['main_survived'] != true) result['success'] = false;
    try {
      try {
        await disposeProbeResources(
          started: probeStarted,
          disposeView: () async => await probeView?.dispose(),
          disposeEnvironment: () async => await probeEnvironment?.dispose(),
        );
      } finally {
        await disposeProbeResources(
          started: mainStarted,
          disposeView: () async => await mainView?.dispose(),
          disposeEnvironment: () async => await mainEnvironment?.dispose(),
        );
      }
      // WebView2 的进程退出与文件锁释放可能晚于环境 dispose 返回。
      if (mainDirectory != null) await removeProfile(mainDirectory);
      result['main_profile_removed'] =
          mainDirectory == null || !await mainDirectory.exists();
    } catch (error) {
      result['cleanup_error'] = error.toString();
      result['success'] = false;
    }
    stdout.writeln(jsonEncode(result));
    await stdout.flush();
    exit(result['success'] == true ? 0 : 1);
  }
}

Future<void> removeProfile(Directory directory) async {
  for (var attempt = 0; attempt < 21; attempt++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 20) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}
