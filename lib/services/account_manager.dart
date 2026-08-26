import 'dart:async';
import 'dart:convert';

import 'package:enhanced_cookie_jar/enhanced_cookie_jar.dart';
import 'package:flutter/foundation.dart';

import 'auth_session.dart';
import '../constants.dart';
import 'discourse/discourse_service.dart';
import 'network/cookie/cookie_full_info.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'network/cookie/raw_cookie_writer.dart';
import 'network/cookie/webview_cookie_priming.dart';
import 'preloaded_data_service.dart';
import 'storage/resilient_secure_storage.dart';

/// 已保存账号的元数据（会话快照单独存储，不进注册表）
class SavedAccount {
  final String username;
  final String? avatarTemplate;
  final DateTime savedAt;

  const SavedAccount({
    required this.username,
    this.avatarTemplate,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
    'username': username,
    if (avatarTemplate != null) 'avatar_template': avatarTemplate,
    'saved_at': savedAt.toIso8601String(),
  };

  factory SavedAccount.fromJson(Map<String, dynamic> json) => SavedAccount(
    username: json['username'] as String,
    avatarTemplate: json['avatar_template'] as String?,
    savedAt:
        DateTime.tryParse(json['saved_at'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// 切换失败：目标账号的本机快照缺失或已过期，需要重新登录
class AccountSessionExpiredException implements Exception {
  final String username;
  AccountSessionExpiredException(this.username);

  @override
  String toString() => 'AccountSessionExpiredException($username)';
}

/// 多账号管理服务。
///
/// 账号会话、内置浏览器 cookie、LDC/CDK 配置都必须以账号为边界。这里的
/// [_operationTail] 还负责把切换、登录前清场、后台快照串起来，避免旧账号
/// 的异步收尾在新账号上继续写状态。
class AccountManager {
  AccountManager._();
  static final AccountManager _instance = AccountManager._();
  factory AccountManager() => _instance;

  static const _registryKey = 'multi_account_registry';
  static const _snapshotPrefix = 'multi_account_snapshot_';
  static const _currentUsernameKey = 'linux_do_username';
  static const _pendingNewLoginKey = 'multi_account_pending_new_login';
  static const _guestModeKey = 'multi_account_guest_mode';

  /// 没有登录账号时使用的默认 profile。它不展示在账号列表中，只用于
  /// 保证「添加账号」开始前拥有一个干净、可恢复的 cookie/config 边界。
  static const String guestAccountId = 'guest';

  /// LDC/CDK、打赏凭证等账号级 SharedPreferences key 的统一命名规则。
  static String accountScopedKey(String key, String accountId) {
    return '$key::${Uri.encodeComponent(accountId)}';
  }

  /// 内置浏览器里需要随账号保存的 origin。不要把 Cloudflare 设备 cookie
  /// 放进账号快照；它们由 [DiscourseService.detachSessionLocally] 保留。
  static const List<String> _browserCookieOrigins = [
    'https://linux.do/',
    'https://credit.linux.do/',
    'https://cdk.linux.do/',
    'https://connect.linux.do/',
  ];

  static const Set<String> _deviceCookieNames = {'cf_clearance', '__cf_bm'};

  final _storage = ResilientSecureStorage();
  Future<void> _operationTail = Future<void>.value();

  /// 让所有会改动当前认证上下文的操作严格串行。
  Future<T> _exclusive<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  // ========== 注册表 ==========

  Future<List<SavedAccount>> listAccounts() async {
    final raw = await _storage.read(key: _registryKey);
    return _decodeRegistry(raw);
  }

  List<SavedAccount> _decodeRegistry(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .whereType<Map>()
          .map((e) => SavedAccount.fromJson(Map<String, dynamic>.from(e)))
          // guest 是隐藏 profile，历史版本即使写进 registry 也不能展示。
          .where((account) => account.username != guestAccountId)
          .toList(growable: false);
    } catch (e) {
      debugPrint('[AccountManager] 注册表解析失败,重置: $e');
      return const [];
    }
  }

  Future<void> _saveRegistry(List<SavedAccount> accounts) async {
    await _storage.write(
      key: _registryKey,
      value: jsonEncode(
        accounts
            .where((account) => account.username != guestAccountId)
            .map((a) => a.toJson())
            .toList(),
      ),
    );
  }

  /// 当前登录用户名（来自 DiscourseService 的存储键）。
  Future<String?> getCurrentUsername() =>
      _storage.read(key: _currentUsernameKey);

  /// 添加账号流程是否处在 guest profile。
  Future<bool> isGuestSession() async {
    final value = await _storage.read(key: _guestModeKey);
    return value == '1';
  }

  /// 登录成功后清掉 guest 标记。幂等，冷启动 API key 回调也可以调用。
  Future<void> markLoginSucceeded() async {
    await _exclusive(() async {
      await Future.wait([
        _storage.delete(key: _guestModeKey),
        _storage.delete(key: _pendingNewLoginKey),
      ]);
    });
  }

  // ====== 快照 ======

  Future<Map<String, dynamic>?> _readSnapshot(String username) async {
    final raw = await _storage.read(key: '$_snapshotPrefix$username');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSnapshot(String username, Map<String, dynamic> snapshot) {
    return _storage.write(
      key: '$_snapshotPrefix$username',
      value: jsonEncode(snapshot),
    );
  }

  Future<void> _deleteSnapshot(String username) {
    return _storage.delete(key: '$_snapshotPrefix$username');
  }

  bool _isDeviceCookie(String name) {
    final lower = name.toLowerCase();
    return _deviceCookieNames.contains(lower) ||
        lower.startsWith('cf_') ||
        lower.startsWith('__cf');
  }

  /// 抓取当前 CookieJar 中所有应用域 cookie，而不是只维护几个已知名字。
  /// 这样 credit/LDC 新增的 session cookie 也会自动隔离。
  Future<List<Map<String, dynamic>>> _captureSessionCookies() async {
    final jar = CookieJarService();
    final all = await jar.loadAllCanonicalCookies();
    final captured = <Map<String, dynamic>>[];
    for (final cookie in all) {
      if (_isDeviceCookie(cookie.name) ||
          cookie.value.isEmpty ||
          cookie.value == 'del' ||
          cookie.isExpired ||
          !CookieJarService.matchesAppHost(cookie.normalizedDomain)) {
        continue;
      }
      captured.add(cookie.toJson());
    }
    return captured;
  }

  /// 抓取内置 WebView 的原始 cookie store。WebView cookie 不能依赖 jar
  /// 回读：某些 LDC/credit cookie 只存在于子域或 HttpOnly store 中。
  Future<List<Map<String, dynamic>>> _captureBrowserCookies() async {
    final writer = RawCookieWriter.instance;
    if (!writer.isSupported) return const [];

    final captured = <Map<String, dynamic>>[];
    final identities = <String>{};
    for (final origin in _browserCookieOrigins) {
      List<CookieFullInfo> infos;
      try {
        infos = await writer.getAllCookieInfos(origin);
      } catch (e) {
        debugPrint('[AccountManager] 读取 $origin WebView cookie 失败: $e');
        continue;
      }
      for (final info in infos) {
        if (_isDeviceCookie(info.name) ||
            info.name.isEmpty ||
            info.value.isEmpty ||
            _isExpired(info.expiresMillis)) {
          continue;
        }
        final originHost = Uri.parse(origin).host.toLowerCase();
        final cookieDomain = info.domain?.trim().toLowerCase();
        final identityDomain = cookieDomain == null || cookieDomain.isEmpty
            ? originHost
            : cookieDomain.startsWith('.')
            ? cookieDomain.substring(1)
            : cookieDomain;
        final identity = [
          info.name,
          identityDomain,
          info.path ?? '/',
          info.isPartitioned == true ? '1' : '0',
        ].join('|');
        if (!identities.add(identity)) continue;
        captured.add({
          'url': origin,
          'name': info.name,
          'value': info.value,
          'domain': info.domain,
          'path': info.path,
          'secure': info.isSecure,
          'http_only': info.isHttpOnly,
          'expires_at_ms': info.expiresMillis,
          'same_site': info.sameSite,
          'partitioned': info.isPartitioned,
        });
      }
    }
    return captured;
  }

  bool _isExpired(int? expiresMillis) {
    return expiresMillis != null &&
        expiresMillis > 0 &&
        expiresMillis <= DateTime.now().millisecondsSinceEpoch;
  }

  /// 把快照里的 Cookie 写回 CookieJar。兼容旧版本的简化字段格式。
  Future<void> _restoreSessionCookies(
    List<dynamic> cookies,
    String username,
  ) async {
    final restored = <CanonicalCookie>[];
    for (final raw in cookies) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      try {
        CanonicalCookie cookie;
        if (map.containsKey('expiresAt') || map.containsKey('hostOnly')) {
          cookie = CanonicalCookie.fromJson(map);
        } else {
          final name = map['name']?.toString();
          final value = map['value']?.toString();
          if (name == null || value == null || value.isEmpty) continue;
          final expiresMs = map['expires_at_ms'];
          final expires = expiresMs is int && expiresMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(expiresMs).toUtc()
              : null;
          cookie = CanonicalCookie(
            name: name,
            value: value,
            domain: map['domain']?.toString(),
            path: map['path']?.toString() ?? '/',
            expiresAt: expires,
            secure: map['secure'] != false,
            httpOnly: map['http_only'] == true,
            hostOnly: map['host_only'] == true,
            originUrl: AppConstants.baseUrl,
            source: CookieSource.manualRestore,
          );
        }
        if (_isDeviceCookie(cookie.name) ||
            cookie.value.isEmpty ||
            cookie.isExpired ||
            !CookieJarService.matchesAppHost(cookie.normalizedDomain)) {
          continue;
        }
        if (cookie.originUrl == null || cookie.originUrl!.isEmpty) {
          cookie = cookie.copyWith(originUrl: AppConstants.baseUrl);
        }
        restored.add(cookie);
      } catch (e) {
        debugPrint('[AccountManager] $username 的 cookie 解析失败: $e');
      }
    }
    await CookieJarService().restoreCanonicalCookies(restored, trusted: true);
  }

  String? _rawCookieHeader(Map<String, dynamic> cookie) {
    final name = cookie['name']?.toString();
    final value = cookie['value']?.toString();
    if (name == null || name.isEmpty || value == null || value.isEmpty) {
      return null;
    }
    final buffer = StringBuffer('$name=$value');
    final domain = cookie['domain']?.toString();
    if (domain != null && domain.isNotEmpty) buffer.write('; Domain=$domain');
    final path = cookie['path']?.toString();
    buffer.write('; Path=${path == null || path.isEmpty ? '/' : path}');
    final expires = cookie['expires_at_ms'];
    if (expires is int && expires > 0) {
      buffer.write('; Expires=${_formatHttpDate(expires)}');
    }
    if (cookie['secure'] == true) buffer.write('; Secure');
    if (cookie['http_only'] == true) buffer.write('; HttpOnly');
    final sameSite = cookie['same_site']?.toString();
    if (sameSite != null && sameSite.isNotEmpty) {
      buffer.write('; SameSite=$sameSite');
    }
    if (cookie['partitioned'] == true) buffer.write('; Partitioned');
    return buffer.toString();
  }

  String _formatHttpDate(int expiresMillis) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final date = DateTime.fromMillisecondsSinceEpoch(
      expiresMillis,
      isUtc: true,
    );
    return '${weekdays[date.weekday - 1]}, '
        '${date.day.toString().padLeft(2, '0')} '
        '${months[date.month - 1]} ${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}:'
        '${date.second.toString().padLeft(2, '0')} GMT';
  }

  Future<void> _restoreBrowserCookies(
    dynamic rawCookies,
    String username,
  ) async {
    if (rawCookies is! List) return;
    final writer = RawCookieWriter.instance;
    if (!writer.isSupported) return;
    for (final raw in rawCookies) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final url = map['url']?.toString();
      if (url == null || !_isAllowedBrowserOrigin(url)) continue;
      final header = _rawCookieHeader(map);
      if (header == null) continue;
      final ok = await writer.setRawCookie(url, header);
      if (!ok) {
        debugPrint('[AccountManager] $username 的 WebView cookie 写入失败');
      }
    }
  }

  bool _isAllowedBrowserOrigin(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    return CookieJarService.matchesAppHost(uri.host);
  }

  bool _snapshotHasSessionCookie(dynamic cookies) {
    if (cookies is! List) return false;
    return cookies.any((raw) {
      if (raw is! Map) return false;
      final name = raw['name']?.toString();
      final value = raw['value']?.toString();
      return name == '_t' && value != null && value.isNotEmpty;
    });
  }

  String? _currentAvatarFor(String username) {
    final preloaded = PreloadedDataService().currentUserSync;
    if (preloaded?['username']?.toString() != username) return null;
    final avatar = preloaded?['avatar_template'];
    return avatar is String && avatar.isNotEmpty ? avatar : null;
  }

  Future<void> _syncCurrentAccountLocked({
    bool captureBrowserCookies = false,
  }) async {
    final generation = AuthSession().generation;
    final username = await getCurrentUsername();
    if (username == null || username.isEmpty || username == guestAccountId) {
      return;
    }

    final cookies = await _captureSessionCookies();
    if (!AuthSession().isValid(generation) ||
        await getCurrentUsername() != username ||
        !_snapshotHasSessionCookie(cookies)) {
      return;
    }

    final oldSnapshot = await _readSnapshot(username);
    final browserCookies = captureBrowserCookies
        ? await _captureBrowserCookies()
        : oldSnapshot?['webview_cookies'];
    if (!AuthSession().isValid(generation) ||
        await getCurrentUsername() != username) {
      return;
    }

    final avatarTemplate =
        _currentAvatarFor(username) ??
        oldSnapshot?['avatar_template'] as String?;
    await _writeSnapshot(username, {
      'version': 2,
      'profile': username,
      'cookies': cookies,
      if (browserCookies is List) 'webview_cookies': browserCookies,
      'avatar_template': ?avatarTemplate,
      'saved_at': DateTime.now().toIso8601String(),
    });

    final accounts = [
      ..._decodeRegistry(await _storage.read(key: _registryKey)),
    ];
    final index = accounts.indexWhere((a) => a.username == username);
    final entry = SavedAccount(
      username: username,
      avatarTemplate: avatarTemplate,
      savedAt: DateTime.now(),
    );
    if (index >= 0) {
      accounts[index] = entry;
    } else {
      accounts.insert(0, entry);
    }
    await _saveRegistry(accounts);
    debugPrint(
      '[AccountManager] 已同步账号快照: $username '
      '(${cookies.length} jar cookies, '
      '${browserCookies is List ? browserCookies.length : 0} WebView cookies)',
    );
  }

  // ========== 对外操作 ==========

  /// 登录成功 / 会话自愈后调用：登记当前账号并刷新快照。
  Future<void> syncCurrentAccount({bool captureBrowserCookies = false}) async {
    try {
      await _exclusive(
        () => _syncCurrentAccountLocked(
          captureBrowserCookies: captureBrowserCookies,
        ),
      );
    } catch (e) {
      debugPrint('[AccountManager] 同步当前账号失败(忽略): $e');
    }
  }

  /// 开始「添加账号」：先把当前账号快照保存下来，再切到隐藏 guest profile。
  /// pending username 写入安全存储，支持系统浏览器 API key 回调期间进程被重建。
  Future<void> prepareForNewLogin() async {
    await _exclusive(() async {
      final current = await getCurrentUsername();
      if (current != null && current.isNotEmpty && current != guestAccountId) {
        await _storage.write(key: _pendingNewLoginKey, value: current);
        try {
          await _syncCurrentAccountLocked(captureBrowserCookies: true);
        } catch (e) {
          // 快照失败不能阻塞添加账号；guest 仍必须建立，登录完成后新账号
          // 可正常落盘，取消时则按已有快照尽力恢复。
          debugPrint('[AccountManager] 添加账号前同步快照失败(继续): $e');
        }
      } else {
        await _storage.delete(key: _pendingNewLoginKey);
      }
      await _storage.write(key: _guestModeKey, value: '1');
      await _writeSnapshot(guestAccountId, {
        'version': 2,
        'profile': guestAccountId,
        'cookies': const [],
        'webview_cookies': const [],
        'saved_at': DateTime.now().toIso8601String(),
      });

      // 这一步必须发生在打开 LoginPage / 系统浏览器之前，不能让旧 _t
      // 被 API key callback 误判成「当前账号补授权」。
      await DiscourseService().detachSessionLocally();
      WebViewCookiePriming.instance.invalidate();
    });
  }

  /// 添加账号页面退出时收口。取消/失败则恢复进入添加流程前的账号。
  Future<void> completeNewLogin({required bool success}) async {
    await _exclusive(() async {
      final previous = await _storage.read(key: _pendingNewLoginKey);
      await _storage.delete(key: _pendingNewLoginKey);
      await _storage.delete(key: _guestModeKey);
      if (success) return;

      if (previous != null && previous.isNotEmpty) {
        try {
          await _switchToAccountLocked(previous);
          return;
        } on AccountSessionExpiredException {
          await _removeAccountLocked(previous);
        }
      }
      // 登录失败可能已经留下部分 cookie，恢复 guest 的干净边界。
      await DiscourseService().detachSessionLocally();
    });
  }

  // ========== 后台快照刷新 ==========

  Timer? _autoSnapshotTimer;
  bool _autoSnapshotInFlight = false;

  /// 启动周期性后台快照刷新。
  void ensureAutoSnapshot({Duration interval = const Duration(minutes: 15)}) {
    if (_autoSnapshotTimer != null) return;
    _autoSnapshotTimer = Timer.periodic(interval, (_) {
      if (_autoSnapshotInFlight) return;
      _autoSnapshotInFlight = true;
      unawaited(
        syncCurrentAccount().whenComplete(() => _autoSnapshotInFlight = false),
      );
    });
  }

  /// 移除某个账号的本机记录与快照（登出/主动删除时调用）。
  Future<void> removeAccount(String username) async {
    if (username == guestAccountId || username.isEmpty) return;
    await _exclusive(() => _removeAccountLocked(username));
  }

  Future<void> _removeAccountLocked(String username) async {
    final accounts = [
      ..._decodeRegistry(await _storage.read(key: _registryKey)),
    ];
    accounts.removeWhere((a) => a.username == username);
    await _saveRegistry(accounts);
    await _deleteSnapshot(username);
  }

  Future<void> _switchToAccountLocked(String username) async {
    final snapshot = await _readSnapshot(username);
    final cookies = snapshot?['cookies'];
    if (cookies is! List ||
        cookies.isEmpty ||
        !_snapshotHasSessionCookie(cookies)) {
      await _removeAccountLocked(username);
      throw AccountSessionExpiredException(username);
    }

    final current = await getCurrentUsername();
    if (current != null && current.isNotEmpty && current != username) {
      await _syncCurrentAccountLocked(captureBrowserCookies: true);
    }

    await DiscourseService().detachSessionLocally();
    await _restoreSessionCookies(cookies, username);
    await _restoreBrowserCookies(snapshot?['webview_cookies'], username);
    final restoredToken = await CookieJarService().getTToken();
    if (restoredToken == null || restoredToken.isEmpty) {
      await _removeAccountLocked(username);
      throw AccountSessionExpiredException(username);
    }
    WebViewCookiePriming.instance.invalidate();
    await DiscourseService().finalizeNativeLoginSuccess(username);

    // 头像/快照只允许来自新账号。_currentAvatarFor 会拒绝仍残留的旧 preload。
    await _syncCurrentAccountLocked(captureBrowserCookies: true);
  }

  /// 切换到目标账号。
  Future<void> switchToAccount(String username) async {
    await _exclusive(() => _switchToAccountLocked(username));
  }
}
