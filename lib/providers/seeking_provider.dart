import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/seeking.dart';
import '../models/user_action.dart';
import '../services/discourse/discourse_service.dart';
import '../services/network/exceptions/api_exception.dart';
import 'discourse_providers.dart';
import 'theme_provider.dart';

/// 追觅（监控用户动态）状态。
///
/// 移植自 BestLINUXDO 扩展的 seeking.js：
/// - 两段式省请求：先看 /u/{u}.json 的 last_seen_at 有没有变，没变收工；
/// - 流动化刷新：每步只刷「最久未刷」的一名用户；
/// - 请求间隔由用户选择高/中/低三档；
/// - 429/403 → 挂起到下一分钟整点后谨慎重启。
class SeekingState {
  const SeekingState({
    this.enabled = false,
    this.users = const [],
    this.data = const {},
    this.profiles = const {},
    this.unread = const {},
    this.holdUntil,
    this.refreshing,
    this.paceSeconds = SeekingNotifier.defaultPaceSeconds,
  });

  final bool enabled;

  /// 每个请求之间的间隔秒数（10/30/60 三档，用户可选）
  final int paceSeconds;

  /// 监控用户名列表（顺序即展示顺序）
  final List<String> users;

  /// username → 最新动态（每人最多 [SeekingNotifier.logLimitPerUser] 条）
  final Map<String, List<SeekingActivity>> data;

  /// username → 轻量资料
  final Map<String, SeekingUserProfile> profiles;

  /// username → 未读条数
  final Map<String, int> unread;

  /// 限流挂起截止时间（null = 流动中）
  final DateTime? holdUntil;

  /// 当前正在刷新的用户名（UI 转圈用）
  final String? refreshing;

  int get totalUnread => unread.values.fold(0, (sum, n) => sum + n);

  /// 全部用户动态按时间倒序合并
  List<SeekingActivity> get timeline {
    final all = <SeekingActivity>[for (final list in data.values) ...list];
    all.sort((a, b) {
      final ta = a.createdAt?.millisecondsSinceEpoch ?? 0;
      final tb = b.createdAt?.millisecondsSinceEpoch ?? 0;
      return tb.compareTo(ta);
    });
    return all;
  }

  SeekingState copyWith({
    bool? enabled,
    List<String>? users,
    Map<String, List<SeekingActivity>>? data,
    Map<String, SeekingUserProfile>? profiles,
    Map<String, int>? unread,
    Object? holdUntil = _unset,
    Object? refreshing = _unset,
    int? paceSeconds,
  }) {
    return SeekingState(
      enabled: enabled ?? this.enabled,
      users: users ?? this.users,
      data: data ?? this.data,
      profiles: profiles ?? this.profiles,
      unread: unread ?? this.unread,
      holdUntil: identical(holdUntil, _unset)
          ? this.holdUntil
          : holdUntil as DateTime?,
      refreshing: identical(refreshing, _unset)
          ? this.refreshing
          : refreshing as String?,
      paceSeconds: paceSeconds ?? this.paceSeconds,
    );
  }

  static const Object _unset = Object();
}

class SeekingNotifier extends StateNotifier<SeekingState>
    with WidgetsBindingObserver {
  SeekingNotifier(this._prefs, this._service) : super(const SeekingState()) {
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  /// 应用是否在前台。真正退到后台/最小化（hidden/paused）时暂停轮询：
  /// 省电、省限流额度，也避免多窗口/多实例场景下不可见实例白白抢请求。
  bool _appActive = true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive 不算离开：桌面端窗口失焦（仍可见）就是 inactive——追觅的
    // 意义恰恰是「一边干别的一边盯着」，失焦即停等于桌面上基本不工作。
    // 移动端 inactive 只是权限弹窗/任务切换器等瞬态，放行无妨。
    _appActive =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  static const int maxUsers = 50;
  static const int logLimitPerUser = 10;

  /// 请求频率三档：高 10s / 中 30s / 低 60s（每档一个请求的最小间隔）
  static const List<int> paceOptions = [10, 30, 60];
  static const int defaultPaceSeconds = 30;

  static const String _configKey = 'seeking_config';
  static const String _enabledKey = 'seeking_enabled';
  static const String _paceKey = 'seeking_pace_seconds';

  final SharedPreferences _prefs;
  final DiscourseService _service;

  /// username → 最新一条动态的 uid（新增检测基准），持久化
  final Map<String, String> _lastIds = {};

  /// username → 上次刷新时刻（挑「最久未刷」的依据）
  final Map<String, DateTime> _lastFetchedAt = {};

  /// username → 上次完整拉取动态的时刻。last_seen_at 不能代表点赞、回应、
  /// Boost 等所有活动，因此即使在线时间未变化也必须周期性完整校验。
  final Map<String, DateTime> _lastFullFetchedAt = {};
  static const Duration _fullRefreshInterval = Duration(minutes: 5);

  /// 实际生效的完整校验周期。
  ///
  /// 固定 5 分钟在名单一大（一轮遍历耗时 N × pace 超过 5 分钟，约 >10 人）
  /// 时会让 fullRefreshDue 恒真——两段式省请求彻底失效，每人每轮都发满
  /// 4 个请求。取「3 轮遍历」与 5 分钟的较大者：大名单下平均每 3 次访问
  /// 才做 1 次全量（预算 ~2 请求/次），小名单仍保持 5 分钟的校验频率。
  Duration get _effectiveFullRefreshInterval {
    final cycle = Duration(seconds: state.users.length * state.paceSeconds);
    final scaled = cycle * 3;
    return scaled > _fullRefreshInterval ? scaled : _fullRefreshInterval;
  }

  Timer? _timer;
  bool _busy = false;
  DateTime _lastFlowAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastRequestAt;
  Future<void> _requestTail = Future<void>.value();

  Duration get _pace => Duration(seconds: state.paceSeconds);

  /// 所有追觅请求共享同一串行队列和节拍：距上一个请求发出不足 [_pace]
  /// 时先等待。把「1 + 3 并发」的突发拉平成慢速串行流，避免周期性
  /// 密集 XHR 触发 CF 行为检测反复弹盾。
  Future<T> _pacedRequest<T>(Future<T> Function() request) {
    final completer = Completer<T>();
    final previous = _requestTail;
    _requestTail = () async {
      await previous;
      final last = _lastRequestAt;
      if (last != null) {
        final remaining = _pace - DateTime.now().difference(last);
        if (remaining > Duration.zero) {
          await Future<void>.delayed(remaining);
        }
      }
      _lastRequestAt = DateTime.now();
      try {
        completer.complete(await request());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  // ── 持久化 ──────────────────────────────────

  void _load() {
    final enabled = _prefs.getBool(_enabledKey) ?? false;
    var users = <String>[];
    final raw = _prefs.getString(_configKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final cfg = jsonDecode(raw) as Map<String, dynamic>;
        users = (cfg['users'] as List? ?? const [])
            .map((u) => u.toString())
            .toList();
        (cfg['lastIds'] as Map<String, dynamic>? ?? const {}).forEach(
          (k, v) => _lastIds[k] = v.toString(),
        );
      } catch (e) {
        debugPrint('[Seeking] 配置解析失败: $e');
      }
    }
    final unread = <String, int>{};
    final rawUnread = _prefs.getString('$_configKey.unread');
    if (rawUnread != null && rawUnread.isNotEmpty) {
      try {
        (jsonDecode(rawUnread) as Map<String, dynamic>).forEach((k, v) {
          final n = v is int ? v : int.tryParse(v.toString()) ?? 0;
          if (n > 0) unread[k] = n;
        });
      } catch (_) {}
    }
    final paceSeconds = _prefs.getInt(_paceKey) ?? defaultPaceSeconds;
    state = state.copyWith(
      enabled: enabled,
      users: users,
      unread: unread,
      paceSeconds: paceOptions.contains(paceSeconds)
          ? paceSeconds
          : defaultPaceSeconds,
    );
    _syncTimer();
  }

  Future<void> _save() async {
    await _prefs.setString(
      _configKey,
      jsonEncode({'users': state.users, 'lastIds': _lastIds}),
    );
    await _prefs.setString('$_configKey.unread', jsonEncode(state.unread));
  }

  // ── 名单管理 ─────────────────────────────────

  Future<String?> addUser(String username) async {
    final name = username.trim();
    if (name.isEmpty) return null;
    if (state.users.any((u) => u.toLowerCase() == name.toLowerCase())) {
      return 'exists';
    }
    if (state.users.length >= maxUsers) return 'full';

    // 添加前立即验证用户，避免把不存在的用户名静默放进轮询队列。
    // 同时复用这次请求得到的头像和在线时间，不额外浪费首轮请求。
    //
    // 不排 _pacedRequest：那是给后台轮询流的节拍，用户主动点「添加」
    // 排在轮询后面，低速档（60s）下可能干等几分钟且毫无反馈。单次
    // 用户交互请求与正常浏览页面无异，不构成 CF 行为检测风险。
    try {
      final user = await _service.getUser(name);
      final profiles = Map<String, SeekingUserProfile>.of(state.profiles)
        ..[name] = SeekingUserProfile(
          lastSeenAt: user.lastSeenAt,
          avatarTemplate: user.avatarTemplate,
        );
      state = state.copyWith(users: [name, ...state.users], profiles: profiles);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return 'notFound';
      return 'failed';
    } catch (_) {
      return 'failed';
    }
    // 新用户插队首：无 lastFetchedAt 记录自动优先被刷
    await _save();
    _syncTimer();
    return null;
  }

  Future<void> removeUser(String username) async {
    final users = state.users.where((u) => u != username).toList();
    final data = Map<String, List<SeekingActivity>>.of(state.data)
      ..remove(username);
    final profiles = Map<String, SeekingUserProfile>.of(state.profiles)
      ..remove(username);
    final unread = Map<String, int>.of(state.unread)..remove(username);
    _lastIds.remove(username);
    _lastFetchedAt.remove(username);
    _lastFullFetchedAt.remove(username);
    state = state.copyWith(
      users: users,
      data: data,
      profiles: profiles,
      unread: unread,
    );
    await _save();
    _syncTimer();
  }

  /// 同步关注列表到监控名单（增量导入，不移除既有用户）。
  /// 返回新增数量，-1 表示失败。
  Future<int> syncFollowing() async {
    try {
      final username = await _service.getUsername();
      if (username == null) return -1;
      // 同 addUser：用户主动触发的同步不排后台轮询节拍队列
      final following = await _service.getFollowing(username);
      var added = 0;
      final users = List<String>.of(state.users);
      for (final user in following) {
        final name = user.username;
        if (users.any((u) => u.toLowerCase() == name.toLowerCase())) continue;
        if (users.length >= maxUsers) break;
        users.insert(0, name);
        added++;
      }
      if (added > 0) {
        state = state.copyWith(users: users);
        await _save();
        _syncTimer();
      }
      return added;
    } catch (e) {
      debugPrint('[Seeking] 同步关注失败: $e');
      return -1;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (state.enabled == enabled) return;
    state = state.copyWith(enabled: enabled);
    await _prefs.setBool(_enabledKey, enabled);
    _syncTimer();
  }

  Future<void> setPaceSeconds(int seconds) async {
    if (!paceOptions.contains(seconds) || state.paceSeconds == seconds) return;
    state = state.copyWith(paceSeconds: seconds);
    await _prefs.setInt(_paceKey, seconds);
    // 切换档位后从当前时刻重新计算间隔，避免连续发出两个请求。
    _lastFlowAt = DateTime.now();
  }

  Future<void> markAllRead() async {
    if (state.unread.isEmpty) return;
    state = state.copyWith(unread: const {});
    await _save();
  }

  // ── 流动化刷新 ────────────────────────────────

  void _syncTimer() {
    final shouldRun = state.enabled && state.users.isNotEmpty;
    if (shouldRun && _timer == null) {
      // 1s 轮询定时器只做门控判断，真正出手由 _lastFlowAt + 自适应节拍决定
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else if (!shouldRun) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _tick() async {
    if (_busy || !_appActive || !state.enabled || state.users.isEmpty) return;
    final now = DateTime.now();
    final holdUntil = state.holdUntil;
    if (holdUntil != null) {
      if (now.isBefore(holdUntil)) return;
      state = state.copyWith(holdUntil: null);
    }
    if (now.difference(_lastFlowAt) < _pace) return;

    // 挑「最久未刷」的用户；从未刷过的（新导入）优先。
    // 时间戳在未来 = 退避中（如 404），直接跳过。
    String? target;
    DateTime? oldest;
    for (final user in state.users) {
      final at = _lastFetchedAt[user];
      if (at == null) {
        target = user;
        break;
      }
      if (at.isAfter(now)) continue;
      if (oldest == null || at.isBefore(oldest)) {
        oldest = at;
        target = user;
      }
    }
    if (target == null) return;

    _busy = true;
    _lastFlowAt = now;
    state = state.copyWith(refreshing: target);
    try {
      await _fetchUser(target);
    } on DioException catch (e) {
      final status = e.response?.statusCode ?? 0;
      // CF 拦截器对静默请求直接 reject 一个**没有 response** 的
      // DioException（error 里才是 CfChallengeException），只看
      // statusCode 会把撞盾当普通失败、按原节拍继续轰——持续给 CF
      // 行为检测喂数据，盾更难消，还连累前台请求。
      if (status == 429 || status == 403 || e.error is CfChallengeException) {
        _holdToNextMinute();
        _lastFetchedAt[target] = DateTime.now();
      } else if (status == 404) {
        // 用户不存在/被匿名化：长退避，避免每一圈都浪费一个请求。
        // 时间戳写到未来即可让「最久未刷」选择器长期跳过它。
        debugPrint('[Seeking] 用户 $target 不存在(404)，退避 30 分钟');
        _lastFetchedAt[target] = DateTime.now().add(
          const Duration(minutes: 30),
        );
      } else {
        debugPrint('[Seeking] 刷新 $target 失败: $e');
        _lastFetchedAt[target] = DateTime.now();
      }
    } catch (e) {
      debugPrint('[Seeking] 刷新 $target 异常: $e');
      _lastFetchedAt[target] = DateTime.now();
    } finally {
      _busy = false;
      if (mounted) state = state.copyWith(refreshing: null);
    }
  }

  /// 限流/过盾 → 挂起到下一分钟整点（加少量抖动）。
  void _holdToNextMinute() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final hold = (now ~/ 60000 + 1) * 60000 + math.Random().nextInt(1500);
    state = state.copyWith(
      holdUntil: DateTime.fromMillisecondsSinceEpoch(hold),
    );
    debugPrint('[Seeking] 触发限流，挂起到下一分钟');
  }

  Future<void> _fetchUser(String username) async {
    // 第一段：只花 1 个请求看在线状态有没有变
    final user = await _pacedRequest(
      () => _service.getUser(username, isSilent: true),
    );
    // 请求在途期间用户可能已被移出名单（或 notifier 已销毁）：此时任何
    // state / _lastIds 写回都会让已删用户的数据复活并被持久化。
    if (!mounted || !state.users.contains(username)) return;
    final old = state.profiles[username];
    final profile = SeekingUserProfile(
      lastSeenAt: user.lastSeenAt,
      avatarTemplate: user.avatarTemplate ?? old?.avatarTemplate,
    );
    final changed = old == null || old.lastSeenAt != user.lastSeenAt;
    // 资料没变就别重建 map——state 一换整个页面跟着重建,timeline 还要
    // 全量重排,轮询节拍下这是常态路径,省下来很可观。
    if (old != profile) {
      final profiles = Map<String, SeekingUserProfile>.of(state.profiles)
        ..[username] = profile;
      state = state.copyWith(profiles: profiles);
    }
    _lastFetchedAt[username] = DateTime.now();

    final hasData = (state.data[username] ?? const []).isNotEmpty;
    final lastFullFetchedAt = _lastFullFetchedAt[username];
    final fullRefreshDue =
        lastFullFetchedAt == null ||
        DateTime.now().difference(lastFullFetchedAt) >=
            _effectiveFullRefreshInterval;
    if (!changed && hasData && !fullRefreshDue) return;

    // 第二段：按节拍串行拉三路动态（个别失败不影响整体）
    Future<Object?> optional(Future<Object?> Function() request) async {
      try {
        return await _pacedRequest(request);
      } catch (e) {
        _rethrowIfRateLimited(e);
        return null;
      }
    }

    final actions = await optional(
      () => _service.getUserActions(username, filter: '1,4,5', isSilent: true),
    );
    final reactions = await optional(
      () => _service.getUserReactions(username, isSilent: true),
    );
    final boosts = await optional(
      () => _service.getUserBoostsGiven(username, isSilent: true),
    );

    final merged = <SeekingActivity>[];
    if (actions is UserActionResponse) {
      merged.addAll(
        actions.actions
            .take(logLimitPerUser)
            .map((a) => SeekingActivity.fromUserAction(username, a)),
      );
    }
    if (reactions is UserReactionsResponse) {
      merged.addAll(
        reactions.reactions
            .take(logLimitPerUser)
            .map((r) => SeekingActivity.fromReaction(username, r)),
      );
    }
    if (boosts is UserBoostsResponse) {
      merged.addAll(
        boosts.boosts
            .take(logLimitPerUser)
            .map((b) => SeekingActivity.fromBoost(username, b)),
      );
    }
    // 三路请求在途期间同样可能被移出名单，写回前再验一次
    if (!mounted || !state.users.contains(username)) return;
    _lastFullFetchedAt[username] = DateTime.now();
    if (merged.isEmpty) return;

    merged.sort((a, b) {
      final ta = a.createdAt?.millisecondsSinceEpoch ?? 0;
      final tb = b.createdAt?.millisecondsSinceEpoch ?? 0;
      return tb.compareTo(ta);
    });
    final latest = merged.take(logLimitPerUser).toList(growable: false);

    // 新增检测：从头 diff 到上次记录的最新 uid 为止
    final latestId = latest.first.uid;
    final lastSavedId = _lastIds[username];
    var freshCount = 0;
    if (lastSavedId == null) {
      _lastIds[username] = latestId;
    } else if (latestId != lastSavedId) {
      for (final activity in latest) {
        if (activity.uid == lastSavedId) break;
        freshCount++;
      }
      _lastIds[username] = latestId;
    }

    final data = Map<String, List<SeekingActivity>>.of(state.data)
      ..[username] = latest;
    var unread = state.unread;
    if (freshCount > 0) {
      unread = Map<String, int>.of(state.unread)
        ..[username] = (state.unread[username] ?? 0) + freshCount;
    }
    state = state.copyWith(data: data, unread: unread);
    await _save();
  }

  /// 三路并发里出现限流/CF 盾必须冒泡给 _tick 的挂起逻辑，其余错误各自吞掉
  void _rethrowIfRateLimited(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode ?? 0;
      if (status == 429 || status == 403 || e.error is CfChallengeException) {
        throw e;
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }
}

final seekingProvider = StateNotifierProvider<SeekingNotifier, SeekingState>((
  ref,
) {
  final prefs = ref.watch(sharedPreferencesProvider);
  final service = ref.watch(discourseServiceProvider);
  return SeekingNotifier(prefs, service);
});
