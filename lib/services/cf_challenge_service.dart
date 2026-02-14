import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../constants.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'local_notification_service.dart'; // 用于获取全局 navigatorKey
import 'cf_challenge_logger.dart';
import '../widgets/draggable_floating_pill.dart';

part 'cf_challenge_page.dart';

/// CF 验证服务
/// 处理 Cloudflare Turnstile 验证（仅手动模式）
class CfChallengeService {
  static final CfChallengeService _instance = CfChallengeService._internal();
  factory CfChallengeService() => _instance;
  CfChallengeService._internal();

  bool _isVerifying = false;
  final _verifyCompleter = <Completer<bool>>[];
  BuildContext? _context;
  static DateTime? _lastToastAt;
  Completer<BuildContext>? _contextReadyCompleter;
  VoidCallback? _promoteCallback;
  
  /// 冷却机制：验证失败后进入冷却期
  DateTime? _cooldownUntil;
  static const _cooldownDuration = Duration(seconds: 30);
  static const _toastCooldown = Duration(seconds: 2);
  
  /// 检查是否在冷却期
  bool get isInCooldown {
    if (_cooldownUntil == null) return false;
    if (DateTime.now().isAfter(_cooldownUntil!)) {
      _cooldownUntil = null;
      return false;
    }
    return true;
  }
  
  /// 重置冷却期（验证成功后调用）
  void resetCooldown() {
    _cooldownUntil = null;
    CfChallengeLogger.logCooldown(entering: false);
  }

  /// 手动启动冷却期
  void startCooldown() {
    _cooldownUntil = DateTime.now().add(_cooldownDuration);
    CfChallengeLogger.logCooldown(entering: true, until: _cooldownUntil);
  }

  static void showGlobalMessage(String message, {bool isError = true}) {
    final context = navigatorKey.currentState?.context;
    if (context == null || !context.mounted) return;
    final now = DateTime.now();
    if (_lastToastAt != null && now.difference(_lastToastAt!) < _toastCooldown) {
      return;
    }
    _lastToastAt = now;
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? theme.colorScheme.error : null,
      ),
    );
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

  /// 检测是否是 CF 验证页面
  static bool isCfChallenge(dynamic responseData) {
    if (responseData == null) return false;
    final str = responseData.toString();
    return str.contains('Just a moment') ||
           str.contains('cf_chl_opt') ||
           str.contains('challenge-platform');
  }

  /// 显示手动验证页面
  /// 返回值：true=验证成功, false=验证失败, null=冷却期内暂不可用或无 context
  /// [forceForeground] 是否强制前台显示（默认为 true）
  Future<bool?> showManualVerify([BuildContext? context, bool forceForeground = true]) async {
    // 检查冷却期
    if (isInCooldown) {
      debugPrint('[CfChallenge] In cooldown, skipping manual verify');
      CfChallengeLogger.log('[VERIFY] Skipped: in cooldown');
      return null;
    }

    final verifyUrl = '${AppConstants.baseUrl}/challenge';
    CfChallengeLogger.logVerifyStart(verifyUrl);
    unawaited(CfChallengeLogger.logAccessIps(url: verifyUrl, context: 'verify_start'));
    
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

    // 启动时可能还没有可用的 context，等到 context 可用后立即弹出
    if (ctx == null || !ctx.mounted) {
      _contextReadyCompleter ??= Completer<BuildContext>();
      debugPrint('[CfChallenge] Waiting for context to be ready...');
      ctx = await _contextReadyCompleter!.future;
    }

    // 如果已经在验证中 (Overlay 存在)
    if (_isVerifying) {
        // 如果当前是后台模式，且请求强制前台，则提升为前台
        if (forceForeground) {
          _promoteCallback?.call();
        }

      final completer = Completer<bool>();
      _verifyCompleter.add(completer);
      return completer.future;
    }

    _isVerifying = true;

    // ignore: use_build_context_synchronously
    final overlayState = Overlay.maybeOf(ctx, rootOverlay: true) ?? navigatorKey.currentState?.overlay;
    if (overlayState == null) {
      debugPrint('[CfChallenge] No overlay available for manual verify');
      CfChallengeLogger.log('[VERIFY] No overlay available');
      _isVerifying = false;
      return null;
    }

    // 打开 WebView 前先同步 Cookie 到 WebView
    await CookieJarService().syncToWebView();
    if (!overlayState.mounted) {
      debugPrint('[CfChallenge] Overlay no longer mounted');
      CfChallengeLogger.log('[VERIFY] Overlay not mounted');
      _isVerifying = false;
      return null;
    }

    final resultCompleter = Completer<bool>();
    late final OverlayEntry entry;
    // 引用当前的拦截 Route，用于 cleanup
    ModalRoute? interceptorRoute;
    
    // Page Key 用于触发内部弹窗
    final pageKey = GlobalKey<_CfChallengePageState>();

    // 清理资源
    void cleanup() {
       if (entry.mounted) {
         entry.remove();
       }
       if (interceptorRoute?.isActive ?? false) {
         interceptorRoute?.navigator?.removeRoute(interceptorRoute!);
       }
       _isVerifying = false;
       _promoteCallback = null;
    }

    void finish(bool success) {
      if (!resultCompleter.isCompleted) {
        resultCompleter.complete(success);
      }
      cleanup();
    }
    
    // 创建 OverlayEntry
    // 我们需要传递一个 promoteCallback 给 Page，让 Page 能调用 Service 来 push route
    void onPromoteToForeground(BuildContext pageContext) {
        if (interceptorRoute != null && interceptorRoute!.isActive) return; // 已经有 Route 了
        
        // Push 透明 Route 用于拦截返回键
        interceptorRoute = PageRouteBuilder(
            opaque: false,
            barrierColor: Colors.transparent,
            pageBuilder: (context, _, _) {
                 return PopScope(
                    canPop: false,
                    onPopInvokedWithResult: (didPop, result) async {
                        if (didPop) return;
                        if (!_isVerifying) return;
                        
                        // 触发内部弹窗 via GlobalKey
                        pageKey.currentState?.showExitConfirmation();
                    },
                    // 使用 IgnorePointer 让点击事件穿透到下层的 Overlay (WebView)
                    child: const IgnorePointer(
                      child: SizedBox.expand(),
                    ),
                 );
            },
        );
        
        Navigator.of(pageContext).push(interceptorRoute!).then((_) {
            // Route 被 pop
        });
    }

    entry = OverlayEntry(
      builder: (context) {
        // 注册 promote 回调，供后续 forceForeground 请求使用
        _promoteCallback = () => onPromoteToForeground(context);
        return CfChallengePage(
          key: pageKey,
          startInBackground: !forceForeground,
          onResult: finish,
          onPromoteRequest: () => onPromoteToForeground(context),
        );
      },
    );
    overlayState.insert(entry);
    
    // 如果初始就是前台，立即执行 promote
    if (forceForeground) {
        // Post frame callback to ensure overlay is mounted and context is valid
        WidgetsBinding.instance.addPostFrameCallback((_) {
            // 注意：这里的 ctx 是 Service 传入的 ctx，可能不是 Overlay 的 context
            // 但 Navigator.of(ctx) 应该能找到正确的 Navigator
            // 我们最好使用 OverlayEntry builder 里的 context，但这里访问不到。
            // 使用 ctx 应该是安全的。
             onPromoteToForeground(ctx!);
        });
    }

    final result = await resultCompleter.future;

    // 通知所有等待者
    for (final c in _verifyCompleter) {
      if (!c.isCompleted) c.complete(result);
    }
    _verifyCompleter.clear();

    // 验证成功后重置冷却期
    if (result == true) {
      resetCooldown();
      CfChallengeLogger.logVerifyResult(success: true, reason: 'user completed');
    } else {
      // 验证失败，启动冷却期
      startCooldown();
      debugPrint('[CfChallenge] Verification failed, cooldown until $_cooldownUntil');
      CfChallengeLogger.logVerifyResult(success: false, reason: 'user cancelled or timeout');
    }

    return result;
  }
}

