// Windows 真实 WebView2 资源拦截回归入口。使用独立临时数据目录和合成网页，
// 不访问登录态或社区接口。flutter build windows --debug -t tool/windows_mini_app_smoke.dart
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:common_ui/common_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:window_manager/window_manager.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_host_adapter.dart';

late File _log;
late Uri _entry;
late Uint8List _serverCertificate;
void _record(String text) =>
    _log.writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
Never _fail(Object error) {
  _record('FAIL $error');
  exit(1);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _log = File('build/mini-app-windows-smoke-result.log')
    ..writeAsStringSync('START\n');
  FlutterError.onError = (details) => _fail(details.exception);
  Timer(const Duration(seconds: 45), () => _fail('timeout'));
  // 仅本地 TLS 服务，覆盖生产环境中异步证书校验和未拦截资源的路径。
  final tls = SecurityContext()
    ..useCertificateChain('build/mini-app-smoke-cert.pem')
    ..usePrivateKey('build/mini-app-smoke-key.pem');
  _serverCertificate = File('build/mini-app-smoke-cert.der').readAsBytesSync();
  final server = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    tls,
  );
  _entry = Uri.parse('https://127.0.0.1:${server.port}/app');
  server.listen((request) async {
    request.response.headers.contentType = ContentType.text;
    request.response.write('轻量宿主已就绪');
    await request.response.close();
  });
  final folder = await Directory.systemTemp.createTemp(
    'fluxdo-mini-app-smoke-',
  );
  final environment = await WebViewEnvironment.create(
    settings: WebViewEnvironmentSettings(userDataFolder: folder.path),
  );
  await windowManager.ensureInitialized();
  runApp(MaterialApp(home: _Smoke(environment: environment)));
}

class _Smoke extends StatefulWidget {
  const _Smoke({required this.environment});
  final WebViewEnvironment environment;
  @override
  State<_Smoke> createState() => _SmokeState();
}

class _SmokeState extends State<_Smoke> {
  final _textureKey = GlobalKey();
  int _cycle = 0;
  bool _show = true;
  Completer<void>? _pending;
  InAppWebViewKeepAlive _keepAlive = InAppWebViewKeepAlive();

  Future<void> _verifyNestedViewport(InAppWebViewController controller) async {
    Future<Map> metrics() async =>
        await controller.evaluateJavascript(source: 'window.childMetrics || {}')
            as Map;
    Future<void> scroll(double delta) async {
      // 本地夹具通过自己的消息请求浏览器滚动，验证布局确实有滚动范围。
      // 不将此验证当成 Android 原生触摸/选择框的实机验收。
      await controller.evaluateJavascript(
        source:
            "document.querySelector('iframe').contentWindow.postMessage({fixture:'scroll',delta:$delta}, '*');",
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    for (var phase = 0; phase < 3; phase++) {
      final fixed = phase == 1;
      if (phase == 2) {
        await controller.removeUserScriptsByGroupName(
          groupName: 'viewport-fixture',
        );
      }
      await controller.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(
            _entry.resolve('/viewport-fixture?adapt=${phase > 0}').toString(),
          ),
        ),
      );
      Map sample = {};
      for (var i = 0; i < 50; i++) {
        sample = await metrics();
        if (sample['height'] is num) break;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      final viewport = _textureKey.currentContext!.size!.height;
      if (fixed) {
        if ((sample['height'] as num? ?? 0) > viewport + 2 ||
            (sample['height'] as num? ?? 0) < viewport - 2 ||
            (sample['scrollHeight'] as num? ?? 0) < 1200) {
          _fail(
            'nested viewport was not constrained: $sample, viewport=$viewport',
          );
        }
        await scroll(200);
        final down = await metrics();
        if ((down['scrollTop'] as num? ?? 0) <= 0) {
          _fail('nested app cannot scroll down: $down');
        }
        await scroll(-200);
        final up = await metrics();
        if ((up['scrollTop'] as num) >= (down['scrollTop'] as num)) {
          _fail('nested app cannot scroll up: $up');
        }
        _record(
          'nested viewport fixed: $sample; down=${down['scrollTop']} up=${up['scrollTop']}',
        );
      } else {
        if ((sample['height'] as num? ?? 0) < 1199) {
          _fail(
            'control fixture did not reproduce oversized inner frame: $sample',
          );
        }
        await scroll(200);
        sample = await metrics();
        if (sample['scrollTop'] != 0) {
          _fail('control fixture unexpectedly scrolls: $sample');
        }
        _record(
          'nested viewport ${phase == 0 ? 'control' : 'removed'}: inner height=${sample['height']} clipped by $viewport; cannot scroll',
        );
      }
    }
  }

  Future<void> _verifyTextureSampling(InAppWebViewController controller) async {
    // 两种背景用于验证真实滚动后的纹理，而不只是验证截图字节非空。
    await controller.evaluateJavascript(
      source: '''
      document.body.textContent = '';
      document.body.style.height = (innerHeight + 600) + 'px';
      document.body.style.background =
        'linear-gradient(#12372a 0 200px, #264653 200px 100%)';
      window.badViewport = [];
      const expectedWidth = innerWidth, expectedHeight = innerHeight;
      window.probeRunning = true;
      function probe() {
        if (innerWidth !== expectedWidth || innerHeight !== expectedHeight) {
          window.badViewport.push([innerWidth, innerHeight]);
        }
        if (window.probeRunning) requestAnimationFrame(probe);
      }
      requestAnimationFrame(probe);
    ''',
    );
    await Future<void>.delayed(const Duration(milliseconds: 160));
    for (var step = 0; step < 12; step++) {
      if (step == 4 || step == 8) {
        await controller.scrollTo(x: 0, y: step == 4 ? 400 : 0);
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
      if (!mounted) _fail('test disposed before menu');
      final navigator = Navigator.of(context);
      final density = MediaQuery.devicePixelRatioOf(context);
      Future<int?>? menu;
      if (step.isOdd) {
        menu = showMenu<int>(
          context: context,
          position: const RelativeRect.fromLTRB(300, 100, 20, 20),
          items: const [PopupMenuItem(value: 1, child: Text('测试菜单'))],
        );
      } else {
        // 点击走插件真实指针链路，覆盖此前每次按下都重新设置尺寸的路径。
        const position = Offset(60, 100);
        GestureBinding.instance.handlePointerEvent(
          const PointerHoverEvent(
            position: position,
            kind: PointerDeviceKind.mouse,
          ),
        );
        GestureBinding.instance.handlePointerEvent(
          const PointerDownEvent(
            pointer: 1,
            position: position,
            kind: PointerDeviceKind.mouse,
            buttons: kPrimaryMouseButton,
          ),
        );
        GestureBinding.instance.handlePointerEvent(
          const PointerUpEvent(
            pointer: 1,
            position: position,
            kind: PointerDeviceKind.mouse,
          ),
        );
      }
      await WidgetsBinding.instance.endOfFrame;
      final boundary =
          _textureKey.currentContext!.findRenderObject()
              as RenderTextureCaptureBoundary;
      final origin = boundary.localToGlobal(Offset.zero);
      for (final top in [true, false]) {
        final frame = await boundary.capture(
          Rect.fromLTWH(
            origin.dx,
            origin.dy + (top ? 0 : boundary.size.height - 24),
            boundary.size.width,
            24,
          ),
          maxWidth: 48,
          devicePixelRatio: density,
        );
        if (frame == null) _fail('missing texture at step $step');
        try {
          final expected = top && (step < 4 || step >= 8)
              ? const Color(0xff12372a)
              : const Color(0xff264653);
          final sample = await AdaptiveSurfaceColors.fromImage(frame.image);
          // GPU 缩放/颜色空间转换允许一个量化级误差，白帧与错误区域仍会失败。
          final color = sample?.color;
          if (color == null ||
              sample!.confidence < .8 ||
              (color.r - expected.r).abs() > 2 / 255 ||
              (color.g - expected.g).abs() > 2 / 255 ||
              (color.b - expected.b).abs() > 2 / 255) {
            _fail(
              'texture step $step top=$top: ${sample?.color}, expected $expected',
            );
          }
        } finally {
          frame.image.dispose();
        }
      }
      if (menu != null) {
        navigator.pop();
        await menu;
        // 允许菜单出场完成，再点击网页。
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    final violations = await controller.evaluateJavascript(
      source: '''
      window.probeRunning = false;
      JSON.stringify(window.badViewport);
    ''',
    );
    if (violations != '[]') _fail('capture changed viewport: $violations');
    _record(
      'texture stable $_cycle: 24 edge samples, 6 menus, scroll and pointer; no viewport changes',
    );
  }

  Future<void> _created(InAppWebViewController controller) async {
    try {
      _record('created $_cycle');
      controller.addJavaScriptHandler(
        handlerName: 'smokeNull',
        callback: (JavaScriptHandlerFunctionData data) => null,
      );
      controller.addJavaScriptHandler(
        handlerName: 'smokeEcho',
        callback: (JavaScriptHandlerFunctionData data) => data.args.first,
      );
      controller.addJavaScriptHandler(
        handlerName: 'smokeError',
        callback: (JavaScriptHandlerFunctionData data) =>
            throw StateError('smoke-handler-error'),
      );
      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(_entry.toString())),
      );
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final ready = await controller.evaluateJavascript(
          source: 'window.fixtureReady === true',
        );
        if (ready == true) break;
        if (i == 99) _fail('document did not start');
      }
      final text = await controller.evaluateJavascript(
        source: 'document.body.textContent',
      );
      if (text != '轻量宿主已就绪') _fail('unexpected body: $text');
      _record('ready $_cycle');
      if (_cycle == 0) {
        await _verifyNestedViewport(controller);
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(_entry.toString())),
        );
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (await controller.evaluateJavascript(
                source: 'window.fixtureReady === true',
              ) ==
              true) {
            break;
          }
          if (i == 99) {
            _fail('fixture did not return after nested viewport test');
          }
        }
      }
      // 经由真实 JS 桥和 MethodCodec 回执，区分 JSON "null" 与无返回值。
      // 后者包含未注册处理器及内置焦点通知，曾在原生解码后解引用空指针。
      _record('bridge replies starting $_cycle');
      final bridge = await controller.callAsyncJavaScript(
        functionBody: '''
        const call = (...args) => window.flutter_inappwebview.callHandler(...args);
        if (await call('smokeNull') !== null) throw Error('JSON null reply');
        if (await call('smokeMissing') !== null) throw Error('empty reply');
        for (const name of ['onWindowFocus', 'onWindowBlur']) {
          if (await call(name) !== null) throw Error(name + ' reply');
        }
        for (const value of [{text:'原生桥已就绪', list:[1, true, null]},
                             '字符串', 42, false]) {
          const reply = await call('smokeEcho', value);
          if (JSON.stringify(reply) !== JSON.stringify(value)) {
            throw Error('JSON reply mismatch');
          }
        }
        let rejected = false;
        try { await call('smokeError'); }
        catch (error) { rejected = String(error).includes('smoke-handler-error'); }
        if (!rejected) throw Error('handler error did not reject');
        return 'bridge-ready';
        ''',
      );
      if (bridge?.value != 'bridge-ready') {
        _fail('JS bridge: ${bridge?.toMap()}');
      }
      _record(
        'bridge null, missing, focus, JSON and error replies ready $_cycle',
      );
      // 微应用会创建 worker 和不透明来源的沙箱 frame，普通网页无法覆盖这些事件。
      final sandbox = await controller.callAsyncJavaScript(
        functionBody: '''
        const workerUrl = URL.createObjectURL(new Blob([
          "self.onmessage = () => self.postMessage('worker-ready')"
        ], {type:'text/javascript'}));
        const worker = new Worker(workerUrl);
        const workerReady = new Promise(resolve => {
          worker.onmessage = e => resolve(e.data); worker.postMessage('start');
        });
        const frame = document.createElement('iframe');
        frame.sandbox = 'allow-scripts';
        frame.srcdoc = '<script>parent.postMessage("frame-ready", "*")<\\/script>';
        const frameReady = new Promise(resolve => window.addEventListener(
          'message', e => {if(e.source === frame.contentWindow) resolve(e.data);}
        ));
        document.body.append(frame);
        const values = await Promise.all([workerReady, frameReady]);
        worker.terminate(); URL.revokeObjectURL(workerUrl); frame.remove();
        return values.join(',');
        ''',
      );
      if (sandbox?.value != 'worker-ready,frame-ready') {
        _fail('sandbox startup: ${sandbox?.toMap()}');
      }
      _record('worker and sandbox ready $_cycle');
      await controller.injectCSSCode(source: MiniAppHostAdapter.css);
      final state = await controller.evaluateJavascript(
        source: MiniAppHostAdapter.snapshot,
      );
      if (state is! Map || state['compatible'] != false) {
        _fail('unexpected host snapshot: $state');
      }
      final preview = await controller.takeScreenshot(
        screenshotConfiguration: ScreenshotConfiguration(
          compressFormat: CompressFormat.JPEG,
          quality: 70,
          rect: InAppWebViewRect(x: 0, y: 0, width: 48, height: 24),
        ),
      );
      if (preview == null || preview.isEmpty) _fail('empty viewport capture');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final boundary =
          _textureKey.currentContext!.findRenderObject()
              as RenderTextureCaptureBoundary;
      final global = boundary.localToGlobal(Offset.zero);
      for (final y in [0.0, boundary.size.height - 24]) {
        final frame = await boundary.capture(
          Rect.fromLTWH(global.dx, global.dy + y, boundary.size.width, 24),
          maxWidth: 48,
        );
        if (frame == null) _fail('missing Flutter texture capture');
        try {
          final sample = await AdaptiveSurfaceColors.fromImage(frame.image);
          _record('texture sample $_cycle: ${sample?.color}');
          if (sample == null ||
              sample.confidence < .8 ||
              sample.color != const Color(0xff12372a)) {
            _fail('Flutter texture not captured correctly');
          }
        } finally {
          frame.image.dispose();
        }
      }
      final viewport = await controller.evaluateJavascript(
        source: '({width: innerWidth, height: innerHeight})',
      ) as Map;
      for (final width in [viewport['width'] as num, 2400, 3840]) {
        final edge = await controller.takeScreenshot(
          screenshotConfiguration: ScreenshotConfiguration(
            compressFormat: CompressFormat.JPEG,
            quality: 65,
            rect: InAppWebViewRect(
              x: 0,
              y: 0,
              width: width.toDouble(),
              height: 24,
            ),
          ),
        );
        if (edge == null || edge.isEmpty) _fail('empty edge capture');
        File('build/mini-app-windows-edge.jpg').writeAsBytesSync(edge);
        _record('edge decode $_cycle width=$width');
        final frame = await SurfaceFrame.decode(
          edge,
          Rect.fromLTWH(0, 0, width.toDouble(), 24),
          maxWidth: 48,
        );
        try {
          final image = frame.image;
          if (image.width < 1 || image.width > 48 || image.height < 1) {
            _fail('invalid decoded edge ${image.width}x${image.height}');
          }
          final sample = await AdaptiveSurfaceColors.fromImage(image);
          if (sample == null) _fail('edge color unavailable');
          _record('edge decoded ${image.width}x${image.height}');
        } finally {
          frame.image.dispose();
        }
      }
      _record('host adapter and capture ready $_cycle');
      await _verifyTextureSampling(controller);
      if (_cycle == 3) {
        // 主消息循环结束时仍有 WebView，覆盖 Flutter controller 析构重入。
        _record(
          'PASS 3 disposed cycles; closing native window with live WebView',
        );
        await windowManager.destroy();
        return;
      }
      // 特意让 Dart 回执晚于事件返回与 WebView 关闭，验证原生对象持有与清理。
      _pending = Completer<void>();
      unawaited(
        controller.evaluateJavascript(
          source: "fetch('/delayed').catch(() => {});",
        ),
      );
      await _pending!.future;
      final keepAlive = _keepAlive;
      setState(() => _show = false);
      await WidgetsBinding.instance.endOfFrame;
      await InAppWebViewController.disposeKeepAlive(keepAlive);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      _record('disposed $_cycle with pending response');
      setState(() {
        _cycle++;
        _keepAlive = InAppWebViewKeepAlive();
        _show = true;
      });
    } catch (e) {
      _fail(e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: _show
        ? TextureCaptureBoundary(
            key: _textureKey,
            child: InAppWebView(
              key: ValueKey(_cycle),
              keepAlive: _keepAlive,
              webViewEnvironment: widget.environment,
              initialSettings: InAppWebViewSettings(
                useShouldInterceptRequest: true,
                useShouldOverrideUrlLoading: true,
                javaScriptBridgeForMainFrameOnly: true,
                javaScriptHandlersForMainFrameOnly: true,
              ),
              shouldOverrideUrlLoading: (_, action) async {
                _record('navigation $_cycle ${action.request.url?.path}');
                return NavigationActionPolicy.ALLOW;
              },
              onWebViewCreated: _created,
              initialUserScripts: UnmodifiableListView([
                UserScript(
                  groupName: 'viewport-fixture',
                  source: MiniAppHostAdapter.frameViewportScript(
                    _entry.resolve('/'),
                  ),
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  forMainFrameOnly: false,
                ),
                UserScript(
                  source: MiniAppHostAdapter.navigationScript(_entry),
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  forMainFrameOnly: true,
                ),
              ]),
              onReceivedServerTrustAuthRequest: (_, challenge) async {
                _record('certificate $_cycle');
                await Future<void>.delayed(const Duration(milliseconds: 80));
                final der = challenge
                    .protectionSpace
                    .sslCertificate
                    ?.x509Certificate
                    ?.encoded;
                // 不安装根证书、不改变客户端信任策略，仅接受本次本地测试证书。
                return ServerTrustAuthResponse(
                  action:
                      challenge.protectionSpace.host == '127.0.0.1' &&
                          listEquals(der, _serverCertificate)
                      ? ServerTrustAuthResponseAction.PROCEED
                      : ServerTrustAuthResponseAction.CANCEL,
                );
              },
              shouldInterceptRequest: (_, request) async {
                final path = request.url.path;
                _record('request $_cycle $path');
                final fixture = _nestedFixture(
                  path,
                  request.url.queryParameters['adapt'] == 'true',
                );
                if (fixture != null) {
                  return WebResourceResponse(
                    data: Uint8List.fromList(utf8.encode(fixture)),
                    contentType: path.endsWith('.css')
                        ? 'text/css'
                        : 'text/html',
                    contentEncoding: 'utf-8',
                    statusCode: 200,
                    reasonPhrase: 'OK',
                    headers: {
                      'Cache-Control': 'no-store',
                      if (path.endsWith('frame-host'))
                        'Content-Security-Policy':
                            "sandbox allow-scripts; style-src 'self'",
                    },
                  );
                }
                if (path == '/payload' || path == '/favicon.ico') return null;
                if (path == '/delayed') {
                  if (_pending?.isCompleted == false) _pending!.complete();
                  await Future<void>.delayed(const Duration(milliseconds: 250));
                } else {
                  await Future<void>.delayed(const Duration(milliseconds: 50));
                }
                final body = path == '/app'
                    ? '''<!doctype html><meta charset="utf-8">
          <style>html,body{margin:0;background:#12372a;color:white;}</style><body><script>
          fetch('/payload').then(r => r.text()).then(t => {
            document.body.textContent = t; window.fixtureReady = true;
          });</script></body>'''
                    : '轻量宿主已就绪';
                return WebResourceResponse(
                  data: Uint8List.fromList(utf8.encode(body)),
                  contentType: path == '/app' ? 'text/html' : 'text/plain',
                  contentEncoding: 'utf-8',
                  statusCode: 200,
                  reasonPhrase: 'OK',
                  headers: {'Cache-Control': 'no-store'},
                );
              },
              onReceivedError: (_, request, error) {
                _record(
                  'resource-error ${request.url.path}: ${error.description}',
                );
              },
            ),
          )
        : const SizedBox.shrink(),
  );
}

// 三层结构对应真实宿主：原生固定视口 → 隔离 frame-host → 应用文档。
// 对照组只缩外层，修复组安装生产 frame-host 样式；不修改应用自己的布局。
String? _nestedFixture(String path, bool fixed) => switch (path) {
  '/viewport-fixture' =>
    '''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>${MiniAppHostAdapter.css}</style>
    <main class="mini-app-page"><section class="mini-app-loader">
    <div class="mini-app-loader__viewport"><div class="mini-app-loader__frame">
    <iframe class="mini-app-frame-host" height="1200" src="${fixed ? '/mini-app-api/frame-host' : '/old-frame-host'}"></iframe>
    </div></div></section></main><script>
    addEventListener('message', e => {
      if (e.source === document.querySelector('iframe').contentWindow && e.data?.fixture === 'metrics') window.childMetrics = e.data;
    });</script>''',
  '/mini-app-api/frame-host' || '/old-frame-host' =>
    '''<!doctype html><link rel="stylesheet" href="/frame-host.css">
    <iframe sandbox="allow-scripts" height="1200" src="/runtime-fixture"></iframe><script>
    addEventListener('message', e => {
      if (e.source === parent && e.data?.fixture === 'scroll') {
        document.querySelector('iframe').contentWindow.postMessage(e.data, '*');
      }
      if (e.source === document.querySelector('iframe').contentWindow && e.data?.fixture === 'metrics') {
        parent.postMessage({...e.data, host: {origin:location.origin, path:location.pathname,
          adapted:document.querySelector('iframe').style.height === '100%', height:innerHeight,
          frameHeight:getComputedStyle(document.querySelector('iframe')).height}}, '*');
      }
    });</script>''',
  '/frame-host.css' => 'html,body{margin:0;width:100%;height:100%;overflow:hidden}iframe{display:block;width:100%;border:0}',
  '/runtime-fixture' =>
    '''<!doctype html><style>body{margin:0;height:1200px;background:linear-gradient(#12372a,#264653)}</style><body><script>
    function report() { parent.postMessage({fixture:'metrics',height:innerHeight,
      scrollHeight:document.documentElement.scrollHeight,scrollTop:scrollY}, '*'); }
    addEventListener('message', e => {
      if (e.source === parent && e.data?.fixture === 'scroll') {
        scrollBy(0, e.data.delta); requestAnimationFrame(report);
      }
    });
    addEventListener('load', report); addEventListener('resize', report); addEventListener('scroll', report);
    </script></body>''',
  _ => null,
};
