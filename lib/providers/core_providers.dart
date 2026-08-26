// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/account_manager.dart';
import '../services/auth_session.dart';
import '../services/discourse/discourse_service.dart';
import '../services/preloaded_data_service.dart';

/// Discourse 服务 Provider
final discourseServiceProvider = Provider((ref) => DiscourseService());

/// 认证错误 Provider（监听登录失效事件）
final authErrorProvider = StreamProvider<String>((ref) {
  final service = ref.watch(discourseServiceProvider);
  return service.authErrorStream;
});

/// 认证状态变化 Provider（登录/退出）
final authStateProvider = StreamProvider<void>((ref) {
  final service = ref.watch(discourseServiceProvider);
  return service.authStateStream;
});

/// 当前用户 Provider
/// 优先使用预加载数据同步返回，避免启动时短暂显示未登录状态
class CurrentUserNotifier extends AsyncNotifier<User?> {
  static const String _cacheKey = 'current_user_cache';
  static const String _cacheUserKey = 'current_user_cache_username';
  static const Duration _refreshCooldown = Duration(minutes: 2);
  DateTime? _lastRefreshTime;

  @override
  FutureOr<User?> build() {
    final service = ref.read(discourseServiceProvider);
    final generation = AuthSession().generation;
    final preloaded = PreloadedDataService().currentUserSync;
    if (preloaded != null) {
      // preload 是全局内存缓存，可能仍是切换前的账号。必须先和当前
      // username 对齐，不能仅凭「有 preload」就同步到头像/内容 Provider。
      return _usePreloadedIfCurrent(service, preloaded, generation);
    }
    return _loadUserWithCache(service, generation: generation);
  }

  Future<User?> _usePreloadedIfCurrent(
    DiscourseService service,
    Map<String, dynamic> preloaded,
    int generation,
  ) async {
    if (await AccountManager().isGuestSession()) return null;
    final username = await service.getCurrentUsername();
    final preloadedUsername = preloaded['username']?.toString();
    if (!AuthSession().isValid(generation) ||
        username == null ||
        username.isEmpty ||
        preloadedUsername != username) {
      return _loadUserWithCache(service, generation: generation);
    }

    final preloadedUser = User.fromJson(preloaded);
    if (!AuthSession().isValid(generation) ||
        await service.getCurrentUsername() != username) {
      return null;
    }
    service.currentUserNotifier.value = preloadedUser;
    _refreshUser(
      service,
      preloadedUser,
      generation: generation,
      username: username,
    );
    return preloadedUser;
  }

  Future<User?> _loadUserWithCache(
    DiscourseService service, {
    required int generation,
  }) async {
    if (await AccountManager().isGuestSession()) return null;
    // 先把上次会话的缓存亮出来(毫秒级,登出时缓存会被清,存在即上次已
    // 登录):本 provider 可能在预加载完成前就被 watch(如根部印记层第一
    // 帧即 watch,早于 PreheatGate 放行),此时 build 的同步快路径拿不到
    // preloaded;而下面的 isLoggedIn 含服务端校验、getCurrentUser 是全量
    // 接口,若等它们串行完成才给首值,头像/发帖入口要白等数秒。
    // 渐进 emit:缓存 → preloaded → 接口终态。
    final prefs = await SharedPreferences.getInstance();
    // 缓存必须校验用户名:多账号切换后这里可能还留着上一个账号的用户,
    // 直接 emit 会让"手动刷新仍显示上一个账号"。缓存用户与当前登录
    // 用户名不一致时视为脏缓存,清掉并走接口取新账号数据。
    final currentUsername = await service.getCurrentUsername();
    final cachedUsername = prefs.getString(_cacheUserKey);
    final cached = (cachedUsername != null && cachedUsername == currentUsername)
        ? prefs.getString(_cacheKey)
        : null;
    if (cachedUsername != null && cachedUsername != currentUsername) {
      await prefs.remove(_cacheKey);
      await prefs.remove(_cacheUserKey);
    }
    if (!AuthSession().isValid(generation)) return null;
    User? cachedUser;
    if (cached != null) {
      try {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        final decodedUser = User.fromCacheJson(json);
        if (decodedUser.username == currentUsername) {
          cachedUser = decodedUser;
          state = AsyncValue.data(decodedUser);
        }
      } catch (_) {
        // 缓存损坏，忽略
      }
    }

    final hasToken = await service.isLoggedIn(requestGeneration: generation);
    if (!AuthSession().isValid(generation)) return null;
    if (!hasToken) {
      await prefs.remove(_cacheKey);
      await prefs.remove(_cacheUserKey);
      return null;
    }

    try {
      final preloadedUser = await service.getPreloadedCurrentUser();
      if (!AuthSession().isValid(generation) ||
          await service.getCurrentUsername() != currentUsername) {
        return null;
      }
      if (preloadedUser != null) {
        state = AsyncValue.data(preloadedUser);
      }
      final user = await service.getCurrentUser();
      if (!AuthSession().isValid(generation) ||
          await service.getCurrentUsername() != currentUsername) {
        return null;
      }
      final resolved = user == null
          ? preloadedUser
          : (preloadedUser == null ? user : _mergeUser(user, preloadedUser));
      if (resolved != null) {
        if (currentUsername == null || currentUsername.isEmpty) return null;
        await _saveCache(
          prefs,
          resolved,
          generation: generation,
          username: currentUsername,
        );
        return resolved;
      }
      // 网络返回 null 但本地有缓存时，保守处理：保留缓存返回，
      // 避免短暂鉴权抖动把 UI 误判成已登出。
      // 只有在已确认没有 token 的分支（第 48-53 行）才清理缓存。
      if (cachedUser != null) return cachedUser;
      return null;
    } catch (e) {
      if (!AuthSession().isValid(generation)) return null;
      // 网络失败，返回缓存
      if (cachedUser != null) return cachedUser;
      rethrow;
    }
  }

  Future<User?> _loadUser(
    DiscourseService service, {
    required int generation,
  }) async {
    if (await AccountManager().isGuestSession()) return null;
    final preloadedUser = await service.getPreloadedCurrentUser();
    if (!AuthSession().isValid(generation)) return null;
    final username = await service.getCurrentUsername();
    if (username == null || username.isEmpty) return null;
    if (preloadedUser != null && preloadedUser.username != username) {
      return null;
    }
    final user = await service.getCurrentUser();
    if (!AuthSession().isValid(generation) ||
        await service.getCurrentUsername() != username) {
      return null;
    }
    if (user == null) return preloadedUser;
    if (preloadedUser == null) return user;
    return _mergeUser(user, preloadedUser);
  }

  /// 静默刷新，带冷却时间（默认 2 分钟内不重复请求）
  /// 不提前 emit 中间状态，只在拿到结果后更新一次，避免多余 rebuild
  Future<void> refreshSilently({bool force = false}) async {
    if (!force &&
        _lastRefreshTime != null &&
        DateTime.now().difference(_lastRefreshTime!) < _refreshCooldown) {
      return;
    }
    final service = ref.read(discourseServiceProvider);
    final generation = AuthSession().generation;
    final previous = state.value;
    try {
      final user = await _loadUser(service, generation: generation);
      if (!AuthSession().isValid(generation)) return;
      _lastRefreshTime = DateTime.now();
      if (user != null) {
        final prefs = await SharedPreferences.getInstance();
        await _saveCache(
          prefs,
          user,
          generation: generation,
          username: user.username,
        );
      }
      if (!AuthSession().isValid(generation)) return;
      state = AsyncValue.data(user ?? previous);
    } catch (e, st) {
      // 刷新失败，保留旧数据并标记错误状态（用于离线提示）
      if (!AuthSession().isValid(generation)) return;
      if (previous != null) {
        state = AsyncValue<User?>.error(
          e,
          st,
        ).copyWithPrevious(AsyncValue.data(previous));
      }
    }
  }

  void _refreshUser(
    DiscourseService service,
    User preloadedUser, {
    required int generation,
    required String username,
  }) {
    Future(() async {
      try {
        final user = await service.getCurrentUser();
        if (user == null ||
            !AuthSession().isValid(generation) ||
            user.username != username ||
            await service.getCurrentUsername() != username) {
          return;
        }
        final merged = _mergeUser(user, preloadedUser);
        final prefs = await SharedPreferences.getInstance();
        await _saveCache(
          prefs,
          merged,
          generation: generation,
          username: username,
        );
        if (!AuthSession().isValid(generation) ||
            await service.getCurrentUsername() != username) {
          return;
        }
        state = AsyncValue.data(merged);
      } catch (_) {
        // 后台刷新失败时静默忽略，refreshSilently 会负责设置错误状态
      }
    });
  }

  User _mergeUser(User user, User preloadedUser) {
    return user.copyWith(
      unreadNotifications: preloadedUser.unreadNotifications,
      unreadHighPriorityNotifications:
          preloadedUser.unreadHighPriorityNotifications,
      allUnreadNotificationsCount: preloadedUser.allUnreadNotificationsCount,
      seenNotificationId: preloadedUser.seenNotificationId,
      notificationChannelPosition: preloadedUser.notificationChannelPosition,
      // can_assign 只在 CurrentUserSerializer(预加载/会话数据)里有,
      // /u/username.json 这条公开资料接口不带,live fetch 那份永远是
      // 默认值 false——用预加载兜底,否则第二次刷新就把权限位冲没了。
      canAssign: user.canAssign || preloadedUser.canAssign,
    );
  }

  Future<void> _saveCache(
    SharedPreferences prefs,
    User user, {
    required int generation,
    required String username,
  }) async {
    if (!AuthSession().isValid(generation) || user.username != username) return;
    await prefs.setString(_cacheKey, jsonEncode(user.toCacheJson()));
    if (!AuthSession().isValid(generation)) return;
    await prefs.setString(_cacheUserKey, username);
  }

  Future<void> clearCache() async {
    final generation = AuthSession().generation;
    final prefs = await SharedPreferences.getInstance();
    if (!AuthSession().isValid(generation)) return;
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheUserKey);
    if (!AuthSession().isValid(generation)) return;
    // 清缓存时同步清掉内存态。否则账号切换期间，旧头像/资料会继续被
    // widget 读取，直到新账号的异步 build 完成，形成“头像已切换、内容仍旧”的重叠态。
    state = const AsyncValue.data(null);
  }
}

final currentUserProvider = AsyncNotifierProvider<CurrentUserNotifier, User?>(
  CurrentUserNotifier.new,
);

/// 系统用户头像模板 Provider
/// 用于通知列表中没有 acting_user 时的默认头像
final systemUserAvatarTemplateProvider = FutureProvider<String?>((ref) async {
  return PreloadedDataService().getSystemUserAvatarTemplate();
});

/// 用户统计数据 Provider
class UserSummaryNotifier extends AsyncNotifier<UserSummary?> {
  static const String _cacheKey = 'user_summary_cache';
  static const String _cacheUserKey = 'user_summary_cache_username';

  @override
  Future<UserSummary?> build() async {
    final generation = AuthSession().generation;
    final service = ref.watch(discourseServiceProvider);
    if (await AccountManager().isGuestSession()) return null;
    final currentUsername = ref.watch(
      currentUserProvider.select((value) => value.value?.username),
    );
    final username =
        currentUsername ??
        (await ref.watch(currentUserProvider.future))?.username;
    final storedUsername = await service.getCurrentUsername();
    if (!AuthSession().isValid(generation) ||
        username == null ||
        storedUsername != username) {
      return null;
    }

    // 先尝试从 SP 读取缓存
    final prefs = await SharedPreferences.getInstance();
    if (!AuthSession().isValid(generation) ||
        await service.getCurrentUsername() != username) {
      return null;
    }
    final cachedUser = prefs.getString(_cacheUserKey);
    // 切换账号时清除旧缓存
    if (cachedUser != null && cachedUser != username) {
      await _clearCache(prefs);
    }

    final cached = cachedUser == username ? prefs.getString(_cacheKey) : null;
    UserSummary? cachedSummary;
    if (cached != null) {
      try {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        cachedSummary = UserSummary.fromCacheJson(json);
      } catch (_) {
        // 缓存损坏，忽略
      }
    }

    try {
      final summary = await service.getUserSummary(username);
      if (!AuthSession().isValid(generation) ||
          await service.getCurrentUsername() != username) {
        return null;
      }
      await _saveCache(prefs, summary, username, generation: generation);
      return summary;
    } catch (e) {
      if (!AuthSession().isValid(generation) ||
          await service.getCurrentUsername() != username) {
        return null;
      }
      if (cachedSummary != null) return cachedSummary;
      rethrow;
    }
  }

  Future<void> refresh() async {
    final generation = AuthSession().generation;
    final previous = state.value;
    try {
      final service = ref.read(discourseServiceProvider);
      if (await AccountManager().isGuestSession()) return;
      final user = ref.read(currentUserProvider).value;
      if (user == null) return;
      if (await service.getCurrentUsername() != user.username) return;

      final summary = await service.getUserSummary(
        user.username,
        forceRefresh: true,
      );
      if (!AuthSession().isValid(generation) ||
          await service.getCurrentUsername() != user.username) {
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await _saveCache(prefs, summary, user.username, generation: generation);
      if (!AuthSession().isValid(generation)) return;
      state = AsyncValue.data(summary);
    } catch (e, st) {
      // 刷新失败，保留旧数据并标记错误状态
      if (!AuthSession().isValid(generation)) return;
      if (previous != null) {
        state = AsyncValue<UserSummary?>.error(
          e,
          st,
        ).copyWithPrevious(AsyncValue.data(previous));
      }
    }
  }

  Future<void> _saveCache(
    SharedPreferences prefs,
    UserSummary summary,
    String username, {
    required int generation,
  }) async {
    if (!AuthSession().isValid(generation)) return;
    await prefs.setString(_cacheKey, jsonEncode(summary.toCacheJson()));
    if (!AuthSession().isValid(generation)) return;
    await prefs.setString(_cacheUserKey, username);
  }

  Future<void> clearCache() async {
    final generation = AuthSession().generation;
    final prefs = await SharedPreferences.getInstance();
    if (!AuthSession().isValid(generation)) return;
    await _clearCache(prefs);
    if (!AuthSession().isValid(generation)) return;
    state = const AsyncValue.data(null);
  }

  Future<void> _clearCache(SharedPreferences prefs) async {
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheUserKey);
  }
}

final userSummaryProvider =
    AsyncNotifierProvider<UserSummaryNotifier, UserSummary?>(
      UserSummaryNotifier.new,
    );
