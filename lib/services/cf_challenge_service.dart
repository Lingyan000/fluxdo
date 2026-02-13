import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../constants.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'local_notification_service.dart'; // 用于获取全局 navigatorKey
import 'cf_challenge_logger.dart';
import '../widgets/draggable_floating_pill.dart';

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
             // 找到当前的 State 并调用 promoteToForeground
             // 这里我们需要访问到 CfChallengePage 的 State
             // 由于无法直接访问，我们将通过 EventBus 或简单的 GlobalKey/Callback 机制
             // 在此简化处理：我们假设 _isVerifying 意味着正在运行
             // 实际上，如果已经在运行，我们只需返回当前的 future
             // 但我们需要通知 UI 切换到前台。
             // FIXME: 这里简单的返回 future 可能无法触发 UI 变更。
             // 由于 CfChallengeService 是单例，我们可以持有一个 key 或回调
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
      builder: (context) => CfChallengePage(
        key: pageKey,
        startInBackground: !forceForeground,
        onResult: finish,
        onPromoteRequest: () => onPromoteToForeground(context),
      ),
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

/// CF 验证页面
class CfChallengePage extends StatefulWidget {
  const CfChallengePage({
    super.key,
    this.startInBackground = false,
    this.onResult,
    this.onPromoteRequest,
  });

  /// 先后台尝试验证，超时后再切到前台
  final bool startInBackground;
  final ValueChanged<bool>? onResult;
  final VoidCallback? onPromoteRequest;

  @override
  State<CfChallengePage> createState() => _CfChallengePageState();
}

class _CfChallengePageState extends State<CfChallengePage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  double _progress = 0;
  Timer? _checkTimer;
  String? _initialCfClearance;
  bool _navigatedAfterClearance = false;
  bool _hasPopped = false; // 防止重复 pop
  late bool _isBackground;
  int _checkCount = 0;
  static const _backgroundMaxCheckCount = 10;
  static const _foregroundMaxCheckCount = 60;

  int get _activeMaxCheckCount =>
      _isBackground ? _backgroundMaxCheckCount : _foregroundMaxCheckCount;

  @override
  void dispose() {
    _checkTimer?.cancel();
    super.dispose();
  }

  bool _showExitDialog = false;

  Future<void> showExitConfirmation() async {
     if (!mounted) return;
     setState(() {
       _showExitDialog = true;
     });
  }
  
  void _dismissExitConfirmation() {
    if (!mounted) return;
    setState(() {
      _showExitDialog = false;
    });
  }

  void _confirmExit() {
    if (!mounted) return;
    _finish(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showUi = !_isBackground;

    return Stack(
      children: [
        // 内容层：显示 WebView UI
        IgnorePointer(
          ignoring: _isBackground || _showExitDialog, // 如果显示弹窗，忽略底层点击
          child: Opacity(
            opacity: _isBackground ? 0 : 1,
            child: Scaffold(
              appBar: showUi
                  ? AppBar(
                      title: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('安全验证'),
                          if (_checkCount > 0)
                            Text(
                              '验证中... ${_checkCount}s',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                      leading: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: showExitConfirmation,
                      ),
                      actions: [
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: _refresh,
                          tooltip: '刷新',
                        ),
                        IconButton(
                          icon: const Icon(Icons.help_outline),
                          onPressed: _showHelp,
                          tooltip: '帮助',
                        ),
                      ],
                    )
                  : null,
              body: Column(
                children: [
                  if (showUi && _isLoading)
                    LinearProgressIndicator(
                      value: _progress > 0 ? _progress : null,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        // WebView
                        // 仅在后台时忽略 WebView 的点击
                        IgnorePointer(
                          ignoring: _isBackground,
                          child: InAppWebView(
                            initialUrlRequest: URLRequest(
                                url: WebUri('${AppConstants.baseUrl}/challenge')),
                            initialSettings: InAppWebViewSettings(
                              javaScriptEnabled: true,
                              userAgent: AppConstants.userAgent,
                              mediaPlaybackRequiresUserGesture: false,
                            ),
                            onWebViewCreated: (controller) =>
                                _controller = controller,
                            onLoadStart: (controller, url) {
                              setState(() {
                                _isLoading = true;
                                _progress = 0;
                              });
                              _startVerifyCheck(controller, restart: false);
                            },
                            onProgressChanged: (controller, progress) {
                              _progress = progress / 100;
                              if (showUi) {
                                setState(() {});
                              }
                            },
                            onLoadStop: (controller, url) {
                              if (mounted) {
                                setState(() => _isLoading = false);
                              }
                              _startVerifyCheck(controller);
                            },
                            onReceivedError: (controller, request, error) {
                              if (mounted) {
                                setState(() => _isLoading = false);
                              }
                              if (showUi) {
                                _showError('加载失败: ${error.description}');
                              }
                            },
                          ),
                        ),
                        
                        // 警告卡片 (位于 Inner Stack，仅在前台显示)
                        if (showUi &&
                            _checkCount > _activeMaxCheckCount - 10 &&
                            _checkCount <= _activeMaxCheckCount)
                          Positioned(
                            bottom: 16,
                            left: 16,
                            right: 16,
                            child: Card(
                              color: theme.colorScheme.errorContainer,
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.warning_amber_rounded,
                                      color: theme.colorScheme.onErrorContainer,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '验证时间较长，还剩 ${_activeMaxCheckCount - _checkCount} 秒',
                                        style: TextStyle(
                                          color: theme.colorScheme.onErrorContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 内部弹窗层 (Internal Dialog Layer)
        // 解决 Z-Index 问题：确保弹窗显示在 WebView 之上
        if (_showExitDialog)
           Stack(
             children: [
                // 遮罩
                GestureDetector(
                  onTap: _dismissExitConfirmation,
                  child: Container(
                    color: Colors.black54,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                ),
                // 弹窗
                Center(
                  child: AlertDialog(
                    title: const Text('放弃验证？'),
                    content: const Text('退出验证将导致相关功能无法使用，确定要退出吗？'),
                    actions: [
                      TextButton(
                        onPressed: _dismissExitConfirmation,
                        child: const Text('继续验证'),
                      ),
                      TextButton(
                        onPressed: _confirmExit,
                        child: Text(
                          '退出',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ), 
                ),
             ],
           ),

        if (_showHelpDialog)
          Stack(
            children: [
              // 遮罩
              GestureDetector(
                onTap: _dismissHelp,
                child: Container(
                  color: Colors.black54,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
              // 弹窗
              Center(
                child: AlertDialog(
                  title: const Text('验证帮助'),
                  content: const Text(
                    '这是 Cloudflare 安全验证页面。\n\n'
                    '请完成页面上的验证挑战（如勾选框或滑块）。\n\n'
                    '验证成功后会自动关闭此页面。\n\n'
                    '如果长时间无法完成，可以尝试：\n'
                    '• 点击刷新按钮重新加载\n'
                    '• 检查网络连接\n'
                    '• 关闭后稍后再试',
                  ),
                  actions: [
                    TextButton(
                      onPressed: _dismissHelp,
                      child: const Text('知道了'),
                    ),
                  ],
                ),
              ),
            ],
          ),

        // 悬浮验证胶囊 (位于 Outer Stack，仅在后台显示)
        if (_isBackground)
          DraggableFloatingPill(
            initialTop: 100,
            onTap: _promoteToForeground,
            child: const Text('后台验证中... (点击打开)'),
          ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _isBackground = widget.startInBackground;
  }

  /// 启动定时检查验证状态（非阻塞）
  void _startVerifyCheck(
    InAppWebViewController controller, {
    bool restart = true,
  }) {
    if (!restart && (_checkTimer?.isActive ?? false)) {
      return;
    }
    _checkTimer?.cancel();
    _checkCount = 0;

    Future<String?> getCfClearance() async {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(AppConstants.baseUrl));
      for (final cookie in cookies) {
        if (cookie.name == 'cf_clearance') return cookie.value;
      }
      return null;
    }

    _checkTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      _checkCount++;
      if (!_isBackground) {
        setState(() {}); // 更新计数显示
      }

      if (_checkCount > _activeMaxCheckCount) {
        if (_isBackground) {
          CfChallengeLogger.log(
              '[VERIFY] Background timeout after $_activeMaxCheckCount seconds, prompting manual verify');
          // 超时后调用 promoteToForeground 切到前台
          _promoteToForeground();
          return;
        }
        timer.cancel();
        CfChallengeLogger.logVerifyResult(success: false, reason: 'timeout after $_activeMaxCheckCount seconds');
        if (mounted) {
          _showError('验证超时，请重试');
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) {
            _finish(false);
          }
        }
        return;
      }

      try {
        _initialCfClearance ??= await getCfClearance();
        final html = await controller.evaluateJavascript(source: 'document.body.innerHTML');
        final isChallenge = CfChallengeService.isCfChallenge(html);
        final currentCfClearance = await getCfClearance();
        final clearanceChanged = currentCfClearance != null &&
            currentCfClearance.isNotEmpty &&
            (_initialCfClearance == null || currentCfClearance != _initialCfClearance);

        debugPrint('[CfChallenge] tick#$_checkCount isChallenge=$isChallenge hasClearance=${currentCfClearance != null}');
        CfChallengeLogger.logVerifyCheck(
          checkCount: _checkCount,
          isChallenge: isChallenge,
          cfClearance: currentCfClearance,
          clearanceChanged: clearanceChanged,
        );

        // 验证成功条件：HTML 不包含验证标记 且 cf_clearance Cookie 存在
        if (html != null && !isChallenge && currentCfClearance != null && currentCfClearance.isNotEmpty) {
          timer.cancel();
          CfChallengeLogger.logVerifyResult(success: true, reason: 'page loaded and cf_clearance present');
          if (mounted) {
            _finish(true);
          }
          return;
        }

        if (clearanceChanged) {
          debugPrint('[CfChallenge] clearance updated');
          if (!_navigatedAfterClearance) {
            _navigatedAfterClearance = true;
            debugPrint('[CfChallenge] navigating to baseUrl');
            await controller.loadUrl(
              urlRequest: URLRequest(url: WebUri(AppConstants.baseUrl)),
            );
            return;
          }
          // cf_clearance 已更新且已导航，确认验证成功
          timer.cancel();
          CfChallengeLogger.logVerifyResult(success: true, reason: 'clearance changed after navigation');
          if (mounted) {
            _finish(true);
          }
        }
      } catch (e) {
        debugPrint('[CfChallenge] Check error: $e');
        CfChallengeLogger.log('[VERIFY] Check error: $e');
      }
    });
  }

  void _refresh() {
    _checkTimer?.cancel();
    _checkCount = 0;
    _initialCfClearance = null;
    _navigatedAfterClearance = false;
    setState(() {
      _isLoading = true;
      _progress = 0;
    });
    _controller?.reload();
  }

  void _promoteToForeground() {
    if (!_isBackground) return;
    setState(() {
      _isBackground = false;
      _checkCount = 0;
    });
    // 调用回调以触发 Service 层的 Route Push
    widget.onPromoteRequest?.call();
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showInfo('自动验证超时，请手动完成验证');
    });
  }

  void _finish(bool success) {
    if (_hasPopped) return;
    _hasPopped = true;
    final handler = widget.onResult;
    if (handler != null) {
      handler(success);
    } else {
      Navigator.of(context).pop(success);
    }
  }

  void _showInfo(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  bool _showHelpDialog = false;

  void _showHelp() {
    if (!mounted) return;
    setState(() {
      _showHelpDialog = true;
    });
  }

  void _dismissHelp() {
    if (!mounted) return;
    setState(() {
      _showHelpDialog = false;
    });
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 3),
      ),
    );
  }
}
