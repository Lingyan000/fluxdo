import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_icons/app_icons.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../../../l10n/s.dart';
import '../../../services/network/cookie/webview_cookie_priming.dart';
import '../../../services/webview_settings.dart';
import '../../../services/windows_webview_environment_service.dart';
import '../../../utils/link_launcher.dart';
import '../../../widgets/common/app_bottom_sheet.dart';
import '../models/cdk_models.dart';
import '../services/cdk_client.dart';
import 'cdk_project_widgets.dart';
import 'cdk_widgets.dart';

/// 确认和验证共用一个原生面板，只有官网要求做题时显示 WebView。
/// 设计依据: docs/cdk-integration.md
Future<String?> showCdkVerification(
  BuildContext context,
  CdkClient client,
  CdkProject project, {
  Future<String?> Function()? verify,
}) => AppBottomSheet.show<String>(
  context: context,
  title: project.paid
      ? context.l10n.cdk_confirmPaid
      : context.l10n.cdk_confirmReceive,
  style: AppSheetStyle.card,
  showDragHandle: true,
  maxHeightFactor: 0.95,
  contentPadding: EdgeInsets.zero,
  builder: (_) => CdkSessionContent(
    client: client,
    builder: (_) =>
        CdkClaimContent(client: client, project: project, verify: verify),
  ),
);

enum CdkVerificationPhase { confirmation, preparing, challenge, failed }

class CdkVerificationEvent {
  const CdkVerificationEvent(this.type, [this.value = '']);
  final String type;
  final String value;
}

typedef CdkChallengeBuilder = Widget Function(
  BuildContext context,
  ValueChanged<CdkVerificationEvent> onEvent,
);

/// 与平台视图分离的原生流程，可用模拟验证服务回归取消、重试和会话切换。
class CdkClaimContent extends StatefulWidget {
  const CdkClaimContent({
    super.key,
    required this.client,
    required this.project,
    this.verify,
    this.challengeBuilder,
  });
  final CdkClient client;
  final CdkProject project;
  final Future<String?> Function()? verify;
  final CdkChallengeBuilder? challengeBuilder;
  @override
  State<CdkClaimContent> createState() => _CdkClaimContentState();
}

class _CdkClaimContentState extends State<CdkClaimContent> {
  CdkVerificationPhase _phase = CdkVerificationPhase.confirmation;
  String _failure = '';
  int _attempt = 0;
  bool _finished = false;
  Timer? _timeout;
  late final _lifecycle = AppLifecycleListener(
    onStateChange: (state) {
      if (state == AppLifecycleState.hidden ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        _interrupt();
      }
    },
  );

  bool get _running =>
      _phase == CdkVerificationPhase.preparing ||
      _phase == CdkVerificationPhase.challenge;

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  void _interrupt() {
    if (_running) _fail('interrupted');
  }

  void _invalidate() {
    _finished = true;
    _attempt++;
    _timeout?.cancel();
  }

  void _cancel() {
    _invalidate();
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _attempt++;
    _timeout?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _fail(String reason) {
    if (!mounted || _finished) return;
    _timeout?.cancel();
    setState(() {
      _attempt++;
      _failure = reason;
      _phase = CdkVerificationPhase.failed;
    });
  }

  Future<void> _begin() async {
    if (_running || _finished) return;
    final attempt = ++_attempt;
    setState(() => _phase = CdkVerificationPhase.preparing);
    _timeout = Timer(const Duration(seconds: 45), () {
      if (mounted && attempt == _attempt) _fail('timeout');
    });
    try {
      await widget.client.check();
      if (!mounted || attempt != _attempt) return;
      if (widget.verify != null) {
        final token = await widget.verify!();
        if (!mounted || attempt != _attempt) return;
        if (token == null) {
          _cancel();
        } else {
          await _event(CdkVerificationEvent('token', token), attempt);
        }
      }
    } catch (_) {
      if (mounted && attempt == _attempt) _fail('unavailable');
    }
  }

  Future<void> _event(CdkVerificationEvent event, int attempt) async {
    if (!mounted || _finished || !_running || attempt != _attempt) return;
    if (event.type == 'challenge') {
      _timeout?.cancel(); // 做题时遵循验证服务的有效期，不用加载超时打断用户。
      setState(() => _phase = CdkVerificationPhase.challenge);
    } else if (event.type == 'error') {
      _fail(event.value);
    } else if (event.type == 'token' &&
        event.value.isNotEmpty &&
        event.value.length <= 16384) {
      try {
        await widget.client.check();
        if (!mounted ||
            _finished ||
            attempt != _attempt ||
            !_running ||
            ModalRoute.of(context)?.isCurrent == false) {
          return;
        }
        _finished = true;
        _timeout?.cancel();
        Navigator.of(context).pop(event.value);
      } catch (_) {
        if (mounted && attempt == _attempt) _fail('unavailable');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final t = Theme.of(context);
    final p = widget.project;
    final attempt = _attempt;
    final failed = _phase == CdkVerificationPhase.failed;
    final challenge = _phase == CdkVerificationPhase.challenge;
    final errorText = switch (_failure) {
      'expired' => l.cdk_verifyExpired,
      'closed' => l.cdk_verifyClosed,
      'interrupted' => l.cdk_verifyInterrupted,
      _ => l.cdk_verifyFailed,
    };
    return PopScope<String>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _invalidate();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: _running
                ? SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.68,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                          child: Text(
                            challenge
                                ? l.cdk_verifyHint
                                : l.cdk_verifyPreparing,
                            style: t.textTheme.bodyMedium,
                          ),
                        ),
                        Expanded(
                          child: Stack(
                            children: [
                              if (widget.verify == null)
                                Positioned.fill(
                                  child: ExcludeSemantics(
                                    excluding: !challenge,
                                    child: IgnorePointer(
                                      ignoring: !challenge,
                                      child: Opacity(
                                        opacity: challenge ? 1 : 0,
                                        child: KeyedSubtree(
                                          key: ValueKey(attempt),
                                          child:
                                              widget.challengeBuilder?.call(
                                                context,
                                                (event) => unawaited(
                                                  _event(event, attempt),
                                                ),
                                              ) ??
                                              _CdkChallenge(
                                                client: widget.client,
                                                projectId: p.id,
                                                onEvent: (event) => unawaited(
                                                  _event(event, attempt),
                                                ),
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (!challenge)
                                Positioned.fill(
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const LoadingSpinner(size: 40),
                                        const SizedBox(height: 20),
                                        Text(
                                          l.cdk_verifyTitle,
                                          style: t.textTheme.titleMedium,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Symbols.key_rounded,
                              color: context.emphasis.accent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                p.name,
                                style: t.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        CdkPrice(project: p, prominent: true),
                        const SizedBox(height: 16),
                        CdkPerforation(color: t.colorScheme.outlineVariant),
                        const SizedBox(height: 16),
                        Text(
                          p.paid ? l.cdk_paidHint : l.cdk_freeHint,
                          style: t.textTheme.bodyMedium,
                        ),
                        if (failed) ...[
                          const SizedBox(height: 20),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              errorText,
                              style: t.textTheme.bodyMedium?.copyWith(
                                color: t.colorScheme.error,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => launchExternalLink(
                              context,
                              '${CdkClient.origin}/receive/${p.id}',
                              mode: LinkOpenMode.inApp,
                            ),
                            icon: const Icon(Symbols.open_in_browser_rounded),
                            label: Text(l.cdk_openWebsite),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          l.cdk_captchaDisclosure,
                          style: t.textTheme.bodySmall,
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: () => launchExternalLink(
                                context,
                                'https://www.hcaptcha.com/privacy',
                                mode: LinkOpenMode.inApp,
                              ),
                              child: Text(l.cdk_captchaPrivacy),
                            ),
                            TextButton(
                              onPressed: () => launchExternalLink(
                                context,
                                'https://www.hcaptcha.com/terms',
                                mode: LinkOpenMode.inApp,
                              ),
                              child: Text(l.cdk_captchaTerms),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                TextButton(onPressed: _cancel, child: Text(l.common_cancel)),
                const SizedBox(width: 16),
                if (!_running)
                  Expanded(
                    child: FilledButton(
                      onPressed: _begin,
                      child: Text(failed ? l.common_retry : l.common_confirm),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

bool isCdkVerificationUrl(Uri? url, String projectId) =>
    url != null &&
    url.scheme == 'https' &&
    url.hasAuthority &&
    url.host.isNotEmpty &&
    url.origin == CdkClient.origin &&
    url.userInfo.isEmpty &&
    url.path == '/receive/$projectId' &&
    url.query.isEmpty &&
    url.fragment.isEmpty;

class _CdkChallenge extends StatefulWidget {
  const _CdkChallenge({
    required this.client,
    required this.projectId,
    required this.onEvent,
  });
  final CdkClient client;
  final String projectId;
  final ValueChanged<CdkVerificationEvent> onEvent;
  @override
  State<_CdkChallenge> createState() => _CdkChallengeState();
}

class _CdkChallengeState extends State<_CdkChallenge> {
  InAppWebViewController? _controller;
  bool _primed = false;
  Uri get _url => Uri.parse('${CdkClient.origin}/receive/${widget.projectId}');

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      CdkClient.projectPath(widget.projectId);
      await widget.client.check();
      if (!mounted) return;
      await WebViewCookiePriming.instance.prime(CdkClient.origin);
      await widget.client.check();
      if (mounted) setState(() => _primed = true);
    } catch (_) {
      _send(const CdkVerificationEvent('error', 'unavailable'));
    }
  }

  void _send(CdkVerificationEvent event) {
    if (mounted) widget.onEvent(event);
  }

  Future<bool> _trusted(InAppWebViewController controller) async =>
      isCdkVerificationUrl(
        Uri.tryParse('${await controller.getUrl()}'),
        widget.projectId,
      );

  Future<void> _install(InAppWebViewController controller) async {
    if (!mounted || !await _trusted(controller)) return;
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
  Widget build(BuildContext context) {
    if (!_primed) return const SizedBox.expand();
    final settings = WebViewSettings.visible
      ..supportZoom = false
      ..isInspectable = false
      ..useOnDownloadStart = false
      ..useShouldOverrideUrlLoading = true
      ..javaScriptHandlersForMainFrameOnly = true
      ..javaScriptHandlersOriginAllowList = {
        '^${RegExp.escape(CdkClient.origin)}\$',
      };
    return WebViewSettings.wrapWithScrollFix(
      InAppWebView(
        webViewEnvironment: Platform.isWindows
            ? WindowsWebViewEnvironmentService.instance.environment
            : null,
        initialUrlRequest: URLRequest(url: WebUri(_url.toString())),
        initialSettings: settings,
        initialUserScripts: WebViewSettings.compatPolyfillScripts,
        onWebViewCreated: (controller) {
          _controller = controller;
          controller.addJavaScriptHandler(
            handlerName: 'cdkCaptcha',
            callback: (args) async {
              try {
                if (!mounted ||
                    args.length != 2 ||
                    args[0] is! String ||
                    args[1] is! String ||
                    !await _trusted(controller)) {
                  return null;
                }
                await widget.client.check();
                _send(
                  CdkVerificationEvent(args[0] as String, args[1] as String),
                );
              } catch (_) {
                _send(const CdkVerificationEvent('error', 'unavailable'));
              }
              return null;
            },
          );
        },
        shouldOverrideUrlLoading: (_, action) async {
          if (action.isForMainFrame != true) {
            return NavigationActionPolicy.ALLOW;
          }
          return isCdkVerificationUrl(
                Uri.tryParse('${action.request.url}'),
                widget.projectId,
              )
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
        onLoadStop: (controller, _) async {
          try {
            await _install(controller);
            await WebViewSettings.injectScrollFix(controller);
          } catch (_) {
            _send(const CdkVerificationEvent('error', 'unavailable'));
          }
        },
        onReceivedError: (_, request, _) {
          if (request.isForMainFrame == true) {
            _send(const CdkVerificationEvent('error', 'network'));
          }
        },
        onReceivedHttpError: (_, request, _) {
          if (request.isForMainFrame == true) {
            _send(const CdkVerificationEvent('error', 'network'));
          }
        },
        onReceivedServerTrustAuthRequest: (_, challenge) =>
            WebViewSettings.handleServerTrustAuthRequest(challenge),
      ),
      getController: () => _controller,
    );
  }
}

/// 从官网的 iframe 读取公开配置，独立执行验证，绝不调用官网的领取回调。
String cdkVerificationScript({
  required String background,
  required bool dark,
}) =>
    '''
(() => {
  if (window.__fluxdoCdkCaptcha) return;
  window.__fluxdoCdkCaptcha = true;
  const send = (type, value) => window.flutter_inappwebview.callHandler('cdkCaptcha', type, value);
  // 隐藏既有业务页面，新建的验证题目仍由 hCaptcha 自己排版和处理交互。
  for (const node of document.body.children) {
    node.style.visibility = 'hidden';
    node.inert = true;
  }
  document.documentElement.style.background = ${jsonEncode(background)};
  document.body.style.background = ${jsonEncode(background)};
  document.body.style.margin = '0';
  const panel = document.createElement('div');
  document.body.appendChild(panel);
  let attempts = 0;
  let settled = false;
  const fail = reason => {
    if (settled) return;
    settled = true;
    send('error', reason);
  };
  const timer = setInterval(() => {
    if (++attempts > 120) { clearInterval(timer); fail('unavailable'); return; }
    if (!window.hcaptcha || typeof window.hcaptcha.render !== 'function' || typeof window.hcaptcha.execute !== 'function') return;
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
      const widgetId = window.hcaptcha.render(panel, {
        sitekey, size: 'invisible', theme: ${jsonEncode(dark ? 'dark' : 'light')},
        callback: token => {
          if (settled) return;
          settled = true;
          send('token', token);
        },
        'open-callback': () => { if (!settled) send('challenge', ''); },
        'close-callback': () => fail('closed'),
        'expired-callback': () => fail('expired'),
        'chalexpired-callback': () => fail('expired'),
        'error-callback': () => fail('verification')
      });
      send('ready', '');
      window.hcaptcha.execute(widgetId);
    } catch (_) { fail('render'); }
  }, 250);
})();
''';
