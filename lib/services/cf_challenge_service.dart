import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert' show jsonDecode;
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:common_ui/common_ui.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import 'network/cookie/boundary_sync_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'network/cookie/cookie_logger.dart';
import 'log/log_writer.dart';
import 'local_notification_service.dart'; // 用于获取全局 navigatorKey
import 'cf_challenge_logger.dart';
import 'cf_verification_page_palette.dart';
import 'cf_verification_state.dart';
import 'cf_clearance_refresh_service.dart';
import 'embedded_browser_controller_pool.dart';
import 'toast_service.dart';
import 'webview_settings.dart';
import 'windows_webview_environment_service.dart';
import '../l10n/s.dart';
import '../providers/preferences_provider.dart';
import '../utils/blur_config.dart';
import '../widgets/common/cf_startup_verification.dart';
import '../widgets/common/cf_verification_dialog.dart';
import '../widgets/common/cloudflare_mark.dart';
import '../widgets/draggable_floating_pill.dart';

export 'cf_verification_state.dart';

CookieManager get _cfCookieManager =>
    WindowsWebViewEnvironmentService.instance.cookieManager;

/// 「切兼容模式」询问的三种去向。
enum _CompatPromptChoice {
  /// 本次会话改用浏览器网络栈发主站请求。
  enableCompat,

  /// 关掉自动过盾,改为撞盾时手动点验证。
  disableAutoVerify,

  /// 什么都不做(含关闭弹窗)。
  dismiss,
}

/// 一次验证诉求对界面的打扰等级，按打扰程度递增。
///
/// 同一轮验证被多个请求共享时取所有等待者里的最高档，且只升不降：
/// 后台静默过盾期间有用户正在等的请求加入，展示随之立刻升级。
enum CfVerifyPresentation {
  /// 完全不可见：不影响当前使用的后台流程（如 WebView session bootstrap）。
  /// 需要人工操作或超时即静默放弃，不计失败、不进冷却，留给下一个
  /// 真正阻塞用户的请求再升级处理。
  hidden,

  /// 后台静默请求（timings / csrf 等）：显示胶囊；需要人工操作时只把
  /// 胶囊切到「点按完成」，不主动弹面板。
  pill,

  /// 用户正在等结果的请求：立即显示状态（胶囊，或启动页文案）；需要
  /// 人工操作或超时则自动弹出验证面板。
  blocking,

  /// 用户主动发起的验证：直接前台显示面板。
  foreground,
}

/// CF 验证服务
/// 处理 Cloudflare Turnstile 验证（仅手动模式）
class CfChallengeService {
  static final CfChallengeService _instance = CfChallengeService._internal();
  factory CfChallengeService() => _instance;
  CfChallengeService._internal();

  bool _isVerifying = false;
  Completer<CfVerificationState?>? _verifyCompleter;
  final _pageState = ValueNotifier<CfVerificationState?>(null);

  /// 当前或最近一次验证入口的快照，同一轮的所有等待者共享结果。
  ValueListenable<CfVerificationState?> get pageState => _pageState;
  Completer<void>? _manualTeardownCompleter;
  Future<void>? _completionCookieSync;

  /// 仅在本轮 Cookie 快照尚未落库时有值。
  Future<void>? get pendingCompletionCookieSync => _completionCookieSync;

  /// 等待本次已经发起的 Cookie 快照同步，不等待签发或续期新 Cookie。
  /// 页面可以先结束，原生重试再复用这次同步，避免读到同步前的 jar。
  Future<void> waitForCompletionCookieSync() async {
    await _completionCookieSync;
  }

  /// CF 验证是否正在进行中（用于外部判断是否应忽略路由变化）
  bool get isVerifying => _isVerifying;

  /// 等待当前手动验证 WebView 从 Widget 树移除并走完原生析构冷却。
  ///
  /// BrowserTrust 在拿到 clearance 后仍需要创建 Session Headless WebView；
  /// 不能只等验证结果，因为结果会早于 Windows WebView2 Controller 完全析构。
  Future<void> waitForManualTeardown() async {
    while (true) {
      final teardown = _manualTeardownCompleter;
      if (teardown == null) return;
      await teardown.future;
      if (!_isVerifying) return;
    }
  }

  /// CF 验证状态变化通知（true=进行中, false=空闲）。
  /// 拦截器 / ScreenTrack 等订阅它来在 CF 期间冻结业务流量与数据采集。
  final ValueNotifier<bool> inProgressNotifier = ValueNotifier<bool>(false);

  /// 验证页面已不再被 CF 挑战、可以恢复请求的时刻广播。
  /// 页面可能直接到达源站，不保证本轮发生过验证或签发过新 Cookie。
  /// [BrowserTrustCoordinator] 订阅它:WebView session bootstrap 因 CF 失败后,
  /// 等待 Dio 侧(或主动发起的)验证完成,再 force 重跑 bootstrap,避免两条线各自为政。
  final ValueNotifier<DateTime?> clearanceResolvedAt = ValueNotifier<DateTime?>(
    null,
  );

  /// 当前验证轮次的展示等级（null=空闲）。验证页与启动页订阅它决定呈现方式。
  final ValueNotifier<CfVerifyPresentation?> presentationNotifier =
      ValueNotifier<CfVerifyPresentation?>(null);

  /// 自带验证状态展示的宿主数量（如启动页）。大于 0 时验证页不显示胶囊，
  /// 状态交给宿主呈现。
  final ValueNotifier<int> statusHostCount = ValueNotifier<int>(0);

  final _statusHosts = <CfStartupVerificationHost>{};

  void registerStatusHost(CfStartupVerificationHost host) {
    if (_statusHosts.add(host)) statusHostCount.value = _statusHosts.length;
  }

  void unregisterStatusHost(CfStartupVerificationHost host) {
    if (_statusHosts.remove(host)) statusHostCount.value = _statusHosts.length;
  }

  /// 抬高当前验证轮次的展示等级（只升不降）；空闲时无效。
  void raisePresentation(CfVerifyPresentation level) {
    if (!_isVerifying) return;
    final current = presentationNotifier.value;
    if (current != null && current.index >= level.index) return;
    presentationNotifier.value = level;
  }

  /// 等待当前验证轮次（含原生析构冷却）结束；空闲时立即返回。
  Future<void> waitUntilIdle() {
    if (!_isVerifying) return Future.value();
    final completer = Completer<void>();
    void listener() {
      if (inProgressNotifier.value || completer.isCompleted) return;
      inProgressNotifier.removeListener(listener);
      completer.complete();
    }

    inProgressNotifier.addListener(listener);
    return completer.future;
  }

  /// 启动屏正在承接的验证可能稍后才要求勾选，等同一轮结束再退场。
  Future<void> waitForStartupVerification() async {
    final pending = _verifyCompleter;
    final presentation = presentationNotifier.value;
    if (pending == null ||
        pending.isCompleted ||
        presentation == null ||
        _statusHosts.isEmpty ||
        presentation == CfVerifyPresentation.hidden) {
      return;
    }
    await pending.future;
  }

  void _setVerifying(bool value) {
    if (_isVerifying == value) return;
    _isVerifying = value;
    if (value) {
      _verifyRound++;
      _verifyCompleter = Completer<CfVerificationState?>();
      _pageState.value = CfVerificationState.opening(_verifyRound);
      _completionCookieSync = null;
      final current = _manualTeardownCompleter;
      if (current == null || current.isCompleted) {
        _manualTeardownCompleter = Completer<void>();
      }
    }
    if (io.Platform.isWindows) {
      if (value) {
        // 不等待的第一阶段：立即阻止新的帖子 WebView 获取槽位，并通知
        // 已有 Controller 撤下；验证入口随后会 await 完整 drain。
        unawaited(EmbeddedBrowserControllerPool.instance.suspendAndDrain());
      } else {
        EmbeddedBrowserControllerPool.instance.resume();
      }
    }
    inProgressNotifier.value = value;
    if (!value) {
      presentationNotifier.value = null;
      final pending = _verifyCompleter;
      if (pending != null && !pending.isCompleted) {
        _pageState.value = _pageState.value?.withStage(
          CfVerificationStage.unconfirmed,
        );
        pending.complete(null);
      }
      _verifyCompleter = null;
      final teardown = _manualTeardownCompleter;
      if (teardown != null && !teardown.isCompleted) {
        teardown.complete();
      }
      _manualTeardownCompleter = null;
    }
  }

  /// 验证 WebView 关闭后，原生 WebView2 控制器的销毁是异步的（发生在插件
  /// 的后台线程），比 Flutter 侧 OverlayEntry.remove() 慢一截。如果上一个
  /// 还没销毁干净就立刻起下一个 InAppWebView，在 Windows 上会撞上
  /// flutter_inappwebview_windows_plugin 的一个原生崩溃（0xc0000005 访问越
  /// 界），连续多次 CF 验证失败重试（如连续重新授权触发盾）时复现过。
  /// 这里让 `_isVerifying` 多扛一小段时间，复用已有的 `_verifyCompleter`
  /// 排队机制把这段时间内的新验证请求全部合流，不需要额外状态。
  static const _postCleanupCooldown = Duration(milliseconds: 1200);
  static const _refreshRestartCooldown = Duration(milliseconds: 300);

  /// 是否在拦截到 CF 盾时自动弹出验证 UI（默认 true）
  /// 关闭后 [CfChallengeInterceptor] 命中 CF 盾时会静默 reject，
  /// 交给 ErrorView 提供"手动验证"入口。由 PreferencesNotifier 同步维护。
  bool autoVerifyEnabled = true;

  /// 请求把「自动过盾」开关持久化关闭。
  ///
  /// 服务层拿不到 Riverpod 容器,由 PreferencesNotifier 在初始化时注入
  /// (它才是这个开关的真正归属方,要写 SharedPreferences)。
  /// 未注入时只改内存态,不持久化 —— 不阻塞功能。
  Future<void> Function()? disableAutoVerifyRequest;

  BuildContext? _context;
  static DateTime? _lastToastAt;
  Future<bool>? _activeSessionCompatPrompt;

  /// 上次拒绝「切兼容」的时刻;超过 [_sessionCompatDeclineTtl] 后可再问。
  DateTime? _sessionCompatDeclinedAt;
  Completer<BuildContext>? _contextReadyCompleter;

  /// 冷却机制：连续失败 N 次后进入冷却期
  DateTime? _cooldownUntil;
  int _consecutiveFailures = 0;

  /// 验证轮次序号。每次真正起一轮验证(_setVerifying(true))时递增。
  ///
  /// 多个并发请求撞盾时会合流到同一轮验证(见 showManualVerify 的排队分支),
  /// 但它们各自拿到结果后会**各自**走后续处置。失败计数必须按轮次去重,
  /// 否则五个并发请求把一次时序抖动记成五次失败,瞬间打满阈值 → 冷却 +
  /// 弹切兼容询问,而用户全程无感(实测:启动时五个首屏请求同时撞盾,
  /// cookie 同步慢一拍,9 秒后自行恢复正常)。
  int _verifyRound = 0;

  /// 已被记过失败的轮次号,防止同一轮被多个等待者重复计数。
  int? _failureCountedRound;
  static const _cooldownDuration = Duration(seconds: 30);
  static const _ineffectiveClearanceCooldown = Duration(seconds: 60);
  static const _maxFailuresBeforeCooldown = 3;
  static const _toastCooldown = Duration(seconds: 2);

  /// 等待 navigator context 就绪的上限。
  ///
  /// 启动早期 context 通常几百毫秒内到位;等不到说明当前环境根本没有前台
  /// UI(后台 isolate 等),此时应放弃验证而不是挂死。
  static const _contextWaitTimeout = Duration(seconds: 10);

  /// "切兼容模式"询问被拒绝后的静默期。
  ///
  /// 此前一旦拒绝就沉默到登出,用户启动时随手点了取消,之后哪怕盾天天触发
  /// 也不再询问。给它加时效:既不反复打扰,也不永久放弃。
  static const _sessionCompatDeclineTtl = Duration(minutes: 30);

  /// 检查是否在冷却期
  bool get isInCooldown {
    if (_cooldownUntil == null) return false;
    if (DateTime.now().isAfter(_cooldownUntil!)) {
      _cooldownUntil = null;
      return false;
    }
    return true;
  }

  /// 冷却截止时刻(仅供诊断快照读取,不参与判定——判定请用 [isInCooldown])。
  DateTime? get cooldownUntil => _cooldownUntil;

  /// 连续验证失败次数(诊断用)。
  int get consecutiveFailures => _consecutiveFailures;

  /// 本次会话是否已被用户拒绝过"切兼容模式"询问(诊断用)。
  /// 当前是否处于「已拒绝切兼容」的静默期内(诊断用)。
  bool get sessionCompatPromptDeclined {
    final declinedAt = _sessionCompatDeclinedAt;
    if (declinedAt == null) return false;
    return DateTime.now().difference(declinedAt) < _sessionCompatDeclineTtl;
  }

  /// 重置冷却期和失败计数（验证成功后调用）
  void resetCooldown() {
    _cooldownUntil = null;
    _consecutiveFailures = 0;
    // 去重标记随计数一起清:下一轮失败要能重新记账
    _failureCountedRound = null;
    CfChallengeLogger.logCooldown(entering: false);
  }

  /// 当前验证轮次号。
  ///
  /// 拦截器在"验证成功但后续处置失败"时把它传给 [startCooldown],
  /// 让同一轮验证的多个等待者只记一次失败。
  int get verifyRound => _verifyRound;

  /// 记录一次验证失败，连续达到上限后进入冷却期。
  ///
  /// [round] 传入触发本次失败的验证轮次号(见 [verifyRound])。同一轮只记一次
  /// —— 多个并发请求撞盾会合流到同一轮验证,却各自走后续处置,不去重会把
  /// 一次失败放大成 N 次,瞬间打满阈值。不传则按独立失败计数(如验证本身
  /// 被用户取消,那与并发无关)。
  void startCooldown({int? round}) {
    if (round != null) {
      if (_failureCountedRound == round) {
        debugPrint('[CfChallenge] 轮次 $round 的失败已记过，跳过重复计数');
        return;
      }
      _failureCountedRound = round;
    }
    _consecutiveFailures++;
    if (_consecutiveFailures >= _maxFailuresBeforeCooldown) {
      _cooldownUntil = DateTime.now().add(_cooldownDuration);
      debugPrint(
        '[CfChallenge] 连续失败 $_consecutiveFailures 次，进入 ${_cooldownDuration.inSeconds}s 冷却期',
      );
      CfChallengeLogger.logCooldown(entering: true, until: _cooldownUntil);
    } else {
      debugPrint(
        '[CfChallenge] 验证失败 $_consecutiveFailures/$_maxFailuresBeforeCooldown，允许重试',
      );
    }
  }

  /// 验证页面已无挑战，但原生请求重试仍命中 CF 时立即冷却。
  ///
  /// 浏览器入口的放行不能证明原生 API 已恢复。两侧出口、网络栈或路径规则
  /// 可能不同；先阻止反复拉起相同的验证页面，再由实际请求结果判断恢复。
  void startIneffectiveClearanceCooldown() {
    _consecutiveFailures = _maxFailuresBeforeCooldown;
    _cooldownUntil = DateTime.now().add(_ineffectiveClearanceCooldown);
    debugPrint(
      '[CfChallenge] 验证入口已无盾，但原生请求仍命中 CF，'
      '进入 ${_ineffectiveClearanceCooldown.inSeconds}s 冷却期',
    );
    CfChallengeLogger.logCooldown(entering: true, until: _cooldownUntil);
  }

  static void showGlobalMessage(String message, {bool isError = true}) {
    final now = DateTime.now();
    if (_lastToastAt != null &&
        now.difference(_lastToastAt!) < _toastCooldown) {
      return;
    }
    _lastToastAt = now;
    if (isError) {
      ToastService.showError(message);
    } else {
      ToastService.showInfo(message);
    }
  }

  /// 原生链路在完成验证后仍被 CF 拒绝时，询问用户是否仅在本次会话
  /// 使用浏览器网络栈。并发失败请求共享同一个弹窗结果。
  Future<bool> confirmSessionCompatibilityMode() {
    if (sessionCompatPromptDeclined) return Future.value(false);
    final active = _activeSessionCompatPrompt;
    if (active != null) return active;

    late final Future<bool> future;
    future = _confirmSessionCompatibilityModeInternal().whenComplete(() {
      if (identical(_activeSessionCompatPrompt, future)) {
        _activeSessionCompatPrompt = null;
      }
    });
    _activeSessionCompatPrompt = future;
    return future;
  }

  Future<bool> _confirmSessionCompatibilityModeInternal() async {
    BuildContext? context = _context;
    if (context == null || !context.mounted) {
      context = navigatorKey.currentContext;
    }
    if (context == null || !context.mounted) return false;

    final choice = await showInteractionDialog<_CompatPromptChoice>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: Text(S.current.cf_sessionCompatTitle),
          // 三个动作横排放不下(中文约 360px、英文约 500px,而对话框可用宽度
          // 只有 280~320px,OverflowBar 会自动竖排,把"取消"顶到最上面、
          // 主次层级反过来)。故把第三条出路降级为正文里的文字链接:
          // 主次分明,且它紧跟在解释文字后面,阅读顺序自然。
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(S.current.cf_sessionCompatMessage),
              const SizedBox(height: 16),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () =>
                      Navigator.of(dialogContext)
                          .pop(_CompatPromptChoice.disableAutoVerify),
                  child: Text(
                    S.current.cf_sessionCompatDisableAuto,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_CompatPromptChoice.dismiss),
              child: Text(
                MaterialLocalizations.of(dialogContext).cancelButtonLabel,
              ),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext)
                      .pop(_CompatPromptChoice.enableCompat),
              child: Text(S.current.cf_sessionCompatEnable),
            ),
          ],
        );
      },
    );

    switch (choice) {
      case _CompatPromptChoice.enableCompat:
        return true;

      case _CompatPromptChoice.disableAutoVerify:
        autoVerifyEnabled = false;
        // 持久化交给设置层(它持有 SharedPreferences);未注入时只改内存态。
        await disableAutoVerifyRequest?.call();
        // 关掉自动过盾后不必再问兼容模式 —— 后续撞盾会静默 reject 并由
        // ErrorView 给出手动验证入口,不再走到本询问。
        _sessionCompatDeclinedAt = DateTime.now();
        showGlobalMessage(S.current.cf_autoVerifyDisabledHint, isError: false);
        CfChallengeLogger.log(
          '[PROMPT] User disabled auto verify from compat prompt',
        );
        return false;

      case _CompatPromptChoice.dismiss:
      case null:
        // 用户明确拒绝:进入静默期不再打扰。带时效而非永久——盾的成因
        // (出口 IP、代理配置)可能在半小时内就变了,那时值得再问一次。
        _sessionCompatDeclinedAt = DateTime.now();
        return false;
    }
  }

  void resetSessionCompatibilityDecision() {
    _sessionCompatDeclinedAt = null;
  }

  void setContext(BuildContext context) {
    _context = context;
    if (context.mounted) {
      _contextReadyCompleter ??= Completer<BuildContext>();
      if (!_contextReadyCompleter!.isCompleted) {
        _contextReadyCompleter!.complete(context);
      }
    }
  }

  /// 综合响应头 + 响应体判断 dio Response 是否是 CF 验证响应。
  ///
  /// Cloudflare 对所有 Challenge Page 定义了同一响应头 `cf-mitigated: challenge`。
  /// 即使传输适配器没有提供页面正文或正确的内容类型，也可据此识别。
  ///
  /// 状态码可能是 403 也可能是 429:
  /// - 普通 CF 盾(WAF / bot fight 等)→ 403 + cf-mitigated: challenge
  /// - 速率限制规则 action 配 managed_challenge / js_challenge / challenge → 429 + cf-mitigated: challenge
  /// 两种情况都应该交由 CfChallengeInterceptor 走验证流程,不能当成普通 403/429 处理。
  ///
  /// 历史上这里曾把 content-type 必须 text/html 作为前置条件,导致 dio 这种
  /// 默认 `Accept: application/json, text/plain, */*` 的客户端拿到 text/plain
  /// 时被漏掉, CfChallengeInterceptor 不弹手动验证。
  static bool isCfChallengeResponse(Response? response) {
    if (response == null) return false;
    final headers = response.headers;

    // 1. cf-mitigated: challenge — CF 官方权威信号,单独命中即判定。
    //    不再把 server 头当前置闸:部分传输通道下响应头可能缺失/走样,
    //    server 头一票否决会让挑战型 429 永远进不了验证自愈链路。
    if (headers['cf-mitigated']?.any(_isChallengeHeader) == true) return true;

    // 2. fallback: 不带 cf-mitigated 时用 body 兜底。挑战页一定是 text/html,
    //    content-type 明确为其他类型则排除(避免误判 Discourse 自己的
    //    plaintext/JSON 403);content-type 缺失时放行 body 判定,
    //    isCfChallenge 的标记(cf_chl_opt 等)足够特异,不会误伤业务响应。
    final contentType = headers.value('content-type') ?? '';
    if (contentType.isNotEmpty && !contentType.contains('text/html')) {
      return false;
    }

    return isCfChallenge(response.data);
  }

  static bool _isChallengeHeader(String value) =>
      value.trim().toLowerCase() == 'challenge';

  /// 检测是否是 CF 验证页面（用于 403 响应体判断）
  static bool isCfChallenge(dynamic responseData) {
    if (responseData == null) return false;
    final str = responseData.toString();
    // cf_chl_opt 是 CF 验证页面的可靠标记（challenge options JS 变量）
    if (str.contains('cf_chl_opt')) return true;
    // challenge-platform 路径需配合 cloudflare 标记，避免误匹配
    if (str.contains('challenge-platform') && str.contains('cloudflare')) {
      return true;
    }
    // "Just a moment" 需配合 CF 特征，避免误匹配用户内容
    if (str.contains('Just a moment') &&
        (str.contains('cloudflare') || str.contains('cf-challenge'))) {
      return true;
    }
    return false;
  }

  /// 检测页面 HTML 中是否有活跃的 CF 验证盾
  /// 用于判断已加载的页面是否仍在展示验证挑战
  static bool hasActiveCfChallenge(String html) {
    return html.contains('cf-turnstile') ||
        html.contains('challenge-running') ||
        html.contains('challenge-stage') ||
        html.contains('cf_chl_opt');
  }

  /// 响应头缺失时，以 Discourse 404 页的结构或错误类型作为源站证据。
  static bool isOriginNotFound(String html) =>
      _originNotFoundMarker.hasMatch(html);

  static final _originNotFoundMarker = RegExp(
    r'''\s(?:class|id)\s*=\s*["'][^"']*\b(?:page-not-found|discourse-no-results|404-body)\b[^"']*["']|"error_?type"\s*:\s*"not_?found"''',
    caseSensitive: false,
  );

  /// 显示手动验证页面
  /// true 表示入口已放行，可以重试业务请求。具体是否出现过挑战见 [verifyPage]。
  /// [forceForeground] 为 true 时直接前台显示，否则按 [CfVerifyPresentation.pill]
  /// 在后台尝试。
  Future<bool?> showManualVerify([
    BuildContext? context,
    bool forceForeground = true,
  ]) {
    return verify(
      context: context,
      presentation: forceForeground
          ? CfVerifyPresentation.foreground
          : CfVerifyPresentation.pill,
    );
  }

  /// 发起（或合流到进行中的）CF 验证，[presentation] 声明本次诉求的打扰等级。
  /// 返回值语义同 [showManualVerify]。
  Future<bool?> verify({
    BuildContext? context,
    CfVerifyPresentation presentation = CfVerifyPresentation.foreground,
  }) async => (await verifyPage(
    context: context,
    presentation: presentation,
  ))?.reachedOrigin;

  /// 返回本轮页面的实际观察结果。用户主动重试时可以清除冷却。
  Future<CfVerificationState?> verifyPage({
    BuildContext? context,
    CfVerifyPresentation presentation = CfVerifyPresentation.foreground,
    bool userInitiated = false,
  }) async {
    if (userInitiated) resetCooldown();
    // 检查冷却期
    if (isInCooldown) {
      debugPrint('[CfChallenge] In cooldown, skipping manual verify');
      CfChallengeLogger.log('[VERIFY] Skipped: in cooldown');
      return null;
    }

    final verifyUrl = '${AppConstants.baseUrl}/challenge';

    // 尝试获取 context：传入的 > 已设置的 > 全局 navigatorKey
    BuildContext? ctx = context ?? _context;
    if (ctx == null || !ctx.mounted) {
      // 使用全局 navigatorKey 作为备用
      final navState = navigatorKey.currentState;
      if (navState != null && navState.context.mounted) {
        ctx = navState.context;
        debugPrint('[CfChallenge] Using global navigatorKey context');
      }
    }

    // 启动时可能还没有可用的 context，等到 context 可用后立即弹出。
    //
    // 但这个等待必须有上限:后台 isolate(iOS 后台拉取)与无 UI 环境里
    // context 永远不会到来,无限等待会让请求挂死,只能靠系统任务超时收尸
    // (历史上后台拉取撞盾就是这个形态)。启动早期的等待仍然有效——那时
    // context 通常在几百毫秒内就绪。
    if (ctx == null || !ctx.mounted) {
      _contextReadyCompleter ??= Completer<BuildContext>();
      debugPrint('[CfChallenge] Waiting for context to be ready...');
      try {
        ctx = await _contextReadyCompleter!.future.timeout(_contextWaitTimeout);
      } on TimeoutException {
        debugPrint(
          '[CfChallenge] 等待 context 超时 '
          '(${_contextWaitTimeout.inSeconds}s),按无 UI 环境处理',
        );
        CfChallengeLogger.log(
          '[VERIFY] Skipped: no UI available after '
          '${_contextWaitTimeout.inSeconds}s',
          level: 'warning',
        );
        return null;
      }
    }
    if (!ctx.mounted) {
      debugPrint('[CfChallenge] Context no longer mounted');
      return null;
    }

    // 如果已经在验证中 (Overlay 存在)
    if (_isVerifying) {
      // 验证结果已产生但原生 WebView 仍在冷却析构时，直接复用刚完成的
      // 结果；不能再加入等待列表，否则旧流程已经清空列表后将无人完成它。
      final pending = _verifyCompleter!;
      if (!pending.isCompleted) raisePresentation(presentation);
      return pending.future;
    }

    _setVerifying(true);
    final openingRound = _verifyRound;
    final resultCompleter = _verifyCompleter!;
    presentationNotifier.value = presentation;

    // ignore: use_build_context_synchronously
    final overlayState =
        Overlay.maybeOf(ctx, rootOverlay: true) ??
        navigatorKey.currentState?.overlay;
    if (overlayState == null) {
      debugPrint('[CfChallenge] No overlay available for manual verify');
      CfChallengeLogger.log('[VERIFY] No overlay available');
      _setVerifying(false);
      return null;
    }

    final cookieJarService = CookieJarService();
    io.Cookie? backupCfClearance;
    Set<String>? oldWebViewClearances;
    try {
      if (io.Platform.isWindows) {
        await EmbeddedBrowserControllerPool.instance.suspendAndDrain();
      }
      // 等续期 WebView 销毁后再建验证页，避免 Windows 原生控制器重叠。
      await CfClearanceRefreshService().stop();
      backupCfClearance = await cookieJarService.getCfClearanceCookie();
      try {
        oldWebViewClearances = await BoundarySyncService.instance
            .readCookieValuesFromWebView(name: 'cf_clearance');
      } catch (e) {
        CfChallengeLogger.log(
          '[VERIFY] Failed to snapshot WebView clearances: $e',
        );
      }
      await cookieJarService.deleteCookie('cf_clearance');
      await cookieJarService.deleteWebViewCookie('cf_clearance');
    } catch (e) {
      final failure = _pageState.value!.withStage(
        CfVerificationStage.loadFailed,
      );
      _pageState.value = failure;
      CfChallengeLogger.log(
        '[VERIFY] Cannot prepare verification page: ${e.runtimeType}',
      );
      try {
        if (backupCfClearance != null) {
          await cookieJarService.restoreCfClearance(backupCfClearance);
        }
      } finally {
        resultCompleter.complete(failure);
        _setVerifying(false);
      }
      return failure;
    }
    if (!overlayState.mounted) {
      debugPrint('[CfChallenge] Overlay no longer mounted');
      CfChallengeLogger.log('[VERIFY] Overlay not mounted');
      try {
        if (backupCfClearance != null) {
          await cookieJarService.restoreCfClearance(backupCfClearance);
        }
      } finally {
        _setVerifying(false);
      }
      return null;
    }

    final oldClearanceValue = backupCfClearance == null
        ? null
        : CookieValueCodec.decode(backupCfClearance.value);
    late final OverlayEntry entry;
    ModalRoute<void>? interceptorRoute;
    ValueNotifier<bool>? interceptorPopAllowed;

    // Page Key 用于触发内部弹窗
    final pageKey = GlobalKey<_CfChallengePageState>();
    final BuildContext navigatorContext = ctx;

    void closeForegroundRoute() {
      final routeToClose = interceptorRoute;
      final allowPop = interceptorPopAllowed;
      interceptorRoute = null;
      interceptorPopAllowed = null;
      if (routeToClose != null && routeToClose.isActive) {
        // 绝不能 removeRoute：框架 _flushHistoryUpdates 的 remove 分支不会
        // 给下方路由补发 didPopNext（RouteObserver 也没有 didRemove 实现），
        // 下方页面的 RouteAware 订阅者（话题详情 ScreenTrack、视频、iframe）
        // 会永远停在「被覆盖」状态——曾表现为 CF 验证通过后 ScreenTrack 不再
        // start，阅读时长怎么滑动都不上报。放行 PopScope 后走正常 pop，让
        // 路由生命周期通知完整派发。canPop 变更要等下一帧重建才生效，pop
        // 放到 post-frame。
        allowPop!.value = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!routeToClose.isActive) return;
          final nav = routeToClose.navigator;
          if (nav == null) return;
          if (routeToClose.isCurrent) {
            nav.pop();
          } else {
            // 极端兜底：验证期间有别的路由压到它上面（正常不会发生——前台
            // 验证时全屏 Overlay 拦截所有交互）。pop 动画是异步的，无法同步
            // 回收到本 route，退化为 removeRoute。
            nav.removeRoute(routeToClose);
          }
        });
      }
    }

    void cleanup() {
      void removeEntry() {
        if (entry.mounted) entry.remove();
      }

      // 等待 Windows 插件派发完已有回调，再销毁平台视图。
      if (io.Platform.isWindows) {
        Future.delayed(_postCleanupCooldown, removeEntry);
      } else {
        removeEntry();
      }
      closeForegroundRoute();
      // 延迟释放 _isVerifying：给原生 WebView2 控制器留出真正销毁的时间，
      // 这段时间内的新验证请求会走上面的排队合流分支，而不是立刻起新
      // WebView 撞上销毁中的旧实例（见 _postCleanupCooldown 处注释）。
      Future.delayed(_postCleanupCooldown, () => _setVerifying(false));
    }

    void finish(CfVerificationState result) {
      if (resultCompleter.isCompleted) return;
      resultCompleter.complete(result);
      cleanup();
    }

    // 创建 OverlayEntry
    // 我们需要传递一个 promoteCallback 给 Page，让 Page 能调用 Service 来 push route
    void onPromoteToForeground(BuildContext pageContext) {
      if (interceptorRoute != null && interceptorRoute!.isActive) {
        return; // 已经有 Route 了
      }

      // Push 透明 Route 用于拦截返回键
      final allowPop = ValueNotifier(false);
      final route = InteractionPageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (context, _, _) {
          // canPop 由 cleanup 在验证结束时放行：验证期间拦截系统返回键
          // 弹退出确认；结束时必须让本 route 走正常 pop（而非 removeRoute），
          // 否则下方路由永远收不到 didPopNext（见 cleanup 内注释）。
          return ValueListenableBuilder<bool>(
            valueListenable: allowPop,
            builder: (context, canPop, _) {
              return PopScope(
                canPop: canPop,
                onPopInvokedWithResult: (didPop, result) async {
                  if (didPop) return;
                  if (!_isVerifying) return;

                  // 触发内部弹窗 via GlobalKey
                  pageKey.currentState?.handleBack();
                },
                // 使用 IgnorePointer 让点击事件穿透到下层的 Overlay (WebView)
                child: const IgnorePointer(child: SizedBox.expand()),
              );
            },
          );
        },
      );

      interceptorRoute = route;
      interceptorPopAllowed = allowPop;
      Navigator.of(pageContext).push(route).then((_) {
        if (identical(interceptorRoute, route)) {
          interceptorRoute = null;
          interceptorPopAllowed = null;
        }
        allowPop.dispose();
      });
    }

    entry = OverlayEntry(
      builder: (context) => CfChallengePage(
        key: pageKey,
        verifyUrl: verifyUrl,
        round: openingRound,
        presentation: presentationNotifier,
        onStateChanged: (state) {
          if (state.round == _verifyRound) _pageState.value = state;
        },
        onPageResult: finish,
        // 优先用调用方的 navigator context；它已失效时退回 OverlayEntry 自身的。
        onPromoteRequest: () => onPromoteToForeground(
          navigatorContext.mounted ? navigatorContext : context,
        ),
        onStartupClaimed: closeForegroundRoute,
        oldCfClearanceValue: oldClearanceValue,
        oldCfClearanceValues: oldWebViewClearances,
      ),
    );
    // 初始即前台时，页面在首帧后自行请求 promote（见 initState）。
    CfChallengeLogger.logVerifyStart(verifyUrl);
    CfChallengeLogger.log('[VERIFY] Presentation: ${presentation.name}');
    overlayState.insert(entry);

    final result = (await resultCompleter.future)!;
    // 只剩 hidden 诉求的一轮：放弃不代表用户失败，不计数、不冷却。
    final abandonedQuietly =
        !result.reachedOrigin &&
        presentationNotifier.value == CfVerifyPresentation.hidden;

    // 验证成功后重置冷却期
    if (result.reachedOrigin) {
      resetCooldown();
      // 广播验证入口已经无盾。是否签发新 Cookie、原生请求是否恢复是独立状态。
      clearanceResolvedAt.value = DateTime.now();
      // 验证页移除后，Windows WebView2 的原生 Controller 仍会异步析构。
      // 等验证冷却完成、帖子 WebView 池恢复后再错峰启动续期 WebView。
      Future.delayed(_postCleanupCooldown + _refreshRestartCooldown, () {
        if (!_isVerifying) {
          CfClearanceRefreshService().start();
        }
      });
    } else {
      // 验证失败，恢复备份的 cf_clearance（避免丢失可能仍有效的值）
      if (backupCfClearance != null) {
        await cookieJarService.restoreCfClearance(backupCfClearance);
        debugPrint('[CfChallenge] 验证失败，已恢复备份 cf_clearance');
      }
      if (abandonedQuietly) {
        CfChallengeLogger.log(
          '[VERIFY] Hidden verify abandoned, defer to next blocking request',
        );
        return result;
      }
      // 验证失败，启动冷却期
      startCooldown();
      debugPrint(
        '[CfChallenge] Verification failed, cooldown until $_cooldownUntil',
      );
    }

    return result;
  }

  /// 用户主动触发的验证入口：允许绕过冷却期。
  Future<bool?> showManualVerifyNow([
    BuildContext? context,
    bool forceForeground = true,
  ]) {
    resetCooldown();
    return showManualVerify(context, forceForeground);
  }
}

/// CF 验证页面
class CfChallengePage extends StatefulWidget {
  const CfChallengePage({
    super.key,
    required this.verifyUrl,
    required this.presentation,
    this.round = 0,
    this.onStateChanged,
    this.onPageResult,
    this.onResult,
    this.onPromoteRequest,
    this.onStartupClaimed,
    this.oldCfClearanceValue,
    this.oldCfClearanceValues,
  });

  final String verifyUrl;
  final int round;
  final ValueChanged<CfVerificationState>? onStateChanged;

  /// 本轮验证的展示等级（由 [CfChallengeService] 维护、只升不降）。非 foreground 时先在
  /// 后台尝试，需要人工操作或超时后按等级决定如何升级。
  final ValueListenable<CfVerifyPresentation?> presentation;
  final ValueChanged<CfVerificationState>? onPageResult;
  final ValueChanged<bool>? onResult;
  final VoidCallback? onPromoteRequest;
  final VoidCallback? onStartupClaimed;

  /// showManualVerify 在删除前备份的旧 cf_clearance 值（已解码）
  /// 用于可靠过滤 Windows 上 WebView 中未完全删除的残留旧值
  final String? oldCfClearanceValue;

  /// 删除前 WebView 中的全部旧值。空集合表示已确认没有旧值；null 表示
  /// 未取得快照，需要沿用页面初始化时的读取兜底。
  final Set<String>? oldCfClearanceValues;

  @override
  State<CfChallengePage> createState() => _CfChallengePageState();
}

class _CfChallengePageState extends State<CfChallengePage> {
  InAppWebViewController? _controller;
  // 插件在构造 InAppWebView 时创建平台组件，整轮验证共用这一份。
  InAppWebView? _webView;
  final _webViewKey = GlobalKey();
  final _pillKey = GlobalKey();
  CfStartupVerificationHost? _startupHost;
  bool get _startupActive => _startupHost != null;
  bool _pageNeeded = false;
  ({int document, Color surface, Color text})? _originalPagePalette;
  Rect? _panelRevealFrom;
  double _progress = 0;
  bool _hasMarkedPageReady = false;
  bool _hasPopped = false; // 防止重复 pop
  late bool _isBackground;
  bool _challengeWebViewVisible = false;
  late CfVerificationState _observation;
  // 当前导航有明确的挑战或错误响应时，其无标记 HTML 不能充当源站证据。
  bool _documentResponseBlocked = false;
  bool _currentDocumentChallenged = false;
  bool get _hasSeenChallenge => _observation.challengeObserved;
  bool get _hasReportedError =>
      _observation.stage == CfVerificationStage.widgetError ||
      _observation.stage == CfVerificationStage.loadFailed;
  bool _hideOriginFallbackPage = false;
  int? _originProbeGeneration;
  bool get _checkingOriginFallback => _originProbeGeneration != null;
  bool _finishingFromVerifyResponse = false;
  int _loadGeneration = 0;
  int _challengeRevealProbeGeneration = 0;
  bool _hasTimedOut = false;
  int _checkCount = 0;
  Timer? _timeoutTimer;
  Timer? _noChallengeCheckTimer;
  Timer? _loadStopFallbackTimer;
  Timer? _pageReadyFallbackTimer;
  Timer? _pillRevealTimer;
  Timer? _pillAttentionTimer;

  /// 后台页面需要展示操作入口，既可能收到交互信号，也可能只是等待过久。
  bool _needsInteraction = false;

  /// 胶囊是否已到可显示时机（pill 等级延迟出现，blocking 立即出现）。
  bool _pillRevealed = false;

  /// 自动通过的验证实测多在 1s 内结束，pill 等级延迟出现，避免一闪而过。
  static const _pillRevealDelay = Duration(seconds: 2);

  /// pill 等级需要人工操作后等待用户点按的上限，超时按失败收尾。
  static const _pillAttentionTimeout = Duration(seconds: 60);

  /// 自动检查的等待时长。已确认的前台挑战到期后显示原页，后台请求按展示等级处理。
  static const _automaticCheckCount = 8;
  static const _foregroundMaxCheckCount = 60;
  static const _noChallengeCheckDelay = Duration(milliseconds: 1200);
  static const _revealStateWatchInterval = Duration(milliseconds: 150);
  static const _loadStopFallbackDelay = Duration(milliseconds: 1200);
  static const _pageReadyFallbackDelay = Duration(seconds: 4);
  static const _completionProbeTimeout = Duration(seconds: 8);
  static const _noChallengeProbeTimeout = Duration(milliseconds: 1800);

  /// 验证页面加载时 WebView 中的 cf_clearance 快照
  /// 用于区分「旧值残留」和「验证后新设的值」
  final Set<String> _initialCfClearances = {};

  int get _activeMaxCheckCount =>
      _isBackground ? _automaticCheckCount : _foregroundMaxCheckCount;

  CfVerifyPresentation get _presentation =>
      widget.presentation.value ?? CfVerifyPresentation.foreground;

  bool get _showPill =>
      _isBackground &&
      _presentation != CfVerifyPresentation.hidden &&
      _pillRevealed &&
      // 启动页等宿主自带状态展示时让位；需要用户点按时仍然露出入口。
      (CfChallengeService().statusHostCount.value == 0 || _needsInteraction);

  @override
  void initState() {
    super.initState();
    _observation = CfVerificationState.opening(widget.round);
    _startupHost = _presentation == CfVerifyPresentation.hidden
        ? null
        : CfChallengeService()._statusHosts.lastOrNull;
    _startupHost?.cancelVerification = _confirmExit;
    _isBackground =
        !_startupActive && _presentation != CfVerifyPresentation.foreground;
    widget.presentation.addListener(_onPresentationChanged);
    CfChallengeService().statusHostCount.addListener(_onStatusHostChanged);
    if (_isBackground) {
      _syncPillReveal();
    } else if (!_startupActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_hasPopped && !_claimStartupHost()) {
          widget.onPromoteRequest?.call();
        }
      });
    }
    _snapshotInitialClearance();
  }

  void _report(
    CfVerificationStage stage, {
    CfChallengeEvidence? evidence,
    int? status,
    CfOriginEvidence? origin,
    String? widgetErrorCode,
    String? loadErrorDescription,
  }) {
    if (!mounted || _hasPopped) return;
    final next = _observation.withStage(
      stage,
      observed: evidence,
      status: status,
      origin: origin,
      widgetErrorCode: widgetErrorCode,
      loadErrorDescription: loadErrorDescription,
    );
    if (identical(next, _observation)) return;
    setState(() => _observation = next);
    widget.onStateChanged?.call(next);
    _syncStartupPage();
  }

  void _observeChallenge(CfChallengeEvidence evidence, {int? status}) {
    _currentDocumentChallenged = true;
    final stage = switch (_observation.stage) {
      CfVerificationStage.opening ||
      CfVerificationStage.unconfirmed ||
      CfVerificationStage.loadFailed => CfVerificationStage.checking,
      final current => current,
    };
    _report(stage, evidence: evidence, status: status);
  }

  /// 展示等级被新加入的诉求抬高：按新等级立即调整呈现。
  void _onPresentationChanged() {
    if (!mounted || _hasPopped) return;
    final presentation = _presentation;
    if (_startupActive || (_isBackground && _claimStartupHost())) return;
    if (!_isBackground) return;
    if (presentation == CfVerifyPresentation.foreground) {
      _promoteToForeground();
      return;
    }
    if (presentation == CfVerifyPresentation.blocking && _needsInteraction) {
      _bringVerificationForward();
      return;
    }
    _syncPillReveal();
    setState(() {});
  }

  void _onStatusHostChanged() {
    // 启动页可能正在布局或退场，等当前帧结束再调整独立的 Overlay。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hasPopped) return;
      if (_startupActive &&
          !identical(
            _startupHost,
            CfChallengeService()._statusHosts.lastOrNull,
          )) {
        _releaseStartupHost();
        _isBackground = true;
        if (_claimStartupHost()) return;
        if (_presentation == CfVerifyPresentation.foreground ||
            (_presentation == CfVerifyPresentation.blocking &&
                (_needsInteraction ||
                    _observation.stage ==
                        CfVerificationStage.interactionRequired))) {
          _promoteToForeground();
          return;
        }
        _syncPillReveal();
      }
      if (!_startupActive && !_claimStartupHost()) {
        setState(() {});
      }
    });
  }

  void _syncPillReveal() {
    if (_pillRevealed) return;
    switch (_presentation) {
      case CfVerifyPresentation.hidden:
        return;
      case CfVerifyPresentation.pill:
        _pillRevealTimer ??= Timer(_pillRevealDelay, () {
          if (!mounted || _hasPopped) return;
          setState(() => _pillRevealed = true);
        });
      case CfVerifyPresentation.blocking:
      case CfVerifyPresentation.foreground:
        _pillRevealTimer?.cancel();
        _pillRevealed = true;
    }
  }

  /// 后台验证判定需要人工操作后，按当前展示等级决定如何升级。
  void _escalateNeedsInteraction({required String reason}) {
    if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
    if (!_isBackground || _needsInteraction) return;
    _needsInteraction = true;
    final presentation = _presentation;
    CfChallengeLogger.log(
      '[VERIFY] Opening verification controls ($reason), presentation=${presentation.name}',
    );
    switch (presentation) {
      case CfVerifyPresentation.hidden:
        _timeoutTimer?.cancel();
        _finish(_observation.stage);
      case CfVerifyPresentation.pill:
        _pillRevealTimer?.cancel();
        _pillAttentionTimer = Timer(_pillAttentionTimeout, () {
          if (!mounted || _hasPopped || !_isBackground) return;
          CfChallengeLogger.log('[VERIFY] Pill attention timeout, giving up');
          _finish(
            _hasReportedError
                ? _observation.stage
                : CfVerificationStage.timedOut,
          );
        });
        setState(() => _pillRevealed = true);
      case CfVerifyPresentation.blocking:
        _bringVerificationForward();
      case CfVerifyPresentation.foreground:
        _promoteToForeground();
    }
  }

  static final _widgetErrorCodePattern = RegExp(r'^[1-9][0-9]{5}$');

  /// 只接收当前 /challenge 主文档转发的控件状态。
  Future<void> _onChallengeWidgetEvent(
    JavaScriptHandlerFunctionData data,
  ) async {
    if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
    if (!data.isMainFrame || !_isVerifyUrl(data.requestUrl)) return;
    final event = data.args.firstOrNull;
    if (event != 'fail' &&
        event != 'interactiveEnd' &&
        event != 'interactiveBegin' &&
        event != 'interactiveTimeout') {
      return;
    }
    final generation = _loadGeneration;
    WebUri? url;
    try {
      url = await _controller?.getUrl();
    } catch (_) {
      return;
    }
    if (!mounted ||
        _hasPopped ||
        _finishingFromVerifyResponse ||
        generation != _loadGeneration ||
        !_isVerifyUrl(url)) {
      return;
    }
    _currentDocumentChallenged = true;
    if (event == 'interactiveEnd') {
      if (_observation.stage == CfVerificationStage.interactionRequired) {
        _report(CfVerificationStage.checking);
      }
      return;
    }
    if (event == 'fail') {
      final rawCode = data.args.elementAtOrNull(1);
      final code = rawCode is int || rawCode is String
          ? rawCode.toString()
          : '';
      // 控件可能自行恢复。仅报告它给出的错误，不结束页面或重试业务请求。
      _report(
        CfVerificationStage.widgetError,
        evidence: CfChallengeEvidence.widgetError,
        widgetErrorCode: _widgetErrorCodePattern.hasMatch(code) ? code : null,
      );
      _requestVerificationPage();
      return;
    }
    _report(
      event == 'interactiveBegin'
          ? CfVerificationStage.interactionRequired
          : CfVerificationStage.interactionExpired,
      evidence: CfChallengeEvidence.interactionSignal,
    );
    _requestVerificationPage();
    _escalateNeedsInteraction(reason: 'turnstile $event');
  }

  /// 记录本轮开始前 jar 与 WebView 中可见的旧值。两者可能不同，不能只
  /// 比较 jar 的备份，否则另一枚残留值会被误认成本轮新签发的 clearance。
  Future<void> _snapshotInitialClearance() async {
    _initialCfClearances.addAll(
      (widget.oldCfClearanceValues ?? const <String>{})
          .where((value) => value.isNotEmpty)
          .map(CookieValueCodec.decode),
    );
    if (widget.oldCfClearanceValue != null &&
        widget.oldCfClearanceValue!.isNotEmpty) {
      _initialCfClearances.add(
        CookieValueCodec.decode(widget.oldCfClearanceValue!),
      );
    }
    if (widget.oldCfClearanceValues != null ||
        _initialCfClearances.isNotEmpty) {
      debugPrint(
        '[CfChallenge] 已记录验证前 cf_clearance 快照 '
        '(${_initialCfClearances.length} 个不同值)',
      );
      return;
    }

    // 兜底：从 WebView 读取（可能不可靠，但聊胜于无）
    try {
      final cookieValue = await _readCookieValue('cf_clearance');
      if (cookieValue != null && cookieValue.isNotEmpty) {
        _initialCfClearances.add(CookieValueCodec.decode(cookieValue));
        debugPrint(
          '[CfChallenge] ⚠️ 验证页加载时 WebView 仍存在旧 cf_clearance '
          '(${cookieValue.length} chars)，将忽略该值',
        );
      }
    } catch (e) {
      debugPrint('[CfChallenge] 快照 cf_clearance 失败: $e');
    }
  }

  @override
  void dispose() {
    widget.presentation.removeListener(_onPresentationChanged);
    CfChallengeService().statusHostCount.removeListener(_onStatusHostChanged);
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();
    _pillRevealTimer?.cancel();
    _pillAttentionTimer?.cancel();
    _releaseStartupHost();
    // InAppWebView 自身会随 Widget 销毁平台 Controller；这里再次手动
    // dispose 会让 Windows 插件对同一个原生对象执行双重释放。
    _controller = null;
    super.dispose();
  }

  /// 读取 cookie 值：先尝试 CookieManager，Windows 上 fallback 到 DevTools
  Future<String?> _readCookieValue(String name) async {
    try {
      final cookie = await _cfCookieManager.getCookie(
        url: WebUri(AppConstants.baseUrl),
        name: name,
      );
      if (cookie != null && cookie.value.isNotEmpty) {
        return cookie.value;
      }
    } catch (e) {
      debugPrint('[CfChallenge] CookieManager 读取 $name 失败: $e');
    }

    // Windows：通过当前页面 controller 读取实时 cookie，再回退到 CookieJar
    if (io.Platform.isWindows && _controller != null) {
      final liveValue = await CookieJarService().readCookieValueFromController(
        _controller!,
        name,
        currentUrl: widget.verifyUrl,
      );
      if (liveValue != null && liveValue.isNotEmpty) {
        return liveValue;
      }
      return CookieJarService().getCookieValue(name);
    }

    if (io.Platform.isWindows) {
      return CookieJarService().getCookieValue(name);
    }

    // Linux WPE: getCookie() 内部已调 getCookies(url) 做 URL 过滤，
    // 若 URL 匹配有问题，改用 getAllCookies() 绕过 URL 过滤
    if (io.Platform.isLinux) {
      try {
        final allCookies = await _cfCookieManager.getAllCookies();
        for (final c in allCookies) {
          if (c.name == name && c.value.isNotEmpty) {
            return c.value;
          }
        }
      } catch (e) {
        debugPrint(
          '[CfChallenge] Linux getAllCookies fallback 读取 $name 失败: $e',
        );
      }
    }

    return null;
  }

  /// 将关键 cookie 从 WebView 同步到 CookieJar
  ///
  /// [freshClearance] challenge 确认的 fresh cf_clearance 值；传入后只接受该值
  /// 写入 jar（排除 WebView 残留旧变体），并以 trusted 升 version 盖过旧值。
  Future<void> _syncLiveCookiesToCookieJar({String? freshClearance}) async {
    await BoundarySyncService.instance.syncFromWebView(
      currentUrl: widget.verifyUrl,
      controller: _controller,
      cookieNames: const {'cf_clearance'},
      trusted: true,
      throwOnError: true,
      acceptValues: freshClearance != null && freshClearance.isNotEmpty
          ? {'cf_clearance': freshClearance}
          : null,
    );
  }

  // ---------------------------------------------------------------------------
  // JS 注入：拦截 XHR/fetch 对 cdn-cgi/challenge-platform 的响应
  // 当 challenge-platform 请求完成时，通过 JS Handler 通知 Flutter 侧
  // Flutter 侧用 CookieManager（可读 HttpOnly cookie）检查 cf_clearance
  // ---------------------------------------------------------------------------

  /// 注入 XHR/fetch 拦截 + 页面内 DOM 遮罩脚本
  ///
  /// 两层防线，确保跳转期间一帧 404 都不露：
  /// 1. JS 层：在 `beforeunload` / `pagehide` 的同一个 tick 里，立即往 DOM 里塞一个
  ///    `position:fixed;z-index:max` 的全屏 div，挡住当前页面剩余的渲染。
  /// 2. Flutter 层：通过 `onChallengeNavigation` Handler 通知 Dart 端 setState，
  ///    在 PlatformView 完成新页面渲染前用 Flutter 遮罩盖住。
  Future<void> _injectChallengeInterceptor(
    InAppWebViewController controller,
  ) async {
    final maskColorHex = _resolveMaskColorHex();
    await controller.evaluateJavascript(
      source:
          '''
(function() {
  if (window._cfInterceptorInstalled) return;
  window._cfInterceptorInstalled = true;
  window.__fluxdoCfMaskColor = '$maskColorHex';

  var CP = 'cdn-cgi/challenge-platform';

  // 拦截 XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url) {
    this._cfUrl = url;
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function() {
    var self = this;
    if (self._cfUrl && self._cfUrl.indexOf(CP) !== -1) {
      self.addEventListener('load', function() {
        try {
          window.flutter_inappwebview.callHandler('onChallengeComplete', self._cfUrl, self.status);
        } catch(e) {}
      });
    }
    return origSend.apply(this, arguments);
  };

  // 拦截 fetch
  var origFetch = window.fetch;
  window.fetch = function(input, init) {
    var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
    return origFetch.apply(this, arguments).then(function(resp) {
      if (url.indexOf(CP) !== -1) {
        try {
          window.flutter_inappwebview.callHandler('onChallengeComplete', url, resp.status);
        } catch(e) {}
      }
      return resp;
    });
  };

  // 页面内 DOM 遮罩：CF 跳走的瞬间立刻挡住，不依赖 Flutter rebuild
  function showCfMask() {
    var root = document.body || document.documentElement;
    if (!root) return;
    var mask = document.getElementById('__fluxdoCfMask');
    if (mask) {
      mask.style.display = 'block';
      return;
    }
    mask = document.createElement('div');
    mask.id = '__fluxdoCfMask';
    mask.style.cssText = 'position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;background:' +
      (window.__fluxdoCfMaskColor || '#ffffff') +
      '!important;z-index:2147483647!important;pointer-events:auto!important;';
    root.appendChild(mask);
  }
  window.__fluxdoShowCfMask = showCfMask;

  // 仅监听真正的"页面即将卸载"事件。
  // 不要 hook history.pushState/replaceState：CF Turnstile 验证过程中
  // 会用 history API 更新 URL 但不真正导航，hook 会在验证未完成时误触发 fallback。
  function notifyNav(reason) {
    showCfMask();
    try {
      window.flutter_inappwebview.callHandler('onChallengeNavigation', reason);
    } catch(e) {}
  }
  window.addEventListener('beforeunload', function(){ notifyNav('beforeunload'); });
  window.addEventListener('pagehide', function(){ notifyNav('pagehide'); });
})();
''',
    );
  }

  static String _cssColor(Color color) {
    final rgb = color.toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0')}';
  }

  /// 取当前主题的 surface 色作为页面内 mask 颜色，深色模式下不会闪白。
  String _resolveMaskColorHex() =>
      mounted ? _cssColor(Theme.of(context).colorScheme.surface) : '#ffffff';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(_applyOriginalPagePalette());
  }

  Future<void> _applyOriginalPagePalette() async {
    final controller = _controller;
    if (controller == null || _hasPopped || _finishingFromVerifyResponse) {
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    final palette = (
      document: _loadGeneration,
      surface: scheme.surface,
      text: scheme.onSurface,
    );
    if (_originalPagePalette == palette) return;
    _originalPagePalette = palette;
    var applied = false;
    try {
      final result = await controller.evaluateJavascript(
        source: _pagePaletteScript(scheme),
      );
      applied = result == true;
    } catch (_) {
      // 平台暂时无法更新样式时，原页仍可继续操作。
    } finally {
      if (!applied && _originalPagePalette == palette) {
        _originalPagePalette = null;
      }
    }
  }

  String _pagePaletteScript(ColorScheme scheme) =>
      cfVerificationPagePaletteScript(
        page: _verifyUri,
        surface: _cssColor(scheme.surface),
        text: _cssColor(scheme.onSurface),
      );

  UnmodifiableListView<UserScript> _initialChallengeScripts() {
    final scheme = Theme.of(context).colorScheme;
    return UnmodifiableListView([
      UserScript(
        source: _documentStartMaskScript(_cssColor(scheme.surface)),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
      // 主文档从首帧起使用当前主题底色。
      UserScript(
        source: _pagePaletteScript(scheme),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
      ...WebViewSettings.compatPolyfillScripts,
    ]);
  }

  String _documentStartMaskScript(String maskColorHex) {
    return '''
(function() {
  if (window.__fluxdoCfDocumentMaskInstalled) return;
  window.__fluxdoCfDocumentMaskInstalled = true;
  window.__fluxdoCfMaskColor = '$maskColorHex';

  function root() {
    return document.body || document.documentElement;
  }

  function ensureMask() {
    var r = root();
    if (!r) return null;
    var mask = document.getElementById('__fluxdoCfMask');
    if (!mask) {
      mask = document.createElement('div');
      mask.id = '__fluxdoCfMask';
      mask.style.cssText = 'position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;width:100vw!important;height:100vh!important;margin:0!important;padding:0!important;background:' +
        (window.__fluxdoCfMaskColor || '#ffffff') +
        '!important;z-index:2147483647!important;pointer-events:auto!important;';
      r.appendChild(mask);
    }
    return mask;
  }

  window.__fluxdoCfMaskSuppressed = false;

  window.__fluxdoShowCfMask = function(force) {
    if (window.__fluxdoCfMaskSuppressed && !force) return;
    window.__fluxdoCfMaskSuppressed = false;
    var mask = ensureMask();
    if (mask) mask.style.display = 'block';
  };

  window.__fluxdoHideCfMask = function() {
    window.__fluxdoCfMaskSuppressed = true;
    var mask = document.getElementById('__fluxdoCfMask');
    if (mask) mask.style.display = 'none';
  };

  function notifyNav(reason) {
    window.__fluxdoShowCfMask(true);
    try {
      window.flutter_inappwebview.callHandler('onChallengeNavigation', reason);
    } catch(e) {}
  }

  function looksLikeOrigin404() {
    try {
      var html = document.documentElement ? document.documentElement.innerHTML : '';
      var title = document.title || '';
      var haystack = (html + ' ' + title).toLowerCase();
      return haystack.indexOf('page-not-found') !== -1 ||
        haystack.indexOf('discourse-no-results') !== -1 ||
        haystack.indexOf('"errortype":"notfound"') !== -1 ||
        haystack.indexOf('404-body') !== -1 ||
        haystack.indexOf('exist or is private') !== -1 ||
        haystack.indexOf('page you requested') !== -1 ||
        title.indexOf('404') !== -1;
    } catch(e) {
      return false;
    }
  }

  var origin404Notified = false;
  function probeOrigin404() {
    if (origin404Notified || !looksLikeOrigin404()) return;
    origin404Notified = true;
    notifyNav('origin-404-dom');
  }

  function installOrigin404Observer() {
    probeOrigin404();
    try {
      var observer = new MutationObserver(probeOrigin404);
      observer.observe(document.documentElement || document, {
        childList: true,
        subtree: true,
        characterData: true
      });
    } catch(e) {}
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      window.__fluxdoShowCfMask(false);
      installOrigin404Observer();
    }, { once: true });
  } else {
    window.__fluxdoShowCfMask();
    installOrigin404Observer();
  }
  window.addEventListener('beforeunload', function(){ notifyNav('beforeunload'); });
  window.addEventListener('pagehide', function(){ notifyNav('pagehide'); });

  // 只接收真实验证页报告的交互状态和错误。
  window.addEventListener('message', function(e) {
    if (window !== window.top || e.origin !== 'https://challenges.cloudflare.com') return;
    var d = e.data;
    if (!d || typeof d !== 'object' || d.source !== 'cloudflare-challenge') return;
    if (d.event !== 'fail' && d.event !== 'interactiveBegin' &&
        d.event !== 'interactiveEnd' && d.event !== 'interactiveTimeout') return;
    try {
      var code = d.event === 'fail' && (typeof d.code === 'number' || typeof d.code === 'string')
        ? d.code : null;
      window.flutter_inappwebview.callHandler('onChallengeWidgetEvent', d.event, code);
    } catch(e) {}
  });
})();
''';
  }

  /// challenge-platform 响应到达时的回调
  ///
  /// 不再主动 reveal WebView：reveal 完全交给 _startChallengeRevealProbe，
  /// 避免「完成响应到达 → reveal → 紧接着 CF 跳转回 /challenge 加载源站 404」
  /// 期间 404 闪现。回调只触发页面检查，不用 Cookie 变化代替挑战状态。
  Future<void> _onChallengeComplete(List<dynamic> args) async {
    if (_hasPopped || _finishingFromVerifyResponse) return;
    final generation = _loadGeneration;
    try {
      final controller = _controller;
      // challenge-platform 有脚本加载、初始化、提交等多次请求；收到它的
      // 响应或观察到续期 Cookie 都不等于页面已经结束挑战。
      if (controller != null &&
          await _hasLoadedOriginDocument(controller) &&
          generation == _loadGeneration &&
          mounted) {
        _finishFromOriginResponse(
          origin: CfOriginEvidence.document,
          reason: 'challenge callback: loaded document has no CF challenge',
        );
      }
    } catch (e) {
      debugPrint('[CfChallenge] challenge 回调页面检查异常: $e');
    }
  }

  /// 页面 unload/pagehide/history 变化时回调
  ///
  /// CF 验证完成后会跳到源 URL（/challenge → 404）。在 Android 上 `onLoadStart`
  /// 对部分 location.replace 跳转触发时机晚于 PlatformView 渲染，导致 404 闪现。
  /// 借助 JS 在跳走的最早时刻通知 Flutter，立即重置 reveal 状态、覆盖 WebView。
  Future<void> _onChallengeNavigation(List<dynamic> args) async {
    if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
    final reason = args.isNotEmpty ? args.first.toString() : 'unknown';
    if (!_challengeWebViewVisible && _hideOriginFallbackPage) {
      // 已经覆盖中，不必重复触发 fallback 流程
      return;
    }
    debugPrint('[CfChallenge] JS 导航事件 ($reason)，立刻覆盖 WebView');
    CfChallengeLogger.log('[VERIFY] JS navigation: $reason');
    await _handleVerifyOriginFallback(
      _loadGeneration,
      reason: 'js navigation: $reason',
      completionLikely: true,
    );
  }

  // ---------------------------------------------------------------------------
  // 超时计时器（兜底机制）
  // ---------------------------------------------------------------------------

  void _startTimeout() {
    _timeoutTimer?.cancel();
    _checkCount = 0;
    _hasTimedOut = false;
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _finishingFromVerifyResponse) {
        timer.cancel();
        return;
      }
      _checkCount++;
      // 已确认的挑战持续停留却没有报告交互时，也让用户查看同一页。
      if (!_isBackground &&
          !_pageNeeded &&
          _currentDocumentChallenged &&
          _checkCount >= _automaticCheckCount) {
        _requestVerificationPage();
      }

      // 兜底轮询：验证通过后页面重定向会销毁 JS 上下文，
      // 导致 onChallengeComplete 回调丢失（macOS 上尤为明显），
      // 每秒检查已加载的页面是否还有挑战；续期 Cookie 不作为完成信号。
      _pollVerificationDocument();

      if (_checkCount > _activeMaxCheckCount) {
        if (_isBackground) {
          // 继续每秒轮询页面：pill 等级等待点按期间页面仍可能自行通过。
          if (!_needsInteraction && !_hasReportedError) {
            _report(CfVerificationStage.timedOut);
          }
          _escalateNeedsInteraction(
            reason: 'background timeout after $_activeMaxCheckCount seconds',
          );
          return;
        }
        if (!_hasTimedOut &&
            _observation.stage != CfVerificationStage.interactionRequired) {
          if (!_hasReportedError &&
              _observation.stage != CfVerificationStage.interactionExpired) {
            _report(CfVerificationStage.timedOut);
          }
          CfChallengeLogger.log(
            '[VERIFY] Still waiting after $_activeMaxCheckCount seconds',
          );
          if (mounted) {
            setState(() {
              _hasTimedOut = true;
            });
            if (_observation.stage != CfVerificationStage.loadFailed) {
              _requestVerificationPage();
            }
          }
        }
        return;
      }
    });
  }

  /// 延迟检测页面是否存在 CF 验证盾
  /// 如果页面加载完成后没有盾，立刻走 fallback 流程，避免源站 404 露出
  void _scheduleNoChallengeCheck(InAppWebViewController controller) {
    _noChallengeCheckTimer?.cancel();
    final generation = _loadGeneration;
    _noChallengeCheckTimer = Timer(_noChallengeCheckDelay, () async {
      if (_hasPopped ||
          !mounted ||
          _finishingFromVerifyResponse ||
          generation != _loadGeneration) {
        return;
      }

      try {
        final canShowPage = await _hasDisplayableVerificationPage(controller);
        if (_hasPopped ||
            _finishingFromVerifyResponse ||
            generation != _loadGeneration) {
          return;
        }
        if (canShowPage) {
          _revealChallengeWebView();
          return;
        }

        // 页面无盾：统一交给 fallback 处理（先轮询 cf_clearance，无果再给重试）
        await _handleVerifyOriginFallback(
          generation,
          reason:
              'no challenge after ${_noChallengeCheckDelay.inMilliseconds}ms',
          completionLikely: _hasSeenChallenge,
        );
      } catch (e) {
        debugPrint('[CfChallenge] 检测 challenge 状态异常: $e');
      }
    });
  }

  /// 处理「页面没有 CF 挑战」的统一入口
  ///
  /// 触发场景：源站 404 / onReceivedHttpError / reveal 后页面退化 / noChallengeCheck 命中。
  /// 状态码回调缺失或页面正在跳转时，短期确认源站文档。
  /// 已加载的无盾文档即可结束，不要求源站为本轮签发新 Cookie。
  Future<void> _handleVerifyOriginFallback(
    int generation, {
    String? reason,
    bool completionLikely = false,
  }) async {
    if (_hasPopped ||
        _finishingFromVerifyResponse ||
        generation != _loadGeneration) {
      return;
    }
    _coverWebViewForOriginFallback();
    if (_originProbeGeneration == generation) return;

    _originProbeGeneration = generation;
    final isCompletionProbe = completionLikely || _hasSeenChallenge;
    // 避免在同一次导航中重复发起文档探测。
    _challengeRevealProbeGeneration++;
    _noChallengeCheckTimer?.cancel();
    if (reason != null) {
      debugPrint('[CfChallenge] fallback triggered: $reason');
    }

    final timeout = isCompletionProbe
        ? _completionProbeTimeout
        : _noChallengeProbeTimeout;
    final stop = Completer<_VerificationDocument>();
    final timer = Timer(
      timeout,
      () => stop.complete(_VerificationDocument.unknown),
    );
    try {
      var attempt = 0;
      while (!stop.isCompleted) {
        if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
        if (generation != _loadGeneration) return;
        final controller = _controller;
        final document = controller == null
            ? _VerificationDocument.unknown
            : await Future.any([
                _readVerificationDocument(controller),
                stop.future,
              ]);
        if (_hasPopped || !mounted || generation != _loadGeneration) return;
        if (document == _VerificationDocument.origin) {
          _finishFromOriginResponse(
            origin: CfOriginEvidence.document,
            reason: 'loaded verification document has no CF challenge',
          );
          return;
        }
        // 慢页面可能在初始探测之后才显示挑战。新出现的内容仍交给同一 WebView。
        if (!completionLikely && _canDisplayVerificationDocument(document)) {
          _revealChallengeWebView();
          return;
        }
        attempt++;
        await Future.delayed(
          attempt < 12
              ? const Duration(milliseconds: 150)
              : const Duration(milliseconds: 400),
        );
      }
      if (!mounted || _hasPopped || generation != _loadGeneration) return;
      // 新文档已在别的回调中显示了挑战，继续等待本轮验证。
      if (_challengeWebViewVisible) return;
      debugPrint('[CfChallenge] fallback/completion 尚未确认页面结束挑战');
      if (!_hasReportedError &&
          _observation.stage != CfVerificationStage.timedOut &&
          _observation.stage != CfVerificationStage.interactionExpired) {
        _report(CfVerificationStage.unconfirmed);
      }
      if (_isBackground) {
        _timeoutTimer?.cancel();
        if (mounted) _finish(_observation.stage);
        return;
      }
    } catch (e) {
      debugPrint('[CfChallenge] 处理 fallback 异常: $e');
    } finally {
      timer.cancel();
      if (_originProbeGeneration == generation) {
        _originProbeGeneration = null;
        if (mounted && !_hasPopped) {
          setState(() {});
          _probePendingVerificationPage();
        }
      }
    }
  }

  void _coverWebViewForOriginFallback() {
    if (!mounted || _hasPopped) return;
    if (!_challengeWebViewVisible && _hideOriginFallbackPage) return;
    setState(() {
      _challengeWebViewVisible = false;
      _hideOriginFallbackPage = true;
    });
    _syncStartupPage();
  }

  /// 页面状态轮询（兜底 JS 回调被重定向吞掉的场景）
  bool _polling = false;
  Future<void> _pollVerificationDocument() async {
    if (_hasPopped ||
        _finishingFromVerifyResponse ||
        _polling ||
        _checkingOriginFallback) {
      return;
    }
    _polling = true;
    final generation = _loadGeneration;
    try {
      final controller = _controller;
      if (controller != null &&
          await _hasLoadedOriginDocument(controller) &&
          generation == _loadGeneration &&
          mounted) {
        _finishFromOriginResponse(
          origin: CfOriginEvidence.document,
          reason: 'polling: loaded document has no CF challenge',
        );
      }
    } catch (e) {
      debugPrint('[CfChallenge] 轮询检查异常: $e');
    } finally {
      _polling = false;
    }
  }

  // ---------------------------------------------------------------------------
  // UI 操作
  // ---------------------------------------------------------------------------

  var _dialogSection = CfVerificationDialogSection.verification;

  bool _claimStartupHost() {
    final host = CfChallengeService()._statusHosts.lastOrNull;
    if (host == null || _presentation == CfVerifyPresentation.hidden) {
      return false;
    }
    if (identical(host, _startupHost)) return true;
    _pillRevealTimer?.cancel();
    _pillRevealTimer = null;
    _pillAttentionTimer?.cancel();
    widget.onStartupClaimed?.call();
    setState(() {
      _startupHost = host;
      host.cancelVerification = _confirmExit;
      _isBackground = false;
    });
    _resumeVerificationPresentation();
    return true;
  }

  void _releaseStartupHost() {
    final host = _startupHost;
    host?.cancelVerification = null;
    _startupHost = null;
    host?.present();
  }

  void _bringVerificationForward() {
    if (!_claimStartupHost()) _promoteToForeground();
  }

  void _resumeVerificationPresentation() {
    if (_pageNeeded ||
        _observation.stage == CfVerificationStage.interactionRequired ||
        _observation.stage == CfVerificationStage.interactionExpired ||
        _observation.stage == CfVerificationStage.timedOut ||
        _observation.stage == CfVerificationStage.widgetError) {
      _requestVerificationPage();
    } else {
      _syncStartupPage();
    }
  }

  bool get _showVerificationPage =>
      _pageNeeded &&
      !_isBackground &&
      !_shouldCoverWebView &&
      !_finishingFromVerifyResponse &&
      _observation.stage != CfVerificationStage.loadFailed;

  void _requestVerificationPage() {
    if (!mounted ||
        _hasPopped ||
        _isBackground ||
        _finishingFromVerifyResponse) {
      return;
    }
    if (!_pageNeeded) setState(() => _pageNeeded = true);
    if (_currentDocumentChallenged &&
        !_hideOriginFallbackPage &&
        !_checkingOriginFallback) {
      _revealChallengeWebView();
    } else {
      _probePendingVerificationPage();
    }
    _syncStartupPage();
  }

  void _probePendingVerificationPage() {
    final controller = _controller;
    if (controller != null &&
        _pageNeeded &&
        !_isBackground &&
        _hasMarkedPageReady &&
        _shouldCoverWebView &&
        !_checkingOriginFallback &&
        _observation.stage != CfVerificationStage.loadFailed) {
      unawaited(_probeContentImmediately(controller, _loadGeneration));
    }
  }

  void _syncStartupPage() {
    final host = _startupHost;
    if (host == null) return;
    final visible = _showVerificationPage;
    host.present(
      pageVisible: visible,
      reloadPage:
          visible ||
              _hasReportedError ||
              _hasTimedOut ||
              _observation.stage == CfVerificationStage.unconfirmed ||
              _observation.stage == CfVerificationStage.interactionExpired
          ? _refresh
          : null,
    );
  }

  void _setDialogSection(CfVerificationDialogSection section) {
    if (mounted && !_hasPopped) setState(() => _dialogSection = section);
  }

  void handleBack() {
    if (_startupActive) return;
    _setDialogSection(
      _dialogSection == CfVerificationDialogSection.verification
          ? CfVerificationDialogSection.confirmExit
          : CfVerificationDialogSection.verification,
    );
  }

  void _confirmExit() {
    if (!mounted) return;
    _finish(CfVerificationStage.cancelled);
  }

  void _refresh() {
    _pageNeeded = false;
    _startupHost?.present();
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();
    _challengeRevealProbeGeneration++;
    _hasMarkedPageReady = false;
    _checkCount = 0;
    _hasTimedOut = false;
    _challengeWebViewVisible = false;
    _documentResponseBlocked = false;
    _currentDocumentChallenged = false;
    _loadGeneration++;
    _logPageResult(reloaded: true);
    _observation = CfVerificationState.opening(
      widget.round,
      attempt: _observation.attempt + 1,
    );
    widget.onStateChanged?.call(_observation);
    _hideOriginFallbackPage = false;
    _originProbeGeneration = null;
    _needsInteraction = false;
    _finishingFromVerifyResponse = false;
    setState(() {
      _progress = 0;
    });
    _controller?.reload();
  }

  void _promoteToForeground() {
    if (!_isBackground || _hasPopped || !mounted) return;
    _panelRevealFrom = CfVerificationPanelReveal.anchorIn(_pillKey, context);
    _pillRevealTimer?.cancel();
    _pillAttentionTimer?.cancel();
    setState(() {
      _isBackground = false;
      _hasTimedOut = false;
      _checkCount = 0;
    });
    CfChallengeService().raisePresentation(CfVerifyPresentation.foreground);
    _resumeVerificationPresentation();
    widget.onPromoteRequest?.call();
  }

  void _finish(
    CfVerificationStage stage, {
    CfOriginEvidence? origin,
    int? status,
  }) {
    if (_hasPopped) return;
    _report(stage, origin: origin, status: status);
    setState(() => _hasPopped = true);
    _releaseStartupHost();
    _timeoutTimer?.cancel();
    _logPageResult();
    widget.onPageResult?.call(_observation);
    widget.onResult?.call(_observation.reachedOrigin);
    if (widget.onPageResult == null && widget.onResult == null) {
      Navigator.of(context).pop(_observation.reachedOrigin);
    }
  }

  void _logPageResult({bool reloaded = false}) {
    CfChallengeLogger.log(
      '[VERIFY] /challenge: ${_observation.stage.name}',
      fields: {
        'event': 'cf_verification_page_result',
        'verificationRound': widget.round,
        'attempt': _observation.attempt,
        if (reloaded) 'reloaded': true,
        'stage': _observation.stage.name,
        'challengeEvidence': _observation.evidence
            .map((source) => source.name)
            .toList(),
        'interactionRequested': _observation.interactionRequested,
        'lastHttpStatus': _observation.lastHttpStatus,
        if (_observation.lastWidgetErrorCode != null)
          'widgetErrorCode': _observation.lastWidgetErrorCode,
        'originEvidence': _observation.originEvidence?.name,
      },
    );
  }

  bool get _shouldCoverWebView =>
      !_challengeWebViewVisible || _hideOriginFallbackPage;

  bool _isFreshClearance(String? cookieValue) {
    if (cookieValue == null || cookieValue.isEmpty) return false;
    return !_initialCfClearances.contains(CookieValueCodec.decode(cookieValue));
  }

  bool _isVerifyUrl(WebUri? url) {
    return url != null && _isVerifyUri(Uri.tryParse(url.toString()));
  }

  late final _verifyUri = Uri.parse(widget.verifyUrl);

  bool _isVerifyUri(Uri? actual) {
    final expected = _verifyUri;
    if (actual == null) return false;
    return actual.scheme == expected.scheme &&
        actual.host == expected.host &&
        actual.port == expected.port &&
        actual.path == expected.path;
  }

  bool _isBareVerifyUrl(WebUri? url) {
    if (!_isVerifyUrl(url)) return false;
    final actual = Uri.tryParse(url.toString());
    if (actual == null) return false;
    return actual.query.isEmpty;
  }

  Future<NavigationActionPolicy> _shouldOverrideVerifyNavigation(
    InAppWebViewController controller,
    NavigationAction navigationAction,
  ) async {
    final url = navigationAction.request.url;
    if (navigationAction.isForMainFrame == true &&
        _hasSeenChallenge &&
        _isBareVerifyUrl(url)) {
      debugPrint('[CfChallenge] 验证完成后准备加载 /challenge，提前覆盖并等待状态码');
      CfChallengeLogger.log(
        '[VERIFY] Post-challenge navigation to ${url?.toString() ?? ''}',
      );
      _coverWebViewForOriginFallback();
      unawaited(
        _handleVerifyOriginFallback(
          _loadGeneration,
          reason: 'post-challenge /challenge navigation pending status',
          completionLikely: true,
        ),
      );
    }

    return NavigationActionPolicy.ALLOW;
  }

  /// 两种平台回调走同一入口。仅在主框架明确到达验证入口时结束导航。
  bool _handleVerifyResponse({
    required WebUri? url,
    required bool? isForMainFrame,
    required int? statusCode,
    Map<String, String>? headers,
  }) {
    if (_hasPopped ||
        _finishingFromVerifyResponse ||
        isForMainFrame != true ||
        !_isVerifyUrl(url)) {
      return false;
    }
    final challenged =
        headers?.entries.any(
          (entry) =>
              entry.key.toLowerCase() == 'cf-mitigated' &&
              CfChallengeService._isChallengeHeader(entry.value),
        ) ??
        false;
    if (challenged) {
      _documentResponseBlocked = true;
      _observeChallenge(CfChallengeEvidence.responseHeader, status: statusCode);
      return false;
    }

    // /challenge 在源站恰好不存在，所以通常返回 404；若站点以后提供正常
    // 页面，2xx 也应结束。这里只说明入口当前无盾，不说明签发了新 Cookie。
    // 403/429 等含义不明确的状态继续由页面内容判定，不能一律视为已放行。
    if (statusCode == null) return false;
    // 同一主文档的第二个回调可能丢失响应头，保留先到的明确挑战证据。
    if (_currentDocumentChallenged &&
        (statusCode == _observation.lastHttpStatus ||
            statusCode == 403 ||
            statusCode == 429)) {
      _report(_observation.stage, status: statusCode);
      return false;
    }
    // 缺失响应头的 2xx 可能仍是挑战文档，让 WebView 提交页面后再辨认。
    if ((headers == null || headers.isEmpty) &&
        statusCode >= 200 &&
        statusCode < 300) {
      _report(_observation.stage, status: statusCode);
      return false;
    }
    if ((statusCode >= 200 && statusCode < 300) || statusCode == 404) {
      _finishFromOriginResponse(
        origin: CfOriginEvidence.response,
        reason: 'main frame verification request reached origin ($statusCode)',
        headers: headers,
        statusCode: statusCode,
      );
      return true;
    }
    if (statusCode >= 400) {
      _documentResponseBlocked = true;
      _report(
        statusCode == 403 || statusCode == 429
            ? CfVerificationStage.unconfirmed
            : CfVerificationStage.loadFailed,
        status: statusCode,
        loadErrorDescription: 'HTTP $statusCode',
      );
    }
    return false;
  }

  Future<NavigationResponseAction> _handleVerifyNavigationResponse(
    InAppWebViewController controller,
    NavigationResponse navigationResponse,
  ) async {
    final response = navigationResponse.response;
    if (_handleVerifyResponse(
      url: response?.url,
      isForMainFrame: navigationResponse.isForMainFrame,
      statusCode: response?.statusCode,
      headers: response?.headers,
    )) {
      return NavigationResponseAction.CANCEL;
    }

    return NavigationResponseAction.ALLOW;
  }

  void _finishFromOriginResponse({
    required CfOriginEvidence origin,
    required String reason,
    Map<String, String>? headers,
    int? statusCode,
  }) {
    if (_hasPopped || _finishingFromVerifyResponse) return;
    _finishingFromVerifyResponse = true;
    _coverWebViewForOriginFallback();
    _timeoutTimer?.cancel();
    _noChallengeCheckTimer?.cancel();
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();
    _challengeRevealProbeGeneration++;
    _revealStateWatchGeneration++;

    debugPrint('[CfChallenge] $reason，验证入口当前无盾，结束验证页面');

    // 源站可直接放行而不签发 Cookie。只同步此刻已有的值，不轮询续期，
    // 不把 Cookie 的产生或落库作为页面结束条件。
    final cookieSync = _syncCookiesAfterOriginResponse(
      reason: reason,
      statusCode: statusCode,
      cfRay: headers?.entries
          .where((entry) => entry.key.toLowerCase() == 'cf-ray')
          .firstOrNull
          ?.value,
    );
    final service = CfChallengeService();
    service._completionCookieSync = cookieSync;
    unawaited(
      cookieSync.whenComplete(() {
        if (identical(service._completionCookieSync, cookieSync)) {
          service._completionCookieSync = null;
        }
      }),
    );
    if (mounted && !_hasPopped) {
      _finish(
        _observation.challengeObserved
            ? CfVerificationStage.challengeCleared
            : CfVerificationStage.noChallengeObserved,
        origin: origin,
        status: statusCode,
      );
    }
  }

  Future<void> _syncCookiesAfterOriginResponse({
    required String reason,
    int? statusCode,
    String? cfRay,
  }) async {
    final timer = Stopwatch()..start();
    final round = widget.round;
    final attempt = _observation.attempt;
    final networkContext = CfChallengeLogger.networkContext();
    String? clearance;
    String? jarClearance;
    Object? failure;
    var candidateCount = 0;
    var freshCount = 0;
    try {
      final values = await BoundarySyncService.instance
          .readCookieValuesFromWebView(
            name: 'cf_clearance',
            currentUrl: widget.verifyUrl,
            controller: _controller,
          );
      candidateCount = values.length;
      final freshValues = values.where(_isFreshClearance).toSet();
      freshCount = freshValues.length;
      // getCookie 可能只返回残留分区值。唯一新值直接选中；存在多个新值时
      // 保留浏览器单值接口的选择，但必须确认它属于本轮，不能选回旧副本。
      String? confirmed;
      if (freshValues.length == 1) {
        confirmed = freshValues.single;
      } else if (freshValues.length > 1) {
        final live = await _readCookieValue('cf_clearance');
        final normalized = CookieValueCodec.decode(live ?? '');
        if (!freshValues.contains(normalized)) {
          throw StateError('本轮出现多个新的 cf_clearance，浏览器未返回其中的值');
        }
        confirmed = normalized;
      }
      clearance = confirmed ?? values.singleOrNull;
      await _syncLiveCookiesToCookieJar(freshClearance: confirmed);
      jarClearance = await CookieJarService().getCfClearance();
      if (confirmed != null &&
          CookieValueCodec.decode(jarClearance ?? '') != confirmed) {
        throw StateError('本轮 cf_clearance 未同步到 CookieJar');
      }
    } catch (e) {
      failure = e;
      debugPrint('[CfChallenge] 源站已放行，Cookie 同步未完成: $e');
    } finally {
      // 复用本轮读取结果与 jar 内存快照，记录完成时序及两端摘要。
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': failure == null ? 'info' : 'warning',
        'type': 'cookie_trace',
        'event': 'cf_completion_cookie_sync',
        'message': 'CF 验证后的 Cookie 同步结果',
        'verificationRound': round,
        'attempt': attempt,
        'verifyReason': reason,
        'verifyStatusCode': statusCode,
        'verifyCfRay': cfRay,
        'cfNetworkContext': networkContext,
        'cookieSyncDurationMs': timer.elapsedMilliseconds,
        'cookieSyncCompleted': failure == null,
        'clearanceCandidateCount': candidateCount,
        'freshClearanceCount': freshCount,
        'webViewCfClearanceHash': CookieLogger.valueHash(clearance),
        'jarCfClearanceHash': CookieLogger.valueHash(jarClearance),
        if (failure != null) 'errorType': failure.runtimeType.toString(),
      });
    }
  }

  /// 在同一次主文档读取中取得 URL、加载状态和页面内容。导航交接时，
  /// 平台 getUrl 可能已更新，JS 上下文却仍指向上一页。
  Future<_VerificationDocument> _readVerificationDocument(
    InAppWebViewController controller,
  ) async {
    final generation = _loadGeneration;
    final raw = await controller.evaluateJavascript(
      source: '''
JSON.stringify({url: location.href, ready: document.readyState === 'complete',
  html: document.body ? document.documentElement.outerHTML : ''})
''',
    );
    if (!mounted ||
        _hasPopped ||
        _finishingFromVerifyResponse ||
        generation != _loadGeneration ||
        raw is! String ||
        raw.isEmpty) {
      return _VerificationDocument.unknown;
    }
    final snapshot = jsonDecode(raw);
    if (snapshot is! Map ||
        snapshot['url'] is! String ||
        !_isVerifyUri(Uri.tryParse(snapshot['url'] as String))) {
      return _VerificationDocument.unknown;
    }
    final html = snapshot['html'];
    if (html is! String || html.isEmpty) return _VerificationDocument.unknown;
    // 普通 Discourse 页面也可能嵌 Turnstile 或加载 Cloudflare 资源。
    // 仅有控件时保留真实页面交互，不能据此报告 WAF 挑战。
    final isOrigin =
        CfChallengeService.isOriginNotFound(html) ||
        _discoursePreloaded.hasMatch(html);
    if (!isOrigin && _challengeDocumentMarker.hasMatch(html)) {
      _observeChallenge(CfChallengeEvidence.pageContent);
      return _VerificationDocument.challenge;
    }
    if (!isOrigin &&
        !_hideOriginFallbackPage &&
        _currentDocumentChallenged &&
        _observation.interactionRequested &&
        !_isBackground) {
      return _VerificationDocument.challenge;
    }
    if (isOrigin && snapshot['ready'] == true && !_documentResponseBlocked) {
      return _VerificationDocument.origin;
    }
    if (html.contains('cf-turnstile')) {
      if (_observation.stage == CfVerificationStage.opening) {
        _report(CfVerificationStage.unconfirmed);
      }
      return _VerificationDocument.widget;
    }
    // 同一 /challenge 已经载入但结构不认识，保留给原页兜底，不作为挑战或放行证据。
    return !isOrigin && snapshot['ready'] == true
        ? _VerificationDocument.other
        : _VerificationDocument.unknown;
  }

  static final _discoursePreloaded = RegExp(
    '''\\s(?:id\\s*=\\s*["']data-preloaded["']|data-preloaded\\s*=)''',
    caseSensitive: false,
  );
  // 独立的 Turnstile 控件与普通页面的 challenge-platform 脚本都不证明有整页挑战。
  static final _challengeDocumentMarker = RegExp(
    r'''\b_cf_chl_opt\s*=|\b(?:id|class)\s*=\s*["'](?:challenge-stage|challenge-running)(?:[\s"'])''',
    caseSensitive: false,
  );

  Future<bool> _hasLoadedOriginDocument(
    InAppWebViewController controller,
  ) async =>
      await _readVerificationDocument(controller) ==
      _VerificationDocument.origin;

  bool _canDisplayVerificationDocument(_VerificationDocument document) =>
      document == _VerificationDocument.challenge ||
      document == _VerificationDocument.widget ||
      (document == _VerificationDocument.other &&
          _pageNeeded &&
          !_isBackground &&
          _observation.stage != CfVerificationStage.loadFailed);

  Future<bool> _hasDisplayableVerificationPage(
    InAppWebViewController controller,
  ) async => _canDisplayVerificationDocument(
    await _readVerificationDocument(controller),
  );

  int _revealStateWatchGeneration = 0;

  void _revealChallengeWebView() {
    if (_hasPopped ||
        !mounted ||
        _finishingFromVerifyResponse ||
        _challengeWebViewVisible) {
      return;
    }
    unawaited(
      _controller
              ?.evaluateJavascript(source: 'window.__fluxdoHideCfMask?.();')
              .catchError((Object e) {
                debugPrint('[CfChallenge] 隐藏 DOM mask 失败: $e');
              }) ??
          Future<void>.value(),
    );
    setState(() {
      _challengeWebViewVisible = true;
      _hideOriginFallbackPage = false;
    });
    _syncStartupPage();
    _startRevealedStateWatcher();
  }

  /// reveal 后持续监测：若页面内容退化为非挑战（典型为源站 404），立即重新覆盖
  ///
  /// 触发场景：CF 在 reveal 期间内联跳走（替换 location 而未触发 onLoadStart）、
  /// SPA 路由切换、或 onReceivedHttpError 在当前平台未触发但页面已渲染源站 404。
  void _startRevealedStateWatcher() {
    final watcherGeneration = ++_revealStateWatchGeneration;
    final loadGeneration = _loadGeneration;
    unawaited(() async {
      while (true) {
        await Future.delayed(_revealStateWatchInterval);
        if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
        if (watcherGeneration != _revealStateWatchGeneration) return;
        if (loadGeneration != _loadGeneration) return;
        if (!_challengeWebViewVisible) return;
        // 超时后不再做主动监测，留给已有超时 UI / 用户操作
        if (_hasTimedOut && !_pageNeeded) return;

        final controller = _controller;
        if (controller == null) continue;

        try {
          final visible = await _hasDisplayableVerificationPage(controller);
          if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
          if (watcherGeneration != _revealStateWatchGeneration) return;
          if (loadGeneration != _loadGeneration) return;
          if (visible) continue;

          // 页面无挑战。要么是 CF 已完成跳走，要么是源站 404 渲染出来。
          // 统一交给 fallback 流程：先轮询 cf_clearance，没拿到再给用户重试入口。
          debugPrint('[CfChallenge] reveal 后检测到页面无挑战，主动覆盖并探测 cf_clearance');
          unawaited(
            _handleVerifyOriginFallback(
              loadGeneration,
              reason: 'reveal watcher: page lost CF challenge markers',
              completionLikely: true,
            ),
          );
          return;
        } catch (e) {
          debugPrint('[CfChallenge] reveal watcher 检测异常: $e');
        }
      }
    }());
  }

  void _startChallengeRevealProbe(
    InAppWebViewController controller,
    int generation,
  ) {
    final probeGeneration = ++_challengeRevealProbeGeneration;
    unawaited(() async {
      for (var i = 0; i < 20; i++) {
        if (_hasPopped ||
            !mounted ||
            _finishingFromVerifyResponse ||
            generation != _loadGeneration ||
            probeGeneration != _challengeRevealProbeGeneration) {
          return;
        }

        try {
          if (await _hasDisplayableVerificationPage(controller) &&
              generation == _loadGeneration &&
              probeGeneration == _challengeRevealProbeGeneration) {
            _revealChallengeWebView();
            return;
          }
        } catch (e) {
          debugPrint('[CfChallenge] 检测验证页可见状态异常: $e');
        }

        await Future.delayed(const Duration(milliseconds: 250));
      }
    }());
  }

  void _handlePageReady(InAppWebViewController controller, {String? reason}) {
    if (_hasMarkedPageReady || _hasPopped || _finishingFromVerifyResponse) {
      return;
    }
    _hasMarkedPageReady = true;
    final generation = _loadGeneration;
    _loadStopFallbackTimer?.cancel();
    _pageReadyFallbackTimer?.cancel();

    if (reason != null) {
      debugPrint('[CfChallenge] 页面进入可验证状态: $reason');
    }

    _injectChallengeInterceptor(controller);
    unawaited(_applyOriginalPagePalette());
    _startTimeout();
    _startChallengeRevealProbe(controller, generation);
    _scheduleNoChallengeCheck(controller);
    // 同步立刻探一次内容：识别明确的源站 404 / 非挑战页面时直接覆盖，
    // 避免等到 _noChallengeCheckDelay 才决断，挤压可能的 404 露出窗口
    unawaited(_probeContentImmediately(controller, generation));
  }

  /// 页面就绪后立刻探一次内容
  ///
  /// 命中明确的源站 404 → 直接走 fallback 覆盖；命中 CF 挑战 → reveal；
  /// 介于两者之间（白屏/加载中）就交给 reveal probe + noChallengeCheck 兜底。
  Future<void> _probeContentImmediately(
    InAppWebViewController controller,
    int generation,
  ) async {
    if (_hasPopped || !mounted || _finishingFromVerifyResponse) return;
    if (generation != _loadGeneration) return;
    try {
      final document = await _readVerificationDocument(controller);
      if (_hasPopped ||
          !mounted ||
          _finishingFromVerifyResponse ||
          generation != _loadGeneration) {
        return;
      }
      if (_canDisplayVerificationDocument(document)) {
        _revealChallengeWebView();
        return;
      }
      if (document == _VerificationDocument.origin) {
        _finishFromOriginResponse(
          origin: CfOriginEvidence.document,
          reason: 'loaded verification document reached origin',
        );
      }
    } catch (e) {
      debugPrint('[CfChallenge] 即时内容探测异常: $e');
    }
  }

  void _schedulePageReadyFallback(InAppWebViewController controller) {
    if ((!io.Platform.isWindows && !io.Platform.isLinux) ||
        _hasMarkedPageReady) {
      return;
    }
    _pageReadyFallbackTimer?.cancel();
    _pageReadyFallbackTimer = Timer(_pageReadyFallbackDelay, () {
      _pageReadyFallbackTimer = null;
      if (_hasMarkedPageReady || _hasPopped || _finishingFromVerifyResponse) {
        return;
      }
      _handlePageReady(controller, reason: 'timed fallback');
    });
  }

  void _scheduleLoadStopFallback(
    InAppWebViewController controller,
    int progress,
  ) {
    if ((!io.Platform.isWindows && !io.Platform.isLinux) ||
        _hasMarkedPageReady ||
        progress < 95) {
      return;
    }
    _loadStopFallbackTimer ??= Timer(_loadStopFallbackDelay, () {
      _loadStopFallbackTimer = null;
      if (_hasMarkedPageReady ||
          _hasPopped ||
          _finishingFromVerifyResponse ||
          _progress < 0.95) {
        return;
      }
      _handlePageReady(controller, reason: 'progress fallback');
    });
  }

  Widget _buildChallengeWebView() {
    return WebViewSettings.wrapWithScrollFix(
      _webView ??= InAppWebView(
        key: _webViewKey,
        webViewEnvironment:
            WindowsWebViewEnvironmentService.instance.environment,
        initialUrlRequest: URLRequest(url: WebUri(widget.verifyUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          transparentBackground: true,
          userAgent: AppConstants.webViewUserAgentOverride,
          mediaPlaybackRequiresUserGesture: false,
          useShouldOverrideUrlLoading: true,
          useOnNavigationResponse: true,
        ),
        initialUserScripts: _initialChallengeScripts(),
        shouldOverrideUrlLoading: _shouldOverrideVerifyNavigation,
        onNavigationResponse: _handleVerifyNavigationResponse,
        onReceivedServerTrustAuthRequest: (_, challenge) =>
            WebViewSettings.handleServerTrustAuthRequest(challenge),
        onWebViewCreated: (controller) {
          _controller = controller;
          WebViewSettings.registerJsErrorReporter(controller);
          // 注册 JS Handler，challenge-platform 响应到达时触发
          controller.addJavaScriptHandler(
            handlerName: 'onChallengeComplete',
            callback: _onChallengeComplete,
          );
          // 注册 JS Handler，CF 验证完成后即将跳走时触发，立刻覆盖避免 404 露出
          controller.addJavaScriptHandler(
            handlerName: 'onChallengeNavigation',
            callback: _onChallengeNavigation,
          );
          // 控件的失败与人工交互由 /challenge 主文档转发。
          controller.addJavaScriptHandler(
            handlerName: 'onChallengeWidgetEvent',
            callback: _onChallengeWidgetEvent,
          );
        },
        onLoadStart: (controller, url) {
          if (_hasPopped || _finishingFromVerifyResponse) return;
          final isCompletionNavigation = _hasSeenChallenge;
          _loadGeneration++;
          _documentResponseBlocked = false;
          _currentDocumentChallenged = false;
          if (_observation.stage == CfVerificationStage.widgetError) {
            _report(CfVerificationStage.checking);
          }
          _challengeRevealProbeGeneration++;
          _loadStopFallbackTimer?.cancel();
          _pageReadyFallbackTimer?.cancel();
          _hasMarkedPageReady = false;
          _hasTimedOut = false;
          _challengeWebViewVisible = false;
          _hideOriginFallbackPage = isCompletionNavigation;
          _syncStartupPage();
          if (!isCompletionNavigation) {
            _originProbeGeneration = null;
          }
          _schedulePageReadyFallback(controller);
          setState(() {
            _progress = 0;
          });
          if (isCompletionNavigation) {
            unawaited(
              _handleVerifyOriginFallback(
                _loadGeneration,
                reason: 'loadStart after challenge: ${url?.toString() ?? ''}',
                completionLikely: true,
              ),
            );
          }
        },
        onPageCommitVisible: (controller, url) {
          if (_finishingFromVerifyResponse) return;
          _handlePageReady(controller, reason: 'onPageCommitVisible');
        },
        onProgressChanged: (controller, progress) {
          if (_finishingFromVerifyResponse) return;
          _progress = progress / 100;
          _scheduleLoadStopFallback(controller, progress);
        },
        onLoadStop: (controller, url) {
          if (_finishingFromVerifyResponse) return;
          WebViewSettings.injectScrollFix(controller);
          _handlePageReady(controller, reason: 'onLoadStop');
        },
        onReceivedError: (controller, request, error) {
          // _hasPopped:验证已收场,但 Windows 上 PlatformView 延迟 1.2s
          // 才销毁(见 _postCleanupCooldown)。这段窗口里 WebView2 掐掉
          // 在途主文档导航会上报 CONNECTION_ABORTED,不能再弹「加载失败」
          // ——用户看到的将是验证成功后凭空冒出的错误 toast。
          if (_hasPopped || _finishingFromVerifyResponse) return;

          final uri = Uri.tryParse(request.url.toString());
          final isMainFrame = request.isForMainFrame == true;
          CfChallengeLogger.log(
            '[VERIFY] WebView load error: '
            'mainFrame=$isMainFrame '
            'host=${uri?.host ?? '-'} path=${uri?.path ?? '-'} '
            'type=${error.type} description=${error.description}',
            level: isMainFrame ? 'warning' : 'info',
            fields: {
              'isMainFrame': isMainFrame,
              'host': uri?.host,
              'path': uri?.path,
              'errorType': error.type.toString(),
              'description': error.description,
            },
          );

          // WebView 会把脚本、图片、CF challenge-platform 等子资源错误也
          // 上报到这里。子资源连接被刷新流程关闭时，主验证页通常仍可正常
          // 使用；不要因此结束加载态或向用户显示整页加载失败。
          if (!isMainFrame) return;

          // WebView2 在 CF 完成验证并切换主文档时，会把被替换的旧导航
          // 上报为 CONNECTION_ABORTED。此时完成探测已经接管流程，不应把
          // 浏览器主动停止旧连接误报成直连 DoH 加载失败。
          final isExpectedCompletionAbort =
              io.Platform.isWindows &&
              error.type == WebResourceErrorType.CONNECTION_ABORTED &&
              (_hasSeenChallenge ||
                  _checkingOriginFallback ||
                  _hideOriginFallbackPage);
          if (isExpectedCompletionAbort) return;

          if (_isVerifyUrl(request.url)) {
            _documentResponseBlocked = true;
            final description = error.description.trim();
            _report(
              CfVerificationStage.loadFailed,
              loadErrorDescription: description.isEmpty
                  ? error.type.toString()
                  : description,
            );
            if (_isBackground) {
              _finish(CfVerificationStage.loadFailed);
              return;
            }
            _timeoutTimer?.cancel();
            setState(() => _hideOriginFallbackPage = true);
            _syncStartupPage();
          } else if (!_isBackground && !_startupActive) {
            ToastService.showError(
              context.l10n.cf_loadFailed(error.description),
            );
          }
          _pageReadyFallbackTimer?.cancel();
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          if (_hasPopped || _finishingFromVerifyResponse) return;
          _handleVerifyResponse(
            url: request.url,
            isForMainFrame: request.isForMainFrame,
            statusCode: errorResponse.statusCode,
            headers: errorResponse.headers,
          );
        },
      ),
      getController: () => _controller,
    );
  }

  Widget _buildContextualBarrier(ThemeData theme, bool dialogBlur) {
    final barrierColor = dialogBlur
        ? blurBarrierColor(theme.brightness, scene: ModalBlurScene.dialog)
        : theme.colorScheme.scrim.withValues(
            alpha: theme.brightness == Brightness.dark ? 0.48 : 0.36,
          );
    final secondary =
        _dialogSection != CfVerificationDialogSection.verification;
    final barrier = ModalBarrier(
      dismissible: secondary,
      onDismiss: secondary
          ? () => _setDialogSection(CfVerificationDialogSection.verification)
          : null,
      semanticsLabel: secondary
          ? MaterialLocalizations.of(context).modalBarrierDismissLabel
          : null,
      color: barrierColor,
    );

    if (!dialogBlur) return barrier;

    return BackdropFilter(filter: createBlurFilter(blurSigma), child: barrier);
  }

  Widget _buildContextualVerifyLayer(ThemeData theme) {
    return Consumer(
      builder: (context, ref, _) {
        final blur = ref.watch(
          preferencesProvider.select((prefs) => prefs.dialogBlur),
        );
        final media = MediaQuery.of(context);
        return Material(
          type: MaterialType.transparency,
          child: LayoutBuilder(
            builder: (context, constraints) => CfVerificationDialog(
              bounds: _panelBounds(constraints.biggest, media),
              entryAnchor: _panelRevealFrom,
              barrier: _buildContextualBarrier(theme, blur),
              showPage: _showVerificationPage,
              verification: _observation,
              onReload: _hasPopped || _finishingFromVerifyResponse
                  ? null
                  : _refresh,
              section: _dialogSection,
              onSectionChanged: _setDialogSection,
              onExit: _confirmExit,
              webView: _buildChallengeWebView(),
            ),
          ),
        );
      },
    );
  }

  Rect _panelBounds(Size size, MediaQueryData media) {
    final safe = Rect.fromLTRB(
      math.max(media.padding.left, media.viewInsets.left),
      math.max(media.padding.top, media.viewInsets.top),
      size.width - math.max(media.padding.right, media.viewInsets.right),
      size.height - math.max(media.padding.bottom, media.viewInsets.bottom),
    );
    final gutter = safe.width < 360 ? 8.0 : 16.0;
    return Rect.fromCenter(
      center: safe.center,
      width: math.max(1.0, math.min(520.0, safe.width - 2 * gutter)),
      height: math.max(1.0, math.min(440.0, safe.height - 2 * gutter)),
    );
  }

  Widget _buildBackgroundWebView(MediaQueryData media) {
    final width = _panelBounds(media.size, media).width;
    final height = math.max(1.0, media.size.height - media.padding.vertical);
    return Positioned(
      left: -width - 64,
      top: -height - 64,
      width: width,
      height: height,
      child: ExcludeSemantics(
        child: ExcludeFocus(
          child: IgnorePointer(child: _buildChallengeWebView()),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showUi = !_isBackground && !_startupActive;
    final host = _startupHost;
    final media = MediaQuery.of(context);
    final content = Stack(
      children: [
        if (showUi)
          Positioned.fill(child: _buildContextualVerifyLayer(theme))
        else if (host != null)
          Positioned.fill(
            child: CfStartupVerificationViewport(
              host: host,
              child: _buildChallengeWebView(),
            ),
          )
        else
          _buildBackgroundWebView(media),

        // 普通后台请求保留验证入口，点按后由启动屏或通用弹框接管。
        if (_showPill)
          KeyedSubtree(
            key: _pillKey,
            child: DraggableFloatingPill(
              key: ValueKey(_needsInteraction),
              initialTop: 100,
              initiallyExpanded: _needsInteraction,
              tapToExpand: false,
              busy: !_needsInteraction,
              emphasized: _needsInteraction,
              mark: _needsInteraction
                  ? const CloudflareMark(width: 20)
                  : Tooltip(
                      message: context.l10n.cf_backgroundVerifying,
                      child: const CloudflareMark(width: 15),
                    ),
              onTap: _bringVerificationForward,
              child: Text(switch (_observation.stage) {
                CfVerificationStage.interactionRequired =>
                  S.current.cf_backgroundNeedsAction,
                CfVerificationStage.interactionExpired =>
                  S.current.cf_interactionExpiredTitle,
                CfVerificationStage.widgetError ||
                CfVerificationStage.loadFailed => _observation.label(S.current),
                CfVerificationStage.timedOut =>
                  S.current.cf_verifyTimedOutTitle,
                _ => S.current.cf_backgroundVerifying,
              }),
            ),
          ),
      ],
    );
    // 页面结果交给调用方后立即让出输入和语义，原生 WebView 仍按平台时序销毁。
    return Visibility(
      visible: !_hasPopped,
      maintainState: true,
      child: content,
    );
  }
}

enum _VerificationDocument { unknown, challenge, widget, origin, other }
