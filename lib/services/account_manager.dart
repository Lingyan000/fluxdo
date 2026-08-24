import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'discourse/discourse_service.dart';
import 'network/cookie/cookie_jar_service.dart';
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

/// 多账号管理服务
///
/// 每个已登录账号在本机保留一份 Discourse 会话 Cookie 快照（_t /
/// _forum_session 等），切换账号 = 快照当前 → 摘除当前会话 → 回灌目标快照 →
/// 复用 [DiscourseService.finalizeNativeLoginSuccess] 统一收口。
///
/// 设计约束：
/// - 不持有 Dio / 不直接发请求；会话操作全部经由 [DiscourseService] 公开方法，
///   保证与登录/登出自愈逻辑走同一条路。
/// - 注册表与快照都存 [ResilientSecureStorage]（内容是会话凭证，不能落明文）。
/// - cf_clearance 是设备级通行证，不属于任何账号，切换时随
///   [DiscourseService.detachSessionLocally] 自动保留。
class AccountManager {
  AccountManager._();
  static final AccountManager _instance = AccountManager._();
  factory AccountManager() => _instance;

  static const _registryKey = 'multi_account_registry';
  static const _snapshotPrefix = 'multi_account_snapshot_';
  static const _currentUsernameKey = 'linux_do_username';

  /// 随账号切换的会话 Cookie。cf_clearance 是设备级的，不在此列。
  static const Set<String> _snapshotCookieNames = {
    '_t',
    '_forum_session',
    'linux_do_credit_session_id',
  };

  final _storage = ResilientSecureStorage();

  // ========== 注册表 ==========

  Future<List<SavedAccount>> listAccounts() async {
    final raw = await _storage.read(key: _registryKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List;
      return decoded
          .whereType<Map>()
          .map((e) => SavedAccount.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[AccountManager] 注册表解析失败,重置: $e');
      return const [];
    }
  }

  Future<void> _saveRegistry(List<SavedAccount> accounts) async {
    await _storage.write(
      key: _registryKey,
      value: jsonEncode(accounts.map((a) => a.toJson()).toList()),
    );
  }

  /// 当前登录用户名（来自 DiscourseService 的存储键）
  Future<String?> getCurrentUsername() =>
      _storage.read(key: _currentUsernameKey);

  // ====== 快照 ======

  Future<Map<String, dynamic>?> _readSnapshot(String username) async {
    final raw = await _storage.read(key: '$_snapshotPrefix$username');
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
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

  /// 从 CookieJar 抓取当前会话 Cookie 并序列化
  Future<List<Map<String, dynamic>>> _captureSessionCookies() async {
    final jar = CookieJarService();
    final captured = <Map<String, dynamic>>[];
    for (final name in _snapshotCookieNames) {
      final cookie = await jar.getCanonicalCookie(name);
      if (cookie == null) continue;
      if (cookie.value.isEmpty || cookie.value == 'del') continue;
      if (cookie.isExpired) continue;
      captured.add({
        'name': cookie.name,
        'value': cookie.value,
        'domain': cookie.domain,
        'host_only': cookie.hostOnly,
        'path': cookie.path,
        'expires_at_ms': cookie.expiresAt?.millisecondsSinceEpoch,
        'secure': cookie.secure,
        'http_only': cookie.httpOnly,
      });
    }
    return captured;
  }

  /// 把快照里的 Cookie 写回 CookieJar
  Future<void> _restoreSessionCookies(
    List<dynamic> cookies,
    String username,
  ) async {
    final jar = CookieJarService();
    for (final raw in cookies) {
      if (raw is! Map) continue;
      final name = raw['name']?.toString();
      final value = raw['value']?.toString();
      if (name == null || value == null || value.isEmpty) continue;
      final hostOnly = raw['host_only'] == true;
      final domain = raw['domain']?.toString();
      final expiresMs = raw['expires_at_ms'] as int?;
      DateTime? expires;
      if (expiresMs != null && expiresMs > 0) {
        expires = DateTime.fromMillisecondsSinceEpoch(expiresMs);
        if (expires.isBefore(DateTime.now())) {
          debugPrint('[AccountManager] $username 的 cookie $name 已过期,跳过');
          continue;
        }
      }
      await jar.setCookie(
        name,
        value,
        domain: hostOnly ? null : (domain?.isEmpty ?? true ? null : domain),
        path: raw['path']?.toString(),
        expires: expires,
        secure: raw['secure'] != false,
        httpOnly: raw['http_only'] == true,
        trusted: true,
      );
    }
  }

  // ========== 对外操作 ==========

  /// 登录成功 / 会话自愈后调用：把当前登录态登记为已保存账号并刷新其快照。
  ///
  /// 尽力而为：任何失败只打日志，绝不影响登录主流程。
  Future<void> syncCurrentAccount() async {
    try {
      final username = await getCurrentUsername();
      if (username == null || username.isEmpty) return;

      final cookies = await _captureSessionCookies();
      if (cookies.isEmpty) return; // 没有 _t 就没有可恢复的会话

      final avatarTemplate =
          PreloadedDataService().currentUserSync?['avatar_template'] as String?;

      await _writeSnapshot(username, {
        'cookies': cookies,
        'saved_at': DateTime.now().toIso8601String(),
      });

      final accounts = [...await listAccounts()];
      final index = accounts.indexWhere((a) => a.username == username);
      final entry = SavedAccount(
        username: username,
        avatarTemplate: avatarTemplate,
        savedAt: DateTime.now(),
      );
      if (index >= 0) {
        // 保留旧头像：预加载数据可能此刻拿不到 avatar_template
        accounts[index] = SavedAccount(
          username: entry.username,
          avatarTemplate:
              entry.avatarTemplate ?? accounts[index].avatarTemplate,
          savedAt: entry.savedAt,
        );
      } else {
        accounts.insert(0, entry);
      }
      await _saveRegistry(accounts);
      debugPrint(
        '[AccountManager] 已同步账号快照: $username (${cookies.length} cookies)',
      );
    } catch (e) {
      debugPrint('[AccountManager] 同步当前账号失败(忽略): $e');
    }
  }

  /// 移除某个账号的本机记录与快照（登出/主动删除时调用）
  Future<void> removeAccount(String username) async {
    final accounts = [...await listAccounts()];
    accounts.removeWhere((a) => a.username == username);
    await _saveRegistry(accounts);
    await _deleteSnapshot(username);
  }

  /// 切换到目标账号。
  ///
  /// 流程：快照当前会话 → 本地摘除当前登录态（不撤销服务端、cf_clearance
  /// 保留）→ 回灌目标快照 → [DiscourseService.finalizeNativeLoginSuccess]
  /// 收口（预加载刷新 + 登录广播）。
  Future<void> switchToAccount(String username) async {
    final snapshot = await _readSnapshot(username);
    final cookies = snapshot?['cookies'];
    if (cookies is! List ||
        cookies.isEmpty ||
        !cookies.any((c) => c is Map && c['name'] == '_t')) {
      await removeAccount(username);
      throw AccountSessionExpiredException(username);
    }

    final current = await getCurrentUsername();
    if (current != null && current.isNotEmpty && current != username) {
      await syncCurrentAccount(); // 离开前把当前账号的会话固化下来
    }

    await DiscourseService().detachSessionLocally();
    await _restoreSessionCookies(cookies, username);
    await DiscourseService().finalizeNativeLoginSuccess(username);

    // 刷新目标账号的登记时间与头像
    await syncCurrentAccount();
  }
}
