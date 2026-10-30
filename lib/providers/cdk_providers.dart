import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cdk_user_info.dart';
import '../services/cdk_oauth_service.dart';
import '../services/network/exceptions/oauth_exception.dart';
import 'core_providers.dart';

final cdkOAuthServiceProvider = Provider((ref) => CdkOAuthService());

final cdkUserInfoProvider =
    AsyncNotifierProvider<CdkUserInfoNotifier, CdkUserInfo?>(() {
      return CdkUserInfoNotifier();
    });

class CdkUserInfoNotifier extends AsyncNotifier<CdkUserInfo?> {
  static const String _cacheKey = 'cdk_user_info';
  static const String _cdkEnabledKey = 'cdk_enabled';
  static const String _cacheUserKey = 'cdk_user_info_username';

  // 防止 build() 与 refresh() 在 notifier 首次创建时并发触发同接口，
  // 复用同一个 in-flight future
  Future<CdkUserInfo?>? _inFlightFetch;
  int _requestGeneration = 0;

  @override
  Future<CdkUserInfo?> build() async {
    final generation = _requestGeneration;
    final service = ref.read(cdkOAuthServiceProvider);
    ref.onDispose(() {
      _requestGeneration++;
      _inFlightFetch = null;
      service.cancelPendingRequests();
    });
    final prefs = await SharedPreferences.getInstance();
    // 只 watch username:currentUser 对象其他字段刷新时不应触发 CDK 接口的重新请求
    final currentUsername = ref.watch(
      currentUserProvider.select((value) => value.value?.username),
    );
    final username =
        currentUsername ??
        (await ref.watch(currentUserProvider.future))?.username;
    if (username == null) {
      await _clearCache(prefs);
      return null;
    }
    final enabled = prefs.getBool(_cdkEnabledKey) ?? false;

    if (!enabled) return null;

    // 先读取缓存，用于网络失败时兜底
    CdkUserInfo? cachedInfo;
    final cached = prefs.getString(_cacheKey);
    if (cached != null) {
      try {
        final cachedUser = prefs.getString(_cacheUserKey);
        if (cachedUser != null && cachedUser != username) {
          await _clearCache(prefs);
        } else {
          cachedInfo = CdkUserInfo.fromJson(
            jsonDecode(cached) as Map<String, dynamic>,
          );
        }
      } catch (_) {
        // 缓存损坏，忽略
      }
    }

    try {
      return await _fetchUserInfo();
    } on OAuthExpiredException catch (_) {
      if (!ref.mounted || generation != _requestGeneration) return null;
      // 授权过期：清除缓存，让错误状态透传到 UI
      await _clearCache(prefs);
      rethrow;
    } catch (e) {
      if (!ref.mounted || generation != _requestGeneration) return null;
      if (OAuthErrorPolicy.isCfChallenge(e)) rethrow;
      if (cachedInfo != null) return cachedInfo;
      rethrow;
    }
  }

  Future<CdkUserInfo?> _fetchUserInfo() {
    if (_inFlightFetch != null) return _inFlightFetch!;
    late final Future<CdkUserInfo?> future;
    future = _doFetchUserInfo().whenComplete(() {
      if (identical(_inFlightFetch, future)) _inFlightFetch = null;
    });
    return _inFlightFetch = future;
  }

  Future<CdkUserInfo?> _doFetchUserInfo() async {
    final generation = _requestGeneration;
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_cdkEnabledKey) ?? false;

    if (!enabled) return null;

    final currentUser = await ref.read(currentUserProvider.future);
    if (currentUser == null ||
        !ref.mounted ||
        generation != _requestGeneration) {
      return null;
    }

    final service = ref.read(cdkOAuthServiceProvider);
    final userInfo = await service.getUserInfo(
      expectedUsername: currentUser.username,
    );
    if (!ref.mounted ||
        generation != _requestGeneration ||
        !(prefs.getBool(_cdkEnabledKey) ?? false)) {
      return null;
    }

    if (userInfo != null) {
      await prefs.setString(_cacheKey, jsonEncode(userInfo.toJson()));
      await prefs.setString(_cacheUserKey, userInfo.username);
    }

    return userInfo;
  }

  Future<void> refresh() async {
    final generation = _requestGeneration;
    final previousData = state.value;
    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<CdkUserInfo?>().copyWithPrevious(state);
    try {
      final result = await _fetchUserInfo();
      if (!ref.mounted || generation != _requestGeneration) return;
      state = AsyncValue.data(result);
    } catch (e, st) {
      if (!ref.mounted || generation != _requestGeneration) return;
      if (e is OAuthExpiredException) {
        // 登录态过期：清除缓存并立即反映到 UI
        final prefs = await SharedPreferences.getInstance();
        await _clearCache(prefs);
        if (!ref.mounted || generation != _requestGeneration) return;
        state = AsyncValue.error(e, st);
      } else if (OAuthErrorPolicy.isCfChallenge(e)) {
        // 需要验证时保留缓存，但不把旧数据伪装成本次请求成功。
        // ignore: invalid_use_of_internal_member
        state = AsyncValue<CdkUserInfo?>.error(e, st).copyWithPrevious(state);
      } else if (previousData != null) {
        // 网络错误等：保留旧数据
        state = AsyncValue.data(previousData);
      } else {
        state = AsyncValue.error(e, st);
      }
    }
  }

  /// 用户已手动通过 CF，取消旧请求并立即重新读取业务会话。
  Future<void> refreshAfterCfVerification() {
    _requestGeneration++;
    _inFlightFetch = null;
    ref.read(cdkOAuthServiceProvider).cancelPendingRequests();
    return refresh();
  }

  Future<void> clear() async {
    _requestGeneration++;
    _inFlightFetch = null;
    ref.read(cdkOAuthServiceProvider).cancelPendingRequests();
    final prefs = await SharedPreferences.getInstance();
    await _clearCache(prefs);
    state = const AsyncValue.data(null);
  }

  Future<void> disable() async {
    _requestGeneration++;
    _inFlightFetch = null;
    ref.read(cdkOAuthServiceProvider).cancelPendingRequests();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cdkEnabledKey, false);
    await _clearCache(prefs);
    state = const AsyncValue.data(null);
  }

  Future<void> _clearCache(SharedPreferences prefs) async {
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheUserKey);
  }
}
