import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'windows_h3_probe_environment.dart';

// 最小 Flutter 宿主直接使用生产环境管理类，主控制器在探针创建/销毁期间保持存活。
void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: SizedBox.shrink()));
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(runProbe(arguments)));
}

Future<void> runProbe(List<String> arguments) async {
  final result = <String, dynamic>{'engine': 'Flutter WebView2 production probe environment',
    'full_flutter_app': false, 'main_survived': false};
  HeadlessInAppWebView? mainView;
  HeadlessInAppWebView? probeView;
  WebViewEnvironment? mainEnvironment;
  WindowsH3ProbeEnvironment? probeEnvironment;
  Directory? mainDirectory;
  final cancellation = Completer<void>();
  try {
    final uri = Uri.parse(arguments.firstWhere((arg) => arg.startsWith('https://localhost:')));
    if (uri.host != 'localhost' || !['/fluxdo-h3', '/fluxdo-probe'].contains(uri.path)) {
      throw ArgumentError('not a probe URL');
    }
    mainDirectory = await Directory.systemTemp.createTemp('fluxdo-main-check-');
    mainEnvironment = await WebViewEnvironment.create(settings: WebViewEnvironmentSettings(userDataFolder: mainDirectory.path));
    mainView = HeadlessInAppWebView(webViewEnvironment: mainEnvironment,
      initialData: InAppWebViewInitialData(data: '<title>main-alive</title>'));
    await mainView.run().timeout(const Duration(seconds: 20));
    result['version'] = await WebViewEnvironment.getAvailableVersion();
    result['native_user_agent'] = await mainView.webViewController!.evaluateJavascript(source: 'navigator.userAgent');
    final spki = Platform.environment['FLUXDO_NATIVE_PROBE_SPKI'];
    if (spki != null) {
      probeEnvironment = await WindowsH3ProbeEnvironment.create(port: uri.port, spki: spki, cancelled: cancellation.future);
    }
    result['isolated_h3_environment'] = probeEnvironment != null;
    result['diagnostic_force_quic'] = probeEnvironment != null;
    final done = Completer<void>();
    probeView = HeadlessInAppWebView(
      webViewEnvironment: probeEnvironment?.environment ?? mainEnvironment,
      initialUrlRequest: URLRequest(url: WebUri(uri.toString())),
      initialSettings: InAppWebViewSettings(cacheEnabled: false, useShouldOverrideUrlLoading: true),
      shouldOverrideUrlLoading: (_, action) async => action.request.url?.origin == uri.origin
          ? NavigationActionPolicy.ALLOW : NavigationActionPolicy.CANCEL,
      onReceivedServerTrustAuthRequest: (_, challenge) async => ServerTrustAuthResponse(action:
          probeEnvironment == null && challenge.protectionSpace.host == 'localhost' &&
            (challenge.protectionSpace.port == null || challenge.protectionSpace.port == uri.port)
          ? ServerTrustAuthResponseAction.PROCEED : ServerTrustAuthResponseAction.CANCEL),
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true && !done.isCompleted) done.completeError(StateError(error.description));
      },
      onTitleChanged: (_, title) { if (title == 'fluxdo-probe-done' && !done.isCompleted) done.complete(); },
    );
    // 先订阅错误，避免原生回调早于 run 返回时成为未处理异常。
    final completion = Future.wait([probeView.run(), done.future]).timeout(const Duration(seconds: 45));
    await completion;
    await probeView.dispose(); probeView = null;
    await probeEnvironment?.dispose();
    result['probe_profile_removed'] = probeEnvironment == null || !await probeEnvironment.directory.exists();
    result['main_survived'] = (await mainView.webViewController!.evaluateJavascript(source: '1+1')).toString() == '2';
    result['success'] = result['main_survived'] == true && result['probe_profile_removed'] == true;
  } catch (error, stack) {
    result['success'] = false; result['error'] = error.toString();
    stderr.writeln(stack);
  } finally {
    cancellation.complete();
    try {
      await probeView?.dispose();
      await probeEnvironment?.dispose();
      await mainView?.dispose();
      await mainEnvironment?.dispose();
      if (mainDirectory != null && await mainDirectory.exists()) await mainDirectory.delete(recursive: true);
    } catch (error) { result['cleanup_error'] = error.toString(); }
    stdout.writeln(jsonEncode(result));
    await stdout.flush();
    exit(result['success'] == true ? 0 : 1);
  }
}
