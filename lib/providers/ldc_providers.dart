import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ldc_user_info.dart';
import '../services/account_manager.dart';
import '../services/auth_session.dart';
import '../services/ldc_oauth_service.dart';
import '../services/network/exceptions/oauth_exception.dart';
import 'core_providers.dart';

final ldcUserInfoProvider =
    AsyncNotifierProvider<LdcUserInfoNotifier, LdcUserInfo?>(() {
      return LdcUserInfoNotifier();
    });

class LdcUserInfoNotifier extends AsyncNotifier<LdcUserInfo?> {
  static const String _cacheKey = 'ldc_user_info';
  static const String _ldcEnabledKey = 'ldc_enabled';
  static const String _cacheUserKey = 'ldc_user_info_username';

  // 防止 build() 与 refresh() 在同一账号内并发触发同接口；future 同时绑定
  // username + AuthSession generation，切换账号后绝不复用旧请求。
  Future<LdcUserInfo?>? _inFlightFetch;
  String? _inFlightUsername;
  int? _inFlightGeneration;

  String _key(String base, String username) =>
      AccountManager.accountScopedKey(base, username);

  Future<String?> _currentUsername() {
    return ref.read(discourseServiceProvider).getCurrentUsername();
  }

  Future<void> _migrateLegacy(SharedPreferences prefs, String username) async {
    final enabledKey = _key(_ldcEnabledKey, username);
    final cacheKey = _key(_cacheKey, username);
    final cacheUserKey = _key(_cacheUserKey, username);
    if (prefs.containsKey(enabledKey) ||
        prefs.containsKey(cacheKey) ||
        prefs.containsKey(cacheUserKey)) {
      return;
    }

    // 历史版本只有一份全局值；首次看到当前账号时迁移一次，之后只读
    // scoped key，避免旧全局值继续污染其它账号。
    final legacyUser = prefs.getString(_cacheUserKey);
    final legacyCacheUserMatches = legacyUser == null || legacyUser == username;
    if (legacyCacheUserMatches) {
      final legacyEnabled = prefs.getBool(_ldcEnabledKey);
      final legacyCache = prefs.getString(_cacheKey);
      if (legacyEnabled != null) await prefs.setBool(enabledKey, legacyEnabled);
      if (legacyCache != null) await prefs.setString(cacheKey, legacyCache);
      if (legacyUser != null) await prefs.setString(cacheUserKey, username);
    }
    await Future.wait([
      prefs.remove(_ldcEnabledKey),
      prefs.remove(_cacheKey),
      prefs.remove(_cacheUserKey),
    ]);
  }

  @override
  Future<LdcUserInfo?> build() async {
    final generation = AuthSession().generation;
    final prefs = await SharedPreferences.getInstance();
    // watch username 使切换后重新读取，但 identity 以安全存储为准，避免
    // currentUser provider 的旧值在切换窗口内泄漏 LDC 内容。
    ref.watch(currentUserProvider.select((value) => value.value?.username));
    final username = await _currentUsername();
    if (!AuthSession().isValid(generation) ||
        username == null ||
        username.isEmpty) {
      return null;
    }
    await _migrateLegacy(prefs, username);
    if (!AuthSession().isValid(generation) ||
        await _currentUsername() != username) {
      return null;
    }

    final enabled = prefs.getBool(_key(_ldcEnabledKey, username)) ?? false;
    if (!enabled) return null;

    LdcUserInfo? cachedInfo;
    final cached = prefs.getString(_key(_cacheKey, username));
    if (cached != null) {
      try {
        final cachedUser = prefs.getString(_key(_cacheUserKey, username));
        if (cachedUser == username) {
          final decoded = LdcUserInfo.fromJson(
            jsonDecode(cached) as Map<String, dynamic>,
          );
          if (decoded.username == username) cachedInfo = decoded;
        }
      } catch (_) {
        // 缓存损坏，忽略
      }
    }

    try {
      return await _fetchUserInfo(username, generation);
    } on OAuthExpiredException catch (_) {
      await _clearCache(prefs, username);
      rethrow;
    } catch (e) {
      if (cachedInfo != null && AuthSession().isValid(generation)) {
        return cachedInfo;
      }
      rethrow;
    }
  }

  Future<LdcUserInfo?> _fetchUserInfo(String username, int generation) {
    if (_inFlightFetch != null &&
        _inFlightUsername == username &&
        _inFlightGeneration == generation) {
      return _inFlightFetch!;
    }
    late final Future<LdcUserInfo?> request;
    request = _doFetchUserInfo(username, generation).whenComplete(() {
      if (identical(_inFlightFetch, request)) {
        _inFlightFetch = null;
        _inFlightUsername = null;
        _inFlightGeneration = null;
      }
    });
    _inFlightFetch = request;
    _inFlightUsername = username;
    _inFlightGeneration = generation;
    return request;
  }

  Future<LdcUserInfo?> _doFetchUserInfo(String username, int generation) async {
    final prefs = await SharedPreferences.getInstance();
    if (!AuthSession().isValid(generation) ||
        await _currentUsername() != username ||
        !(prefs.getBool(_key(_ldcEnabledKey, username)) ?? false)) {
      return null;
    }

    final currentUser = await ref.read(currentUserProvider.future);
    if (!AuthSession().isValid(generation) ||
        currentUser?.username != username ||
        await _currentUsername() != username) {
      return null;
    }

    final userInfo = await LdcOAuthService().getUserInfo();
    if (!AuthSession().isValid(generation) ||
        await _currentUsername() != username) {
      return null;
    }
    if (userInfo != null && userInfo.username == username) {
      await prefs.setString(
        _key(_cacheKey, username),
        jsonEncode(userInfo.toJson()),
      );
      await prefs.setString(_key(_cacheUserKey, username), username);
      return userInfo;
    }
    // 服务端回了另一个账号的数据时，宁可丢弃也不让它落缓存。
    return null;
  }

  Future<void> refresh() async {
    final generation = AuthSession().generation;
    final username = await _currentUsername();
    if (!AuthSession().isValid(generation) || username == null) return;
    final previousData = state.value;
    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<LdcUserInfo?>().copyWithPrevious(state);
    try {
      final result = await _fetchUserInfo(username, generation);
      if (!AuthSession().isValid(generation) ||
          await _currentUsername() != username) {
        return;
      }
      state = AsyncValue.data(result);
    } catch (e, st) {
      if (!AuthSession().isValid(generation) ||
          await _currentUsername() != username) {
        return;
      }
      if (e is OAuthExpiredException) {
        final prefs = await SharedPreferences.getInstance();
        await _clearCache(prefs, username);
        state = AsyncValue.error(e, st);
      } else if (previousData != null) {
        state = AsyncValue.data(previousData);
      } else {
        state = AsyncValue.error(e, st);
      }
    }
  }

  Future<void> clear() async {
    final generation = AuthSession().generation;
    final username = await _currentUsername();
    if (!AuthSession().isValid(generation) ||
        username == null ||
        username.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await _clearCache(prefs, username);
    if (!AuthSession().isValid(generation) ||
        await _currentUsername() != username) {
      return;
    }
    state = const AsyncValue.data(null);
  }

  Future<void> disable() async {
    final generation = AuthSession().generation;
    final username = await _currentUsername();
    if (!AuthSession().isValid(generation) ||
        username == null ||
        username.isEmpty) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key(_ldcEnabledKey, username), false);
    await _clearCache(prefs, username);
    if (!AuthSession().isValid(generation) ||
        await _currentUsername() != username) {
      return;
    }
    state = const AsyncValue.data(null);
  }

  Future<void> _clearCache(SharedPreferences prefs, String username) async {
    await Future.wait([
      prefs.remove(_key(_cacheKey, username)),
      prefs.remove(_key(_cacheUserKey, username)),
    ]);
  }
}
