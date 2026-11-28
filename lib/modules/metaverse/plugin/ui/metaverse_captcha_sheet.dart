import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../l10n/s.dart';
import '../../../../services/webview_settings.dart';
import '../../../../services/windows_webview_environment_service.dart';
import '../../../../widgets/common/captcha_panel.dart';
import '../../../../widgets/common/hcaptcha_layout_script.dart';
import '../metaverse_captcha_request.dart';

Future<String?> showMetaverseCaptcha(
  BuildContext context,
  String pluginName,
  MetaverseCaptchaRequest request,
  void Function() checkActive,
) => showCaptchaSheet<String>(
  context: context,
  title: context.l10n.metaverse_captchaTitle,
  builder: (_) => MetaverseCaptchaContent(
    pluginName: pluginName,
    request: request,
    checkActive: checkActive,
  ),
);

/// 只加载宿主生成的验证文档，业务 origin 用于签发校验；不加载服务商页面。
class MetaverseCaptchaContent extends StatefulWidget {
  const MetaverseCaptchaContent({
    super.key,
    required this.pluginName,
    required this.request,
    required this.checkActive,
    this.challengeBuilder,
  });
  final String pluginName;
  final MetaverseCaptchaRequest request;
  final void Function() checkActive;
  final Widget Function(BuildContext, void Function(String, String))?
  challengeBuilder;
  @override
  State<MetaverseCaptchaContent> createState() =>
      _MetaverseCaptchaContentState();
}

class _MetaverseCaptchaContentState extends State<MetaverseCaptchaContent> {
  CaptchaPanelPhase _phase = CaptchaPanelPhase.loading;
  double? _height;
  Timer? _timeout;
  int _attempt = 0;
  bool _done = false;
  late final _lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached) {
        _fail();
      }
    },
  );
  @override
  void initState() {
    super.initState();
    _lifecycle;
    _start();
  }

  void _start() {
    _attempt++;
    _phase = CaptchaPanelPhase.loading;
    _height = null;
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 45), _fail);
  }

  void _fail() {
    if (!mounted || _done) return;
    _timeout?.cancel();
    setState(() {
      _attempt++;
      _phase = CaptchaPanelPhase.failed;
    });
  }

  void _event(int attempt, String type, String value) {
    if (!mounted ||
        _done ||
        attempt != _attempt ||
        _phase == CaptchaPanelPhase.failed) {
      return;
    }
    try {
      widget.checkActive();
    } catch (_) {
      _fail();
      return;
    }
    if (type == 'token' &&
        value.isNotEmpty &&
        value.length <= 16384 &&
        ModalRoute.of(context)?.isCurrent != false) {
      _done = true;
      _timeout?.cancel();
      Navigator.of(context).pop(value);
    } else if (type == 'challenge') {
      _timeout?.cancel();
      if (_phase != CaptchaPanelPhase.challenge) {
        setState(() => _phase = CaptchaPanelPhase.challenge);
      }
    } else if (type == 'height') {
      final height = double.tryParse(value);
      if (height != null &&
          height.isFinite &&
          height > 0 &&
          height <= 2048 &&
          height != _height) {
        setState(() => _height = height);
      }
    } else if (type == 'error') {
      _fail();
    }
  }

  @override
  void dispose() {
    _done = true;
    _timeout?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final attempt = _attempt;
    void event(String type, String value) => _event(attempt, type, value);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Text(
            '${widget.pluginName} · ${widget.request.origin.host}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Flexible(
          child: CaptchaPanel(
            phase: _phase,
            contentHeight: _height,
            message: _phase == CaptchaPanelPhase.failed
                ? context.l10n.captcha_expired
                : context.l10n.metaverse_captchaHint,
            onRetry: () => setState(_start),
            child: _phase == CaptchaPanelPhase.failed
                ? null
                : KeyedSubtree(
                    key: ValueKey(attempt),
                    child:
                        widget.challengeBuilder?.call(context, event) ??
                        _CaptchaWebView(
                          request: widget.request,
                          onEvent: event,
                        ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _CaptchaWebView extends StatelessWidget {
  const _CaptchaWebView({required this.request, required this.onEvent});
  final MetaverseCaptchaRequest request;
  final void Function(String, String) onEvent;
  @override
  Widget build(BuildContext context) {
    final origin = request.origin.origin;
    // Android 的 incognito 会清理共享 Cookie，不能用于此入口。
    // 生成文档的 CSP 仅允许验证提供方资源，不读取或注入论坛会话。
    final settings = WebViewSettings.visible
      ..incognito = !Platform.isAndroid
      ..sharedCookiesEnabled = false
      ..thirdPartyCookiesEnabled = false
      ..isInspectable = false
      ..supportZoom = false
      ..useOnDownloadStart = false
      ..useShouldOverrideUrlLoading = true
      ..javaScriptHandlersForMainFrameOnly = true
      ..javaScriptHandlersOriginAllowList = {'^${RegExp.escape(origin)}\$'};
    final color = Theme.of(context).colorScheme.surface
        .toARGB32()
        .toRadixString(16)
        .substring(2);
    return InAppWebView(
      webViewEnvironment: Platform.isWindows
          ? WindowsWebViewEnvironmentService.instance.environment
          : null,
      initialSettings: settings,
      initialData: InAppWebViewInitialData(
        data: metaverseCaptchaHtml(
          request,
          background: '#$color',
          dark: Theme.of(context).brightness == Brightness.dark,
        ),
        baseUrl: WebUri('$origin/'),
      ),
      onWebViewCreated: (controller) => controller.addJavaScriptHandler(
        handlerName: 'pluginCaptcha',
        callback: (args) {
          if (args.length == 2 && args[0] is String && args[1] is String) {
            onEvent(args[0] as String, args[1] as String);
          }
          return null;
        },
      ),
      shouldOverrideUrlLoading: (_, action) async =>
          action.isForMainFrame == true
          ? NavigationActionPolicy.CANCEL
          : NavigationActionPolicy.ALLOW,
      onCreateWindow: (_, _) async => false,
      onPermissionRequest: (_, request) async => PermissionResponse(
        resources: request.resources,
        action: PermissionResponseAction.DENY,
      ),
      onReceivedError: (_, request, _) {
        if (request.isForMainFrame == true) onEvent('error', 'network');
      },
      onReceivedServerTrustAuthRequest: (_, challenge) =>
          WebViewSettings.handleServerTrustAuthRequest(challenge),
    );
  }
}

String metaverseCaptchaHtml(
  MetaverseCaptchaRequest request, {
  required String background,
  required bool dark,
}) =>
    '''
<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://hcaptcha.com https://*.hcaptcha.com; style-src 'unsafe-inline'; frame-src https://hcaptcha.com https://*.hcaptcha.com; connect-src https://hcaptcha.com https://*.hcaptcha.com; img-src data: https://*.hcaptcha.com; base-uri 'none'; form-action 'none'">
<style>html,body{margin:0;background:$background}#challenge{margin:auto}</style></head><body><div id="challenge"></div><script>
$hCaptchaLayoutScript
const pending=[];
function flush(){if(typeof window.flutter_inappwebview?.callHandler!=='function')return;while(pending.length){const event=pending.shift();window.flutter_inappwebview.callHandler('pluginCaptcha',...event);}}
const send=(type,value='')=>{if(pending.length<16)pending.push([type,value]);flush();};
window.addEventListener('flutterInAppWebViewPlatformReady',flush);
let settled=false,stop;
const fail=()=>{if(!settled){settled=true;stop?.();send('error','verification');}};
function ready(){
 const panel=document.getElementById('challenge');
 const id=hcaptcha.render(panel,{sitekey:${jsonEncode(request.siteKey)},size:'invisible',theme:${jsonEncode(dark ? 'dark' : 'light')},
 callback:token=>{if(!settled){settled=true;stop?.();send('token',token);}},
 'open-callback':()=>{send('challenge');stop?.();stop=watchHCaptchaLayout(panel,height=>send('height',String(height)));},
 'close-callback':fail,'expired-callback':fail,'chalexpired-callback':fail,'error-callback':fail});
 hcaptcha.execute(id);
}
</script><script src="https://js.hcaptcha.com/1/api.js?onload=ready&render=explicit" async defer onerror="fail()"></script></body></html>''';
