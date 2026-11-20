import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/cookie/webview_cookie_priming.dart';
import '../../../services/webview_settings.dart';
import '../../../services/windows_webview_environment_service.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../services/cdk_client.dart';
import 'cdk_widgets.dart';

/// 由用户完成官网配置的 hCaptcha；页面不代点领取，也不提交兑换请求。
/// 设计依据: docs/cdk-integration.md
Future<String?> showCdkVerification(
  BuildContext context,
  CdkClient client,
  String projectId,
) async {
  CdkClient.projectPath(projectId);
  await client.check();
  await WebViewCookiePriming.instance.prime(CdkClient.origin);
  await client.check();
  if (!context.mounted) return null;
  return AppBottomSheet.show<String>(
    context: context,
    title: context.l10n.cdk_verifyTitle,
    style: AppSheetStyle.card,
    maxHeightFactor: 0.95,
    builder: (_) => CdkSessionContent(
      client: client,
      builder: (_) => _Verification(client: client, projectId: projectId),
    ),
  );
}

class _Verification extends StatefulWidget {
  const _Verification({required this.client, required this.projectId});
  final CdkClient client;
  final String projectId;
  @override
  State<_Verification> createState() => _VerificationState();
}

class _VerificationState extends State<_Verification> {
  InAppWebViewController? _controller;
  Timer? _timeout;
  bool _loading = true, _failed = false, _finished = false;
  Uri get _url => Uri.parse('${CdkClient.origin}/receive/${widget.projectId}');

  @override
  void initState() {
    super.initState();
    _timeout = Timer(const Duration(seconds: 45), () {
      if (mounted && _loading) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  Future<void> _install(InAppWebViewController controller) async {
    if (!mounted || _finished) return;
    final url = await controller.getUrl();
    if (url == null || Uri.parse('$url').origin != CdkClient.origin) return;
    await widget.client.check();
    if (!mounted) return;
    final background = Theme.of(context).colorScheme.surface
        .toARGB32()
        .toRadixString(16)
        .substring(2);
    await controller.evaluateJavascript(
      source: cdkVerificationScript(
        background: '#$background',
        dark: Theme.of(context).brightness == Brightness.dark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.72,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(context.l10n.cdk_verifyHint),
        ),
        if (_loading && !_failed) const M3eLinearProgress(),
        if (_failed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(context.l10n.cdk_verifyFailed),
          ),
        Expanded(
          child: AbsorbPointer(
            absorbing: _loading || _failed,
            child: Opacity(
              opacity: _loading || _failed ? 0 : 1,
              child: WebViewSettings.wrapWithScrollFix(
                InAppWebView(
                  webViewEnvironment: Platform.isWindows
                      ? WindowsWebViewEnvironmentService.instance.environment
                      : null,
                  initialUrlRequest: URLRequest(url: WebUri(_url.toString())),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    sharedCookiesEnabled: true,
                    thirdPartyCookiesEnabled: true,
                    supportZoom: false,
                    useShouldOverrideUrlLoading: true,
                    javaScriptHandlersForMainFrameOnly: true,
                    javaScriptHandlersOriginAllowList: {
                      '^${RegExp.escape(CdkClient.origin)}\$',
                    },
                  ),
                  initialUserScripts: WebViewSettings.compatPolyfillScripts,
                  onWebViewCreated: (controller) {
                    _controller = controller;
                    controller.addJavaScriptHandler(
                      handlerName: 'cdkCaptcha',
                      callback: (args) async {
                        if (!mounted || _finished || args.length != 2) {
                          return null;
                        }
                        final current = await controller.getUrl();
                        if (current == null ||
                            Uri.parse('$current').origin != CdkClient.origin) {
                          return null;
                        }
                        await widget.client.check();
                        if (!mounted) return null;
                        if (args[0] == 'ready') {
                          setState(() {
                            _loading = false;
                            _failed = false;
                          });
                        } else if (args[0] == 'error') {
                          setState(() {
                            _failed = true;
                            _loading = false;
                          });
                        } else if (args[0] == 'token' &&
                            args[1] is String &&
                            (args[1] as String).isNotEmpty &&
                            (args[1] as String).length <= 16384) {
                          _finished = true;
                          if (context.mounted) {
                            Navigator.of(context).pop(args[1] as String);
                          }
                        }
                        return null;
                      },
                    );
                  },
                  shouldOverrideUrlLoading: (_, action) async {
                    if (action.isForMainFrame != true) {
                      return NavigationActionPolicy.ALLOW;
                    }
                    return action.request.url?.toString() == _url.toString()
                        ? NavigationActionPolicy.ALLOW
                        : NavigationActionPolicy.CANCEL;
                  },
                  onLoadStop: (controller, _) async {
                    try {
                      await _install(controller);
                      await WebViewSettings.injectScrollFix(controller);
                    } catch (_) {
                      if (mounted) setState(() => _failed = true);
                    }
                  },
                  onReceivedError: (_, request, _) {
                    if (mounted && request.isForMainFrame == true) {
                      setState(() {
                        _failed = true;
                        _loading = false;
                      });
                    }
                  },
                  onReceivedServerTrustAuthRequest: (_, challenge) =>
                      WebViewSettings.handleServerTrustAuthRequest(challenge),
                ),
                getController: () => _controller,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// 从官网已渲染的验证 iframe 读取公开 sitekey，避免固化部署配置。
/// 独立验证层遮住原页面的领取按钮；脚本只回传验证码，不发业务请求。
String cdkVerificationScript({
  required String background,
  required bool dark,
}) =>
    '''
(() => {
  if (window.__fluxdoCdkCaptcha) return;
  window.__fluxdoCdkCaptcha = true;
  const send = (type, value) => window.flutter_inappwebview.callHandler('cdkCaptcha', type, value);
  const panel = document.createElement('div');
  panel.style.cssText = 'position:fixed;inset:0;z-index:2147483646;display:flex;align-items:flex-start;justify-content:center;padding-top:24px;overflow:auto';
  panel.style.background = ${jsonEncode(background)};
  // 在原页面形成后再挂载，保留验证服务初始化所需的脚本。
  document.body.appendChild(panel);
  let attempts = 0;
  const timer = setInterval(() => {
    if (++attempts > 120) { clearInterval(timer); send('error', 'unavailable'); return; }
    if (!window.hcaptcha || typeof window.hcaptcha.render !== 'function') return;
    let sitekey;
    for (const frame of document.querySelectorAll('iframe[src]')) {
      try {
        const url = new URL(frame.src);
        if (url.protocol !== 'https:' || !(url.hostname === 'hcaptcha.com' || url.hostname.endsWith('.hcaptcha.com'))) continue;
        sitekey = new URLSearchParams(url.hash.slice(1)).get('sitekey') || url.searchParams.get('sitekey');
        if (sitekey) break;
      } catch (_) {}
    }
    if (!sitekey) return;
    clearInterval(timer);
    try {
      window.hcaptcha.render(panel, {
        sitekey, size: window.innerWidth < 320 ? 'compact' : 'normal', theme: ${jsonEncode(dark ? 'dark' : 'light')},
        callback: token => send('token', token),
        'expired-callback': () => send('error', 'expired'),
        'error-callback': () => send('error', 'verification')
      });
      send('ready', '');
    } catch (_) { send('error', 'render'); }
  }, 250);
})();
''';
