// Linux 原生 WebView 冒烟验证：临时本地 HTTPS 服务，无外网、无账号。
// 运行：dart tool/flutterw.dart run -d linux -t tool/linux_webview_smoke.dart
// 需要 openssl；不安装证书。可通过 FLUXDO_SMOKE_REPORT 指定 JSON 报告路径。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' hide Cookie;

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Linux WebView validation'))),
    ),
  );
  final checks = <String>[];
  Directory? directory;
  HttpServer? server;
  HeadlessInAppWebView? view;
  var exitCode = 0;
  try {
    directory = await Directory.systemTemp.createTemp('fluxdo-tls-smoke-');
    final cert = '${directory.path}/cert.pem';
    final key = '${directory.path}/key.pem';
    final issued = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=IP:127.0.0.1,DNS:localhost',
      '-keyout',
      key,
      '-out',
      cert,
    ]);
    require(issued.exitCode == 0, 'Test certificate generation failed');
    final derResult = await Process.run('openssl', [
      'x509',
      '-in',
      cert,
      '-outform',
      'DER',
    ], stdoutEncoding: null);
    final expectedDer = (derResult.stdout as List<int>);
    final security = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      security,
    );
    var requests = 0;
    server.listen((request) async {
      requests++;
      stdout.writeln('SMOKE HTTP ${request.uri}');
      request.response.headers.contentType = ContentType.html;
      request.response.cookies.add(
        Cookie('serverSmoke', 'present')
          ..path = '/'
          ..secure = true
          ..httpOnly = false,
      );
      if (request.uri.path == '/frame-redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set('Location', '/frame-redirected');
      } else if (request.uri.path.startsWith('/frame')) {
        request.response.write('''<!doctype html><title>Frame</title>
<button onclick="parent.postMessage('clicked', location.origin)">Interact</button>
<script>parent.postMessage(location.pathname, location.origin);</script>''');
      } else {
        request.response.write(
          '<!doctype html><title>FluxDO TLS smoke</title><body>HTTPS loaded</body>',
        );
      }
      await request.response.close();
    });
    final url = WebUri('https://127.0.0.1:${server.port}/');
    void validateChallenge(ServerTrustChallenge challenge) {
      final space = challenge.protectionSpace;
      require(
        space.host == '127.0.0.1' && space.port == server!.port,
        'Host/port changed',
      );
      require(space.protocol == 'https', 'Protocol missing');
      require(
        space.sslError?.code == SslErrorType.UNTRUSTED,
        'SSL code lost: ${space.sslError}',
      );
      require(
        listEquals(space.sslCertificate?.x509Certificate?.encoded, expectedDer),
        'DER certificate changed',
      );
    }

    final rejected = Completer<void>();
    view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: url),
      onReceivedServerTrustAuthRequest: (_, challenge) async {
        try {
          validateChallenge(challenge);
          if (!rejected.isCompleted) rejected.complete();
        } catch (e, s) {
          if (!rejected.isCompleted) rejected.completeError(e, s);
        }
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.CANCEL,
        );
      },
    );
    await view.run();
    await rejected.future.timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(seconds: 2));
    require(requests == 0, 'CANCEL still sent an HTTP request');
    checks.add('TLS CANCEL prevents HTTPS request');
    await view.dispose();

    final accepted = Completer<void>();
    final loaded = Completer<InAppWebViewController>();
    view = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: url),
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
      onLoadStart: (_, url) => stdout.writeln('SMOKE START $url'),
      onReceivedError: (_, request, error) =>
          stdout.writeln('SMOKE ERROR ${request.url} $error'),
      onTitleChanged: (controller, title) {
        if (title == 'FluxDO TLS smoke' && !loaded.isCompleted) {
          loaded.complete(controller);
        }
      },
      onReceivedServerTrustAuthRequest: (_, challenge) async {
        try {
          validateChallenge(challenge);
          // Exercise the native callback after its signal-owned URI is gone.
          await Future<void>.delayed(const Duration(milliseconds: 250));
          if (!accepted.isCompleted) accepted.complete();
          return ServerTrustAuthResponse(
            action: ServerTrustAuthResponseAction.PROCEED,
          );
        } catch (e, s) {
          if (!accepted.isCompleted) accepted.completeError(e, s);
          return ServerTrustAuthResponse(
            action: ServerTrustAuthResponseAction.CANCEL,
          );
        }
      },
      onLoadStop: (controller, _) async {
        stdout.writeln(
          'SMOKE STOP title=${await controller.getTitle()} requests=$requests',
        );
        if (await controller.getTitle() == 'FluxDO TLS smoke' &&
            !loaded.isCompleted) {
          loaded.complete(controller);
        }
      },
    );
    await view.run();
    await accepted.future.timeout(const Duration(seconds: 20));
    final controller = await loaded.future.timeout(const Duration(seconds: 20));
    require(requests > 0, 'PROCEED did not load HTTPS');
    checks.add(
      'TLS PROCEED retries HTTPS after async callback; error, host and DER preserved',
    );
    final script = await controller.evaluateJavascript(
      source: "document.cookie = 'jsSmoke=present; Path=/; Secure'; JSON.stringify({title: document.title, answer: 6 * 7, cookies: document.cookie})",
    );
    final decoded = jsonDecode(script as String) as Map;
    require(
      decoded['answer'] == 42 && decoded['title'] == 'FluxDO TLS smoke',
      'JavaScript result wrong',
    );
    require(
      (decoded['cookies'] as String).contains('serverSmoke=present'),
      'Set-Cookie missing from JS',
    );
    checks.add('JavaScript execution and HTTPS Set-Cookie');
    final cookies = await CookieManager.instance().getCookies(url: url);
    require(
      cookies.any(
        (cookie) => cookie.name == 'jsSmoke' && cookie.value == 'present',
      ),
      'JS cookie missing from native cookie store',
    );
    checks.add('Native CookieManager reads JavaScript cookie');
    final visibleLoaded = Completer<void>();
    final retained = InAppWebViewKeepAlive();
    final frameResponses = <String>[];
    final blockedNavigation = Completer<void>();
    InAppWebViewController? visibleController;
    runApp(
      MaterialApp(
        home: Scaffold(
          body: InAppWebView(
            keepAlive: retained,
            onWebViewCreated: (controller) async {
              visibleController = controller;
              try {
                await controller.loadData(
                  data: '''<!doctype html><title>FluxDO TLS smoke</title>
<script>
window.frameMessages = [];
addEventListener('message', event => {
  if (event.origin === location.origin) frameMessages.push(event.data);
});
</script>
<body>Retained mini app host
<iframe src="/frame-unnamed"></iframe>
<iframe name="named-frame" src="/frame-redirect"></iframe>
<a id="leave" href="/outside">Leave host</a></body>''',
                  baseUrl: url,
                  historyUrl: url,
                );
              } catch (error, stack) {
                if (!visibleLoaded.isCompleted) {
                  visibleLoaded.completeError(error, stack);
                }
              }
            },
            // Match the Linux runner: WPE only identifies the frame accurately
            // at response time, including unnamed and redirected iframes.
            shouldOverrideUrlLoading: (_, action) async =>
                {
                  'https',
                  'http',
                  'about',
                  'blob',
                  'data',
                }.contains(action.request.url?.scheme)
                ? NavigationActionPolicy.ALLOW
                : NavigationActionPolicy.CANCEL,
            onNavigationResponse: (_, response) async {
              final path = response.response?.url?.path;
              if (response.isForMainFrame == true) {
                if (path == '/outside' && !blockedNavigation.isCompleted) {
                  blockedNavigation.complete();
                }
                return NavigationResponseAction.CANCEL;
              }
              if (path != null) frameResponses.add(path);
              return NavigationResponseAction.ALLOW;
            },
            onLoadStop: (controller, _) async {
              final title = await controller.evaluateJavascript(
                source: 'document.title',
              );
              if (title == 'FluxDO TLS smoke' && !visibleLoaded.isCompleted) {
                visibleLoaded.complete();
              }
            },
          ),
        ),
      ),
    );
    await visibleLoaded.future.timeout(const Duration(seconds: 20));
    checks.add(
      'Visible retained InAppWebView loads HTML with HTTPS origin and receives callbacks',
    );
    require(
      await visibleController!.evaluateJavascript(source: 'location.origin') ==
          url.origin,
      'loadData lost the HTTPS origin',
    );
    require(
      frameResponses.contains('/frame-unnamed') &&
          frameResponses.contains('/frame-redirected'),
      'WPE response callback misclassified an iframe: $frameResponses',
    );
    final frameMessages = jsonDecode(
      await visibleController!.evaluateJavascript(
        source: 'JSON.stringify(window.frameMessages)',
      ) as String,
    ) as List;
    require(
      frameMessages.contains('/frame-unnamed') &&
          frameMessages.contains('/frame-redirected'),
      'Iframe scripts did not reach their host: $frameMessages',
    );
    await visibleController!.evaluateJavascript(
      source: "document.querySelector('iframe').contentDocument.querySelector('button').click()",
    );
    for (var attempt = 0; attempt < 50; attempt++) {
      if (await visibleController!.evaluateJavascript(
            source: "window.frameMessages.includes('clicked')",
          ) ==
          true) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    require(
      await visibleController!.evaluateJavascript(
            source: "window.frameMessages.includes('clicked')",
          ) ==
          true,
      'Iframe interaction did not reach the host',
    );
    checks.add(
      'Unnamed and redirected iframes load, execute and exchange messages',
    );
    await visibleController!.evaluateJavascript(
      source: "document.querySelector('#leave').click()",
    );
    await blockedNavigation.future.timeout(const Duration(seconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    require(
      await visibleController!.evaluateJavascript(
            source: "Array.isArray(window.frameMessages)",
          ) ==
          true,
      'External main-frame navigation replaced the host',
    );
    checks.add(
      'Main-frame navigation is cancelled without blocking iframe navigation',
    );
    await visibleController!.evaluateJavascript(
      source: 'window.retainedValue = 73',
    );
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    // Let the platform-view dispose message put the native view into its cache.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final restored = Completer<InAppWebViewController>();
    runApp(
      MaterialApp(
        home: Scaffold(
          body: InAppWebView(
            keepAlive: retained,
            onWebViewCreated: restored.complete,
          ),
        ),
      ),
    );
    final restoredController = await restored.future.timeout(
      const Duration(seconds: 20),
    );
    require(
      await restoredController.evaluateJavascript(
            source: 'window.retainedValue',
          ) ==
          73,
      'Retained JavaScript state lost after remount',
    );
    require(
      await restoredController.getTitle() == 'FluxDO TLS smoke',
      'Retained controller lost native channel',
    );
    checks.add(
      'Retained WebView restores its document, JavaScript state and native channel',
    );
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await InAppWebViewController.disposeKeepAlive(retained);
    await CookieManager.instance().deleteCookie(url: url, name: 'jsSmoke');
    await CookieManager.instance().deleteCookie(url: url, name: 'serverSmoke');
    await view.dispose();
    view = null;
  } catch (error, stack) {
    exitCode = 1;
    checks.add('FAIL: $error\n$stack');
  } finally {
    await view?.dispose();
    await server?.close(force: true);
    await directory?.delete(recursive: true);
    final report = jsonEncode({'passed': exitCode == 0, 'checks': checks});
    stdout.writeln('FLUXDO_WEBVIEW_SMOKE $report');
    final reportPath = Platform.environment['FLUXDO_SMOKE_REPORT'];
    if (reportPath != null) await File(reportPath).writeAsString(report);
    exit(exitCode);
  }
}
