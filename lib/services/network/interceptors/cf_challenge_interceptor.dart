import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../cf_challenge_service.dart';
import '../../cf_challenge_logger.dart';
import '../../cf_clearance_refresh_service.dart';
import '../../cf_clearance_authority.dart';
import '../../app_logger.dart';
import '../adapters/platform_adapter.dart';
import '../cookie/boundary_sync_service.dart';
import '../cookie/cookie_jar_service.dart';
import '../system_proxy_service.dart';
import '../webview/webview_adapter_settings_service.dart';
import '../../../l10n/s.dart';
import '../exceptions/api_exception.dart';
import '../flux_request_spec.dart';
import '../health/network_health_controller.dart';

/// Cloudflare 验证拦截器
///
/// **为什么它不在恢复层里**(2026-08 评估结论,别再迁):
///
/// 恢复层的契约是"策略只产决策、Coordinator 统一执行重放",这对无状态恢复
/// (限流等待、瞬态重放、会话自愈、引擎降级)成立,但 CF 的重试**之后**还有
/// 三段有状态处置:
/// 1. 重试成功 → 广播 [CfChallengeService.clearanceResolvedAt],
///    BrowserTrustCoordinator 靠它 force 重跑被同一次 CF 挡下的 bootstrap;
/// 2. 重试仍被拦 → 在同一上下文里判断能否切兼容、弹询问、撤 skipWebViewAdapter,
///    **换传输方式再重放一次**;
/// 3. 兼容重放失败 → 回滚 sessionFallback,否则后续请求全锁死在坏通道上。
///
/// 第 2、3 步要求"拿到重试结果后决定下一次用什么传输方式,并在失败时回滚
/// 副作用",而策略拿不到重试结果——重放执行权在 Coordinator 手里。硬迁的
/// 三条路都有害:为单个策略给 RecoveryDecision 加变体会污染通用抽象;策略
/// 自己调 dio.fetch 违反"重放只有一处"这条铁律(等于把六个重放入口的病灶
/// 重新引入);拆成多策略靠预算串联会丢掉回滚的时序保证。
///
/// 所以现状是**终态**:恢复层管无状态重放,本拦截器管需要 UI 交互与传输
/// 切换的有状态恢复。分界由 RateLimitPolicy 的 isChallengeResponse 钩子
/// 划定——挑战型 429 放行给这里,真限流归恢复层。
class CfChallengeInterceptor extends Interceptor {
  CfChallengeInterceptor({required this.dio, required this.cookieJarService});

  final Dio dio;
  final CookieJarService cookieJarService;

  /// 共享的 cookie 同步 Future：验证成功后只执行一次 sync
  static Future<void>? _activeSyncFuture;

  static const _mutationMethods = {'POST', 'PUT', 'DELETE', 'PATCH'};

  /// 验证成功后的共享 Cookie 同步（只执行一次）
  Future<void> _syncCookiesOnce() async {
    // 如果已有同步任务在进行，复用结果
    if (_activeSyncFuture != null) return _activeSyncFuture!;

    _activeSyncFuture = _doSync();
    try {
      return await _activeSyncFuture!;
    } finally {
      _activeSyncFuture = null;
    }
  }

  Future<void> _doSync() async {
    try {
      await CfChallengeService().waitForCompletionCookieSync();
      // 已有值时直接复用；没有时只同步一次当前快照。验证入口可能直接
      // 放行而不签发 Cookie，不能等待续期，也不能因此拒绝原请求。
      final clearance = await cookieJarService.getCfClearance();
      if (clearance != null && clearance.isNotEmpty) return;
      await BoundarySyncService.instance.syncFromWebView(
        cookieNames: {'cf_clearance'},
      );
    } catch (e) {
      CfChallengeLogger.log(
        '[INTERCEPTOR] Cookie sync unavailable; retrying with current cookies: $e',
        level: 'warning',
      );
    }
  }

  bool _shouldShowActionPrompt(RequestOptions options) {
    final spec = options.spec;
    if (spec.isSilent) return false;
    if (spec.hasExplicitErrorToast) {
      return spec.showErrorToast;
    }
    return _mutationMethods.contains(options.method.toUpperCase());
  }

  String _requestMode(RequestOptions options) {
    if (options.spec.isSilent) return 'silent';
    return _shouldShowActionPrompt(options) ? 'action' : 'data';
  }

  Future<void> _refreshCookieHeader(RequestOptions options) async {
    options.headers.remove('cookie');
    options.headers.remove('Cookie');

    final cookieHeader = await cookieJarService.getCookieHeaderForRequest(
      options.uri,
    );
    if (cookieHeader != null && cookieHeader.isNotEmpty) {
      options.headers['Cookie'] = cookieHeader;
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final statusCode = err.response?.statusCode;

    // 检查是否标记跳过 CF 验证（防止重试后再次触发）
    final skipCfChallenge = err.requestOptions.spec.skipCfChallenge;

    // CF 速率限制规则的 action 配为 managed_challenge / js_challenge / challenge 时,
    // 触发后返回 429 + cf-mitigated: challenge + 挑战页,而不是 403。
    // 因此 403 / 429 都要走 CF 验证流程,由 isCfChallengeResponse 精确判定。
    if ((statusCode == 403 || statusCode == 429) &&
        !skipCfChallenge &&
        CfChallengeService.isCfChallengeResponse(err.response)) {
      // 备选提取 sitekey（从 403 响应体中）
      CfClearanceRefreshService().extractAndUpdateSitekey(
        err.response?.data?.toString() ?? '',
      );
      // 403 说明 cf_clearance 已失效，停止自动续期（避免与手动验证冲突）。
      // 这里不需要 await——真正要建验证 WebView 前，showManualVerify 内部
      // 会自己再 await 一次 stop()，确保销毁完成。
      unawaited(CfClearanceRefreshService().stop());

      final requestUrl = err.requestOptions.uri.toString();
      final requestMethod = err.requestOptions.method.toUpperCase();
      final requestTag = err.requestOptions.spec.requestTag;
      final logMessage =
          'CF Challenge detected: $requestMethod $requestUrl '
          '(status=$statusCode, silent=${err.requestOptions.spec.isSilent}, '
          'tag=${requestTag ?? '-'}, skipCsrf=${err.requestOptions.spec.skipCsrf})';
      debugPrint('[Dio] $logMessage');
      AppLogger.warning(logMessage, tag: 'CfChallengeInterceptor');
      // 撞盾是排查网络问题的关键时刻:把此刻的通道健康全貌拍进日志,
      // 免得事后只有"某请求 403"这一条结果、没有引擎/降级/凭证状态。
      NetworkHealthController.instance.dumpToLog('cf_challenge_detected');
      // 命中 CF 盾时立即重读系统代理状态:若用户刚开/关了系统代理,
      // 下一个请求就能用一致的出口重试,而不是等 10s 周期刷新。
      SystemProxyService.instance.refresh();
      CfChallengeLogger.logInterceptorDetected(
        url: requestUrl,
        statusCode: statusCode!,
      );
      // 记录在位值被撞：本次请求携带的 cf_clearance 已被 CF 挑战（= 已死），
      // 打开换届窗口——之后 sync 可以替换它（过盾新值继位，或 Turnstile
      // 最新铸值无缝补位）。这里不做任何候选值判定、不分 403/429：
      // 撞了就过盾，语义见 CfClearanceAuthority。
      CfClearanceAuthority.instance.noteIncumbentChallenged(
        CfClearanceAuthority.extractFromCookieHeader(
          err.requestOptions.headers['Cookie']?.toString() ??
              err.requestOptions.headers['cookie']?.toString(),
        ),
      );
      final cfService = CfChallengeService();
      final isSilent = err.requestOptions.spec.isSilent;
      final shouldShowActionPrompt = _shouldShowActionPrompt(
        err.requestOptions,
      );
      final requestMode = _requestMode(err.requestOptions);

      DioException cfException(CfChallengeException error) {
        return DioException(
          requestOptions: err.requestOptions,
          error: error,
          type: DioExceptionType.unknown,
        );
      }

      if (!cfService.autoVerifyEnabled) {
        CfChallengeLogger.log(
          '[INTERCEPTOR] Auto verify disabled, rejecting: '
          '$requestMethod $requestUrl mode=$requestMode',
        );
        return handler.reject(
          cfException(CfChallengeException(autoVerifyDisabled: true)),
        );
      }

      // 注:这里刻意**不**用 NetworkHealthController.hasForegroundUi 提前判掉
      // 无 UI 环境。它的判据是 navigatorKey.currentContext,而主 isolate 启动
      // 早期那也是 null —— 提前 reject 会毁掉"启动时撞盾、等 context 就绪后
      // 补弹验证"这条路径(启动窗口恰恰是验证最该成功的时候)。
      // 无 UI 环境由 showManualVerify 内部的 10s context 等待上限收口。

      if (cfService.isInCooldown) {
        debugPrint('[Dio] CF Challenge in cooldown, rejecting request');
        CfChallengeLogger.log(
          '[INTERCEPTOR] Cooldown after 403: $requestMethod $requestUrl '
          'mode=$requestMode',
        );
        if (shouldShowActionPrompt) {
          CfChallengeService.showGlobalMessage(
            S.current.cf_operationBlockedByChallenge,
          );
        }
        return handler.reject(
          cfException(CfChallengeException(inCooldown: true)),
        );
      }

      // 静默请求只在后台尝试验证；页面数据/操作请求在前台展示验证。
      // (Windows 曾因插件析构竞态崩溃 0xc0000005 禁用过静默后台验证;
      // vendored 插件的 aliveGuard/TextureBridge 修复落地后恢复。)
      final result = await cfService.showManualVerify(null, !isSilent);

      if (result == true) {
        await _syncCookiesOnce();

        // 各自重试自己的原始请求（每个请求 URL/参数不同，无法共享）
        final retryOptions = err.requestOptions;
        try {
          retryOptions.extra[FluxRequestKeys.skipCfChallenge] = true;
          // 绕过 RequestScheduler 的 CF 冻结判定。retry 时序上 isVerifying 已经
          // 复位为 false，但加这个标记是双保险，防止未来逻辑变更引入 race。
          retryOptions.extra[FluxRequestKeys.skipCfBlock] = true;
          // 清除原始请求中残留的 cookie header，并补上最新 Cookie。
          // 这样即使 dio.fetch 不重新经过 CookieManager，也不会继续发送旧值。
          await _refreshCookieHeader(retryOptions);
          // 诊断：记录 CookieJar 中的 cookie 名称和 cf_clearance 状态
          final cookieHeader =
              retryOptions.headers['Cookie']?.toString() ??
              retryOptions.headers['cookie']?.toString();
          final hasCfClearance =
              cookieHeader?.contains('cf_clearance=') ?? false;
          final cookieNames = cookieHeader
              ?.split('; ')
              .map((c) => c.split('=').first)
              .join(', ');
          debugPrint(
            '[Dio] Retry cookies: ${hasCfClearance ? "✓ 包含 cf_clearance" : "⚠️ 缺少 cf_clearance"}, '
            'names=[$cookieNames], total=${cookieHeader?.length ?? 0} chars',
          );
          final response = await dio.fetch(retryOptions);
          CfChallengeLogger.logInterceptorRetry(
            url: requestUrl,
            success: true,
            statusCode: response.statusCode,
          );
          // 广播:Dio 侧真实重试成功。供 BrowserTrustCoordinator
          // 感知"CF 已解决",从而 force 重跑因同一 CF 失败的 WebView session bootstrap。
          cfService.clearanceResolvedAt.value = DateTime.now();
          return handler.resolve(response);
        } catch (e) {
          final retryStillBlockedByCf =
              e is DioException &&
              (e.response?.statusCode == 403 ||
                  e.response?.statusCode == 429) &&
              CfChallengeService.isCfChallengeResponse(e.response);

          // 验证入口已无盾，原生链路仍被 CF 拒绝。浏览器与原生通道的
          // 放行结果可能不同，仅对用户可见请求询问一次，
          // 用户确认后本次会话改用浏览器网络栈，并立即重放原请求。
          if (retryStillBlockedByCf &&
              !isSilent &&
              requestCanUseWebViewAdapter(retryOptions)) {
            final webViewSettings = WebViewAdapterSettingsService.instance;
            final shouldFallback =
                webViewSettings.effectiveEnabled ||
                await cfService.confirmSessionCompatibilityMode();
            if (shouldFallback) {
              webViewSettings.enableSessionFallback();
              // 撤销原请求的"禁走 WebView 适配器"标记,这一行才是让重放
              // 真正改走浏览器网络栈的开关。
              retryOptions.extra.remove(FluxRequestKeys.skipWebViewAdapter);
              try {
                final fallbackResponse = await dio.fetch(retryOptions);
                CfChallengeService.showGlobalMessage(
                  S.current.cf_sessionCompatEnabled,
                  isError: false,
                );
                CfChallengeLogger.log(
                  '[INTERCEPTOR] Native retry still blocked; '
                  'session WebView fallback succeeded',
                );
                return handler.resolve(fallbackResponse);
              } catch (fallbackError) {
                // 会话级兼容必须以首次真实请求成功为准；失败时立即回滚，
                // 避免所有后续请求被锁在一个坏掉的 WebView 传输状态里。
                if (!webViewSettings.persistentEnabled) {
                  webViewSettings.disableSessionFallback();
                }
                CfChallengeLogger.log(
                  '[INTERCEPTOR] Session WebView fallback failed: '
                  '$fallbackError',
                  level: 'warning',
                );
                if (fallbackError is DioException) {
                  return handler.reject(fallbackError);
                }
                return handler.reject(
                  DioException(
                    requestOptions: retryOptions,
                    error: fallbackError,
                    type: DioExceptionType.unknown,
                  ),
                );
              }
            }
          }

          // 诊断：记录完整的重试失败信息
          if (e is DioException) {
            debugPrint(
              '[Dio] Retry failed: status=${e.response?.statusCode}, '
              'type=${e.type}, url=${e.requestOptions.uri}',
            );
            if (e.response?.statusCode == 403 ||
                e.response?.statusCode == 429) {
              debugPrint(
                '[Dio] Verification entry is clear, but API retry returned ${e.response?.statusCode}',
              );
              // 以真实重试仍命中 CF 为冷却依据。入口无盾不保证 API 放行，
              // 也不保证本轮有新 Cookie；避免立刻反复打开同一个验证入口。
              if (CfChallengeService.isCfChallengeResponse(e.response)) {
                cfService.startIneffectiveClearanceCooldown();
                // 仅记录这次重试实际携带的值；可能没有 clearance，不能把
                // 「Cookie 未签发」本身当成失败或拉黑依据。
                CfClearanceAuthority.instance.noteIncumbentChallenged(
                  CfClearanceAuthority.extractFromCookieHeader(
                    retryOptions.headers['Cookie']?.toString() ??
                        retryOptions.headers['cookie']?.toString(),
                  ),
                );
                CfChallengeLogger.log(
                  '[INTERCEPTOR] Origin verification finished but API still challenged '
                  '(retry ${e.response?.statusCode}), entering cooldown: '
                  '$requestMethod $requestUrl',
                  level: 'warning',
                );
                if (shouldShowActionPrompt) {
                  CfChallengeService.showGlobalMessage(
                    S.current.cf_challengeNotEffective,
                  );
                }
              }
            }
          } else {
            debugPrint('[Dio] Retry failed (non-Dio): $e');
          }
          CfChallengeLogger.logInterceptorRetry(
            url: requestUrl,
            success: false,
            error: e.toString(),
          );
          // 验证页面已经结束；保留真实重试错误和状态码，供调用方判断恢复。
          if (e is DioException) {
            return handler.reject(e);
          }
          return handler.reject(
            DioException(
              requestOptions: err.requestOptions,
              error: e,
              type: DioExceptionType.unknown,
            ),
          );
        }
      }

      if (result == null) {
        if (cfService.isInCooldown) {
          CfChallengeLogger.log(
            '[INTERCEPTOR] Verification skipped by cooldown: '
            '$requestMethod $requestUrl mode=$requestMode',
          );
          if (shouldShowActionPrompt) {
            CfChallengeService.showGlobalMessage(
              S.current.cf_operationBlockedByChallenge,
            );
          }
          return handler.reject(
            cfException(CfChallengeException(inCooldown: true)),
          );
        }

        // 无 context（应用刚启动，context 还没设置好）
        debugPrint(
          '[Dio] CF Challenge: no context available, cannot show verify page',
        );
        CfChallengeLogger.log('[INTERCEPTOR] No context available');
        if (shouldShowActionPrompt) {
          CfChallengeService.showGlobalMessage(
            S.current.cf_cannotOpenVerifyPage,
          );
        }
        return handler.reject(
          cfException(CfChallengeException(cause: '无法获取 context，验证页面未展示')),
        );
      }

      // 用户取消或验证失败。页面数据请求交给 ErrorView 展示按钮；操作请求给即时提示；静默请求不打扰。
      CfChallengeLogger.log(
        '[INTERCEPTOR] User cancelled or verify failed: '
        '$requestMethod $requestUrl mode=$requestMode',
      );
      if (shouldShowActionPrompt) {
        CfChallengeService.showGlobalMessage(S.current.cf_verifyIncomplete);
      }
      return handler.reject(
        cfException(CfChallengeException(userCancelled: true)),
      );
    }

    handler.next(err);
  }
}
