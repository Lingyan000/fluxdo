part of 'discourse_service.dart';

/// 认证相关
mixin _AuthMixin on _DiscourseServiceBase {
  static const Duration _authInvalidStrikeWindow = Duration(seconds: 45);
  static const Duration _authInconclusiveCooldown = Duration(seconds: 30);
  int _authInvalidStrikeCount = 0;
  DateTime? _lastAuthInvalidAt;
  Future<bool?>? _authRecheckFuture;
  DateTime? _lastAuthRecheckInconclusiveAt;

  void _resetAuthInvalidState() {
    _authInvalidStrikeCount = 0;
    _lastAuthInvalidAt = null;
    _lastAuthRecheckInconclusiveAt = null;
  }

  bool _shouldSuppressAuthInvalidDuringInconclusiveCooldown() {
    final last = _lastAuthRecheckInconclusiveAt;
    if (last == null) return false;
    return DateTime.now().difference(last) <= _authInconclusiveCooldown;
  }

  void _runAuthHandlingInBackground(
    Future<void> Function() task, {
    required String event,
    String? source,
    String? triggerInfo,
  }) {
    unawaited(
      task().catchError((Object error, StackTrace stackTrace) {
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': event,
          'message': '后台认证异常处理任务失败',
          if (source != null) 'source': source,
          if (triggerInfo != null) 'trigger': triggerInfo,
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        });
      }),
    );
  }

  int _registerAuthInvalidStrike() {
    final now = DateTime.now();
    if (_lastAuthInvalidAt == null ||
        now.difference(_lastAuthInvalidAt!) > _authInvalidStrikeWindow) {
      _authInvalidStrikeCount = 1;
    } else {
      _authInvalidStrikeCount += 1;
    }
    _lastAuthInvalidAt = now;
    return _authInvalidStrikeCount;
  }

  int _registerAuthInvalidStrikeForEvent() {
    // 同一轮会话复检进行中时，把并发异常折叠成同一次 strike。
    // 否则一次首页刷新触发的多个并发请求，可能在同一个「不确定」复检结果上
    // 直接把 strike 叠满，误触发被动登出。
    if (_authRecheckFuture != null && _authInvalidStrikeCount > 0) {
      _lastAuthInvalidAt = DateTime.now();
      return _authInvalidStrikeCount;
    }
    return _registerAuthInvalidStrike();
  }

  Future<bool?> _probeSessionStillValid({
    required String source,
    String? triggerInfo,
  }) {
    final inFlight = _authRecheckFuture;
    if (inFlight != null) return inFlight;

    final future = _probeSessionStillValidImpl(
      source: source,
      triggerInfo: triggerInfo,
    );
    _authRecheckFuture = future;
    future.whenComplete(() {
      if (identical(_authRecheckFuture, future)) {
        _authRecheckFuture = null;
      }
    });
    return future;
  }

  Future<bool?> _probeSessionStillValidImpl({
    required String source,
    String? triggerInfo,
  }) async {
    try {
      try {
        await BoundarySyncService.instance.syncFromWebView(
          cookieNames: {'_t', '_forum_session', 'cf_clearance'},
        );
      } catch (e) {
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'info',
          'type': 'auth',
          'event': 'auth_recheck_boundary_sync_failed',
          'message': '会话复检前的 WebView→CookieJar 同步失败，继续尝试 session 复检',
          'source': source,
          if (triggerInfo != null) 'trigger': triggerInfo,
          'error': e.toString(),
        });
      }

      final tTokenBeforeProbe = await _cookieJar.getTToken();
      final cfClearanceBeforeProbe = await _cookieJar.getCfClearance();

      final response = await _dio.get(
        '/session/current.json',
        queryParameters: {'_': DateTime.now().millisecondsSinceEpoch},
        options: Options(
          extra: {
            'skipAuthCheck': true,
            'skipCsrf': true,
          },
        ),
      );

      final data = response.data;
      if (data is! Map<String, dynamic>) {
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'warning',
          'type': 'auth',
          'event': 'auth_recheck_inconclusive',
          'message': '会话复检返回了非预期数据结构，暂不执行登出',
          'source': source,
          if (triggerInfo != null) 'trigger': triggerInfo,
          'statusCode': response.statusCode,
          'dataType': data.runtimeType.toString(),
        });
        return null;
      }

      final currentUser = data['current_user'];
      if (currentUser is Map<String, dynamic>) {
        final user = User.fromJson(currentUser);
        currentUserNotifier.value = user;
        if (user.username.isNotEmpty) {
          _username = user.username;
          await _storage.write(
            key: DiscourseService._usernameKey,
            value: user.username,
          );
        }
        final liveToken = await _cookieJar.getTToken();
        if (liveToken != null && liveToken.isNotEmpty) {
          _tToken = liveToken;
        }
        LogWriter.instance.write({
          'timestamp': DateTime.now().toIso8601String(),
          'level': 'info',
          'type': 'auth',
          'event': 'auth_recovered_after_probe',
          'message': '会话复检成功，保留当前登录态',
          'source': source,
          if (triggerInfo != null) 'trigger': triggerInfo,
          'username': user.username,
          'hasTBeforeProbe': tTokenBeforeProbe != null && tTokenBeforeProbe.isNotEmpty,
          'hasCfClearanceBeforeProbe': cfClearanceBeforeProbe != null && cfClearanceBeforeProbe.isNotEmpty,
        });
        return true;
      }

      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'auth_recheck_failed',
        'message': '会话复检确认 current_user 不存在',
        'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'statusCode': response.statusCode,
      });
      return false;
    } on DioException catch (e) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'auth_recheck_inconclusive',
        'message': '会话复检请求失败，暂不执行登出',
        'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'statusCode': e.response?.statusCode,
        'errorType': e.type.toString(),
        'url': e.requestOptions.uri.toString(),
      });
      return null;
    } catch (e) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'warning',
        'type': 'auth',
        'event': 'auth_recheck_inconclusive',
        'message': '会话复检发生异常，暂不执行登出',
        'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'error': e.toString(),
      });
      return null;
    }
  }

  /// 初始化拦截器
  void _initInterceptors() {
    // 添加业务特定拦截器
    _dio.interceptors.insert(
      0,
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (!_credentialsLoaded) {
            await _loadStoredCredentials();
            _credentialsLoaded = true;
          }

          final liveToken = await _cookieJar.getTToken();
          if (liveToken != _tToken) {
            if ((liveToken == null || liveToken.isEmpty) &&
                _tToken != null &&
                _tToken!.isNotEmpty) {
              LogWriter.instance.write({
                'timestamp': DateTime.now().toIso8601String(),
                'level': 'warning',
                'type': 'auth',
                'event': 'token_desync_before_request',
                'message': '请求前检测到内存 token 与 CookieJar 不一致，已按 CookieJar 修正',
                'method': options.method,
                'url': options.uri.toString(),
                'memTokenLen': _tToken?.length,
                'jarTokenLen': liveToken?.length,
              });
            }
            _tToken = (liveToken != null && liveToken.isNotEmpty)
                ? liveToken
                : null;
          }

          if (_tToken != null && _tToken!.isNotEmpty) {
            options.headers['Discourse-Logged-In'] = 'true';
            options.headers['Discourse-Present'] = 'true';
          } else {
            options.headers.remove('Discourse-Logged-In');
            options.headers.remove('Discourse-Present');
          }

          debugPrint('[DIO] ${options.method} ${options.uri}');
          handler.next(options);
        },
        onResponse: (response, handler) async {
          final skipAuthCheck =
              response.requestOptions.extra['skipAuthCheck'] == true;

          final loggedOut = response.headers.value('discourse-logged-out');
          if (!skipAuthCheck &&
              loggedOut != null &&
              loggedOut.isNotEmpty &&
              !_isLoggingOut) {
            _runAuthHandlingInBackground(
              () => _onDiscourseLoggedOut(
                source: 'response_header',
                triggerInfo:
                    '${response.requestOptions.method} ${response.requestOptions.uri} → ${response.statusCode}',
                requestOptions: response.requestOptions,
                statusCode: response.statusCode,
                responseHeaders: response.headers.map,
              ),
              event: 'auth_response_header_background_failed',
              source: 'response_header',
              triggerInfo:
                  '${response.requestOptions.method} ${response.requestOptions.uri} → ${response.statusCode}',
            );
            return handler.next(response);
          }

          final tToken = await _cookieJar.getTToken();
          if (tToken != null && tToken.isNotEmpty) {
            _tToken = tToken;
            _resetAuthInvalidState();
          } else if (_tToken != null && _tToken!.isNotEmpty) {
            LogWriter.instance.write({
              'timestamp': DateTime.now().toIso8601String(),
              'level': 'warning',
              'type': 'auth',
              'event': 'token_missing_after_response',
              'message': '响应后 CookieJar 中未检测到 _t，本次仅记录告警，不立即清空内存 token',
              'method': response.requestOptions.method,
              'url': response.requestOptions.uri.toString(),
              'memTokenLen': _tToken?.length,
            });
          }

          final username = response.headers.value('x-discourse-username');
          if (username != null &&
              username.isNotEmpty &&
              username != _username) {
            _username = username;
            _storage.write(key: DiscourseService._usernameKey, value: username);
          }

          debugPrint(
            '[DIO] ${response.statusCode} ${response.requestOptions.uri}',
          );
          handler.next(response);
        },
        onError: (error, handler) async {
          final skipAuthCheck =
              error.requestOptions.extra['skipAuthCheck'] == true;
          final data = error.response?.data;
          debugPrint('[DIO] Error: ${error.response?.statusCode}');

          // BAD CSRF 处理：清空 token → 刷新 → 重试原请求
          // 用 extra 标记防止无限循环，只重试一次
          if (error.response?.statusCode == 403 &&
              _isBadCsrfResponse(data) &&
              error.requestOptions.extra['_csrfRetried'] != true) {
            debugPrint(
              '[DIO] BAD CSRF detected, refreshing csrfToken and retrying',
            );
            _cookieSync.clearCsrfToken();
            await _cookieSync.updateCsrfToken();
            // 用新 token 重试原请求
            final options = error.requestOptions;
            options.extra['_csrfRetried'] = true;
            final csrf = _cookieSync.csrfToken;
            options.headers['X-CSRF-Token'] = (csrf == null || csrf.isEmpty)
                ? 'undefined'
                : csrf;
            try {
              final response = await _dio.fetch(options);
              return handler.resolve(response);
            } on DioException catch (e) {
              return handler.next(e);
            }
          }

          final loggedOut = error.response?.headers.value(
            'discourse-logged-out',
          );
          if (!skipAuthCheck &&
              loggedOut != null &&
              loggedOut.isNotEmpty &&
              !_isLoggingOut) {
            _runAuthHandlingInBackground(
              () => _onDiscourseLoggedOut(
                source: 'error_response_header',
                triggerInfo:
                    '${error.requestOptions.method} ${error.requestOptions.uri} → ${error.response?.statusCode}',
                requestOptions: error.requestOptions,
                statusCode: error.response?.statusCode,
                responseHeaders: error.response?.headers.map,
              ),
              event: 'auth_error_header_background_failed',
              source: 'error_response_header',
              triggerInfo:
                  '${error.requestOptions.method} ${error.requestOptions.uri} → ${error.response?.statusCode}',
            );
            return handler.next(error);
          }

          if (!skipAuthCheck &&
              data is Map &&
              data['error_type'] == 'not_logged_in') {
            final jarTToken = await _cookieJar.getTToken();
            await AuthLogService().logAuthInvalid(
              source: 'error_response',
              reason: data['error_type']?.toString() ?? 'not_logged_in',
              extra: {
                'method': error.requestOptions.method,
                'url': error.requestOptions.uri.toString(),
                'statusCode': error.response?.statusCode,
                'errors': data['errors'],
                'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
                'jarTokenLength': jarTToken?.length,
                'memHasToken': _tToken != null && _tToken!.isNotEmpty,
              },
            );
            final message =
                (data['errors'] as List?)?.first?.toString() ??
                S.current.auth_loginExpiredRelogin;
            _runAuthHandlingInBackground(
              () => _handleAuthInvalid(
                message,
                source: 'error_response_body',
                triggerInfo:
                    '${error.requestOptions.method} ${error.requestOptions.uri} → ${error.response?.statusCode}, error_type=${data['error_type']}',
              ),
              event: 'auth_error_body_background_failed',
              source: 'error_response_body',
              triggerInfo:
                  '${error.requestOptions.method} ${error.requestOptions.uri} → ${error.response?.statusCode}, error_type=${data['error_type']}',
            );
          }

          handler.next(error);
        },
      ),
    );
  }

  /// 收到 discourse-logged-out header 时的处理
  ///
  /// 服务端在以下情况设置此 header（BAD_TOKEN）：
  /// 1. 有 _t cookie 但 UserAuthToken.lookup 找不到对应用户（token 已失效）
  /// 2. 没有 _t cookie 但请求带了 Discourse-Logged-In header
  ///
  /// 这里不再“一次命中就立刻登出”，而是进入保守确认流程：
  /// - 先记录 strike
  /// - 复检 /session/current.json
  /// - 仅在短时间内连续确认失效时才真正清会话
  Future<void> _onDiscourseLoggedOut({
    required String source,
    required String triggerInfo,
    required RequestOptions requestOptions,
    int? statusCode,
    Map<String, List<String>>? responseHeaders,
  }) async {
    // _handleAuthInvalid 内部有 _isLoggingOut 锁，防止重复处理
    if (_isLoggingOut) return;

    debugPrint('[Auth] discourse-logged-out: $triggerInfo');

    final jarTToken = await _cookieJar.getTToken();

    // 从实际发出的请求 header 中提取 _t cookie 状态
    final sentCookieHeader = requestOptions.headers['cookie']?.toString() ?? '';
    final sentTMatch = RegExp(r'(?:^|;\s*)_t=([^;]*)').firstMatch(sentCookieHeader);
    final sentHasT = sentTMatch != null;
    final sentTLen = sentTMatch?.group(1)?.length;

    await AuthLogService().logAuthInvalid(
      source: source,
      reason: 'discourse-logged-out',
      extra: {
        'method': requestOptions.method,
        'url': requestOptions.uri.toString(),
        'statusCode': statusCode,
        'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
        'jarTokenLen': jarTToken?.length,
        'memHasToken': _tToken != null && _tToken!.isNotEmpty,
        // 实际发出的请求中 _t cookie 的状态
        'sentHasT': sentHasT,
        'sentTLen': sentTLen,
        'sentCookieLen': sentCookieHeader.length,
      },
    );

    await _handleAuthInvalid(
      S.current.auth_loginExpiredRelogin,
      source: source,
      triggerInfo: triggerInfo,
      sentHasT: sentHasT,
      sentTLen: sentTLen,
    );
  }

  /// 判断响应是否为 BAD CSRF
  /// Discourse 返回 403 + '["BAD CSRF"]' 表示 CSRF token 校验失败
  bool _isBadCsrfResponse(dynamic data) {
    if (data is String) return data == '["BAD CSRF"]';
    if (data is List) return data.length == 1 && data.first == 'BAD CSRF';
    return false;
  }

  /// 设置导航 context
  void setNavigatorContext(BuildContext context) {
    _cfChallenge.setContext(context);
  }

  Future<void> _handleAuthInvalid(
    String message, {
    String? source,
    String? triggerInfo,
    bool? sentHasT,
    int? sentTLen,
  }) async {
    if (_isLoggingOut) return;

    if (_shouldSuppressAuthInvalidDuringInconclusiveCooldown()) {
      final jarTToken = await _cookieJar.getTToken();
      final csrfToken = _cookieSync.csrfToken;
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_invalid_suppressed_after_inconclusive',
        'message': '距离上次会话复检不确定结果过近，暂时抑制重复登录异常处理',
        'reason': message,
        if (source != null) 'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'cooldownSeconds': _authInconclusiveCooldown.inSeconds,
        'memHasToken': _tToken != null && _tToken!.isNotEmpty,
        'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
        'jarTokenLen': jarTToken?.length,
        'hasCsrf': csrfToken != null && csrfToken.isNotEmpty,
        if (sentHasT != null) 'sentHasT': sentHasT,
        if (sentTLen != null) 'sentTLen': sentTLen,
      });
      return;
    }

    final strike = _registerAuthInvalidStrikeForEvent();
    final jarTToken = await _cookieJar.getTToken();
    final csrfToken = _cookieSync.csrfToken;

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': strike >= 2 ? 'warning' : 'info',
      'type': 'auth',
      'event': 'auth_invalid_detected',
      'message': strike >= 2 ? '登录异常再次出现，准备执行会话复检' : '检测到一次登录异常，先暂缓登出并执行会话复检',
      'reason': message,
      if (source != null) 'source': source,
      if (triggerInfo != null) 'trigger': triggerInfo,
      'strike': strike,
      'memHasToken': _tToken != null && _tToken!.isNotEmpty,
      'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
      'jarTokenLen': jarTToken?.length,
      'hasCsrf': csrfToken != null && csrfToken.isNotEmpty,
      if (sentHasT != null) 'sentHasT': sentHasT,
      if (sentTLen != null) 'sentTLen': sentTLen,
    });

    final probeResult = await _probeSessionStillValid(
      source: source ?? 'unknown',
      triggerInfo: triggerInfo,
    );

    if (probeResult == true) {
      _resetAuthInvalidState();
      return;
    }

    if (probeResult == null) {
      _lastAuthRecheckInconclusiveAt = DateTime.now();
      LogWriter.instance.write({
        'timestamp': _lastAuthRecheckInconclusiveAt!.toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_inconclusive_abort_logout',
        'message': '会话复检结果不确定，本次保持登录态并等待后续独立异常再次确认',
        'reason': message,
        if (source != null) 'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'strike': strike,
        'cooldownSeconds': _authInconclusiveCooldown.inSeconds,
        'memHasToken': _tToken != null && _tToken!.isNotEmpty,
        'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
        'jarTokenLen': jarTToken?.length,
        'hasCsrf': csrfToken != null && csrfToken.isNotEmpty,
        if (sentHasT != null) 'sentHasT': sentHasT,
        if (sentTLen != null) 'sentTLen': sentTLen,
      });
      return;
    }

    if (probeResult == false && strike < 2) {
      LogWriter.instance.write({
        'timestamp': DateTime.now().toIso8601String(),
        'level': 'info',
        'type': 'auth',
        'event': 'auth_recheck_failed_but_deferred_logout',
        'message': '会话复检确认失效，但首次命中仅记录告警，暂不立即登出',
        'reason': message,
        if (source != null) 'source': source,
        if (triggerInfo != null) 'trigger': triggerInfo,
        'strike': strike,
        'memHasToken': _tToken != null && _tToken!.isNotEmpty,
        'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
        'jarTokenLen': jarTToken?.length,
        'hasCsrf': csrfToken != null && csrfToken.isNotEmpty,
        if (sentHasT != null) 'sentHasT': sentHasT,
        if (sentTLen != null) 'sentTLen': sentTLen,
      });
      return;
    }

    _isLoggingOut = true;

    // ===== 第一步：立即切断所有在途请求 =====
    // 先于 logout 执行，防止用户在失效状态下继续操作产生更多 403
    AuthSession().advance();

    LogWriter.instance.write({
      'timestamp': DateTime.now().toIso8601String(),
      'level': 'warning',
      'type': 'lifecycle',
      'event': 'logout_passive',
      'message': '登录失效被动退出（已通过保守复检确认）',
      'reason': message,
      if (source != null) 'source': source,
      if (triggerInfo != null) 'trigger': triggerInfo,
      'strike': strike,
      'probeResult': probeResult,
      'memHasToken': _tToken != null && _tToken!.isNotEmpty,
      'jarHasToken': jarTToken != null && jarTToken.isNotEmpty,
      'jarTokenLen': jarTToken?.length,
      'hasCsrf': csrfToken != null && csrfToken.isNotEmpty,
      if (sentHasT != null) 'sentHasT': sentHasT,
      if (sentTLen != null) 'sentTLen': sentTLen,
    });

    await logout(callApi: false, refreshPreload: true);
    _resetAuthInvalidState();
    _isLoggingOut = false;
    _authErrorController.add(message);
  }

  /// 检查是否已登录
  Future<bool> isLoggedIn() async {
    final tToken = await _cookieJar.getTToken();
    if (tToken == null || tToken.isEmpty) return false;
    _tToken = tToken;
    _username = await _storage.read(key: DiscourseService._usernameKey);
    _resetAuthInvalidState();
    return true;
  }

  /// 仅设置 token，不触发状态广播（登录流程中先设置 token，等数据就绪后再广播）
  void setToken(String tToken) {
    _tToken = tToken;
    _credentialsLoaded = false;
  }

  /// 登录成功后通知监听者（应在预加载数据就绪后调用）
  /// 会话写入由显式边界同步统一处理。
  void onLoginSuccess(String tToken) {
    _tToken = tToken;
    _credentialsLoaded = false;
    _authStateController.add(null);
  }

  /// 保存用户名
  Future<void> saveUsername(String username) async {
    _username = username;
    await _storage.write(key: DiscourseService._usernameKey, value: username);
  }

  /// 登出
  Future<void> logout({bool callApi = true, bool refreshPreload = true}) async {
    // ===== 第一步：切断所有旧请求 =====
    AuthSession().advance();

    // ===== 第二步：主动停止后台 Service =====
    MessageBusService().stopAll();
    CfClearanceRefreshService().stop();

    // ===== 第三步：调用登出 API（可选，用新的 generation） =====
    if (callApi) {
      final usernameForLogout =
          _username ?? await _storage.read(key: DiscourseService._usernameKey);
      try {
        if (usernameForLogout != null && usernameForLogout.isNotEmpty) {
          await _dio.delete('/session/$usernameForLogout');
        }
      } catch (e) {
        debugPrint('[DiscourseService] Logout API failed: $e');
      }
    }

    // ===== 第四步：清除内存状态 =====
    _tToken = null;
    _username = null;
    _cachedUserSummary = null;
    _cachedUserSummaryUsername = null;
    _userSummaryCacheTime = null;
    await _storage.delete(key: DiscourseService._usernameKey);
    _credentialsLoaded = false;

    // ===== 第五步：清除 Cookie（保留 cf_clearance）=====
    await _cookieSync.reset();
    final cfClearanceCookie = await _cookieJar.getCfClearanceCookie();
    await _cookieJar.clearAll();
    if (cfClearanceCookie != null) {
      await _cookieJar.restoreCfClearance(cfClearanceCookie);
    }

    // ===== 第六步：刷新预加载数据（确保新状态就绪后再广播）=====
    PreloadedDataService().reset();
    if (refreshPreload) {
      await PreloadedDataService().refresh();
    }

    // ===== 第七步：广播状态变更（此时一切已就绪）=====
    currentUserNotifier.value = null;
    _authStateController.add(null);
  }
}
