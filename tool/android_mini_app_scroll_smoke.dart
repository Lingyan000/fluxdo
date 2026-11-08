// Android 真实触摸回归，无社区请求和账号数据。
// flutter run -d <emulator> -t tool/android_mini_app_scroll_smoke.dart
// 默认 Fixed：持续取色，上下往返滑动、选择 Daily/Weekly、开关原生菜单。
// Switch 切换 Legacy 后重载同一夹具：局部截图后 touchmove 仍到达但不滚动。
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fluxdo/modules/mini_apps/mini_app_host_adapter.dart';
import 'package:fluxdo/modules/mini_apps/mini_app_modal_blur.dart';
import 'package:fluxdo/services/webview_surface_capture.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _TouchProbe()));
}

class _TouchProbe extends StatefulWidget {
  const _TouchProbe();
  @override
  State<_TouchProbe> createState() => _TouchProbeState();
}

class _TouchProbeState extends State<_TouchProbe>
    with SingleTickerProviderStateMixin {
  static final _site = Uri.parse('https://mini-app.test');
  InAppWebViewController? _controller;
  late final Widget _webView;
  final _viewport = GlobalKey();
  bool _legacyCrop = false;
  int _down = 0;
  Timer? _sample;
  bool _sampling = true;
  bool _capturing = false;
  int _captures = 0;
  final _pointers = <int>{};
  DateTime _idleSince = DateTime.now();
  final _blur = MiniAppModalBlur();
  late final AnimationController _menuAnimation;
  MiniAppModalFrameLease? _menuFrame;
  bool _menuOpen = false;

  @override
  void initState() {
    super.initState();
    _menuAnimation =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 280),
        )..addListener(() {
          _menuFrame?.onBlurSigmaChanged(18 * _menuAnimation.value);
        });
    _webView = InAppWebView(
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldInterceptRequest: true,
        javaScriptBridgeForMainFrameOnly: true,
        javaScriptHandlersForMainFrameOnly: true,
        contentInsetAdjustmentBehavior:
            ScrollViewContentInsetAdjustmentBehavior.NEVER,
        overScrollMode: OverScrollMode.NEVER,
        disallowOverScroll: true,
        iframeAllowFullscreen: true,
      ),
      initialUserScripts: UnmodifiableListView([
        UserScript(
          source: MiniAppHostAdapter.frameViewportScript(_site),
          forMainFrameOnly: false,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'metrics',
          callback: (args) => debugPrint('SCROLL_SMOKE ${jsonEncode(args)}'),
        );
        _load();
        _sample = Timer.periodic(const Duration(seconds: 2), (_) async {
          if (!_sampling ||
              _menuOpen ||
              _capturing ||
              _pointers.isNotEmpty ||
              DateTime.now().difference(_idleSince).inMilliseconds < 500) {
            return;
          }
          final box =
              _viewport.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return;
          _capturing = true;
          try {
            final viewport = box.localToGlobal(Offset.zero) & box.size;
            final density = MediaQuery.devicePixelRatioOf(context);
            for (final top in [true, false]) {
              if (_pointers.isNotEmpty) break;
              final local = Rect.fromLTWH(
                0,
                top ? 0 : box.size.height - 24,
                box.size.width,
                24,
              );
              if (_legacyCrop) {
                await controller.takeScreenshot(
                  screenshotConfiguration: ScreenshotConfiguration(
                    rect: InAppWebViewRect(
                      x: local.left,
                      y: local.top,
                      width: local.width,
                      height: local.height,
                    ),
                    snapshotWidth: 48 / density,
                  ),
                );
              } else {
                final frame = await WebViewSurfaceCapture.capture(
                  takeScreenshot: (config) => controller.takeScreenshot(
                    screenshotConfiguration: config,
                  ),
                  platform: TargetPlatform.android,
                  viewport: viewport,
                  region: local.shift(viewport.topLeft),
                  devicePixelRatio: density,
                  maxWidth: 48,
                );
                if (frame == null) throw StateError('Missing capture');
                frame.image.dispose();
              }
            }
            debugPrint(
              'CAPTURE ${_legacyCrop ? "legacy" : "fixed"} ${++_captures}',
            );
          } finally {
            _capturing = false;
          }
        });
      },
      shouldInterceptRequest: (_, request) async {
        final uri = Uri.parse(request.url.toString());
        if (uri.host != _site.host) {
          throw StateError('Unexpected network request');
        }
        final path = uri.path;
        final body = switch (path) {
          '/app' =>
            '''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>${MiniAppHostAdapter.css}</style>
            <main class="mini-app-page"><section class="mini-app-loader"><div class="mini-app-loader__viewport"><div class="mini-app-loader__frame">
            <iframe class="mini-app-frame-host" height="1200" src="/mini-app-api/frame-host"></iframe>
            </div></div></section></main><script>
              addEventListener('message', e => {
                if(e.source === document.querySelector('iframe').contentWindow)
                  window.flutter_inappwebview.callHandler('metrics',e.data);
              });
            </script>''',
          '/mini-app-api/frame-host' || '/old-host' =>
            '''<!doctype html>
            <link rel="stylesheet" href="/host.css">
            <iframe height="1200" sandbox="allow-scripts" src="/runtime"></iframe>
            <script>addEventListener('message', e => {
              if(e.source === document.querySelector('iframe').contentWindow)
                parent.postMessage({...e.data,hostHeight:innerHeight,
                  frameHeight:document.querySelector('iframe').clientHeight,
                  fitted:document.querySelector('iframe').style.height},'*');
            });</script>''',
          '/host.css' => 'html,body{margin:0;width:100%;height:100%;overflow:hidden}iframe{display:block;width:100%;border:0}',
          '/runtime' =>
            '''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body{margin:0;font:24px sans-serif;background:#eee}main{height:1400px;background:linear-gradient(#ffd37a,#83c9dc)}header{height:150px}button,select{font:24px sans-serif;margin:24px}button{touch-action:manipulation}</style>
            <style>@keyframes tick{to{transform:rotate(360deg)}}aside{position:fixed;right:12px;bottom:12px;width:20px;height:20px;background:#f64;animation:tick 1s linear infinite}</style>
            <aside></aside><main><header>Nested app — swipe both directions</header><select><option>Daily</option><option>Weekly</option></select><button>Tap</button><p style="margin-top:180px">Middle</p><p style="margin-top:600px">Bottom</p></main>
            <script>
              let moves=0,starts=0,ends=0,cancels=0;
              function report(event) {parent.postMessage({event,scrollY,height:innerHeight,
                scrollHeight:document.documentElement.scrollHeight,moves,starts,ends,cancels},'*');}
              addEventListener('touchstart',()=>{starts++;report('start')},{passive:true});
              addEventListener('touchmove',()=>{moves++},{passive:true});
              addEventListener('touchend',()=>{ends++;report('end')},{passive:true});
              addEventListener('touchcancel',()=>{cancels++;report('cancel')},{passive:true});
              addEventListener('scroll',()=>report('scroll'),{passive:true});
              addEventListener('load',()=>report('ready'));
              addEventListener('change',()=>report('select-change'));
              addEventListener('resize',()=>report('resize'));
            </script>''',
          _ => '',
        };
        return WebResourceResponse(
          data: Uint8List.fromList(utf8.encode(body)),
          contentType: path.endsWith('.css') ? 'text/css' : 'text/html',
          contentEncoding: 'utf-8',
          statusCode: 200,
          reasonPhrase: 'OK',
          headers: {
            'Cache-Control': 'no-store',
            if (path.endsWith('host'))
              'Content-Security-Policy':
                  "style-src 'self'; script-src 'unsafe-inline'",
          },
        );
      },
    );
  }

  void _load() => _controller?.loadUrl(
    urlRequest: URLRequest(url: WebUri('${_site.origin}/app')),
  );

  @override
  void dispose() {
    _sample?.cancel();
    _menuAnimation.dispose();
    _blur.dispose();
    super.dispose();
  }

  Future<void> _showMenu() async {
    if (_menuOpen) return;
    _menuOpen = true;
    final density = MediaQuery.devicePixelRatioOf(context);
    final lease = _menuFrame = _blur.acquire(() async {
      if (_capturing) return null;
      final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
      final controller = _controller;
      if (box == null || controller == null || !box.hasSize) return null;
      _capturing = true;
      try {
        final bounds = box.localToGlobal(Offset.zero) & box.size;
        final frame = await WebViewSurfaceCapture.capture(
          takeScreenshot: (config) =>
              controller.takeScreenshot(screenshotConfiguration: config),
          platform: TargetPlatform.android,
          viewport: bounds,
          region: bounds,
          devicePixelRatio: density,
          maxWidth: 360,
        );
        return frame?.image;
      } finally {
        _capturing = false;
      }
    });
    final route = ModalBottomSheetRoute<void>(
      isScrollControlled: false,
      transitionAnimationController: _menuAnimation,
      builder: (_) => const SizedBox(
        height: 240,
        child: Center(child: Text('Native menu')),
      ),
    );
    await Navigator.of(context).push(route);
    lease.finish();
    await route.completed;
    _menuFrame = null;
    _menuOpen = false;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${_legacyCrop ? 'Legacy' : 'Fixed'} · $_down'),
      actions: [
        TextButton(
          onPressed: () => setState(() => _sampling = !_sampling),
          child: Text(_sampling ? 'Capture on' : 'Capture off'),
        ),
        TextButton(
          onPressed: () {
            setState(() => _legacyCrop = !_legacyCrop);
            _load();
          },
          child: const Text('Switch'),
        ),
        IconButton(icon: const Icon(Icons.more_vert), onPressed: _showMenu),
      ],
    ),
    body: SafeArea(
      child: Listener(
        key: _viewport,
        onPointerDown: (e) {
          _pointers.add(e.pointer);
          setState(() => _down++);
        },
        onPointerUp: (e) {
          _pointers.remove(e.pointer);
          _idleSince = DateTime.now();
        },
        onPointerCancel: (e) {
          _pointers.remove(e.pointer);
          _idleSince = DateTime.now();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            _webView,
            MiniAppModalFrame(blur: _blur),
          ],
        ),
      ),
    ),
  );
}
