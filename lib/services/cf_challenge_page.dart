part of 'cf_challenge_service.dart';

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
