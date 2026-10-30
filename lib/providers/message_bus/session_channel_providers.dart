/// 会话与站点级 MessageBus 频道
///
/// 对齐 Discourse 网页版的 instance-initializers/logout.js 与
/// subscribe-user-notifications.js 中的站点级订阅。这些频道的共同点是
/// 「与某个具体话题无关、影响整个客户端会话」，所以集中放在这里，
/// 不混进 topic_tracking_providers。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/user.dart';
import '../../services/message_bus_service.dart';
import '../../services/preloaded_data_service.dart';
import '../../utils/time_utils.dart';
import '../discourse_providers.dart';
import 'message_bus_service_provider.dart';
import 'topic_tracking_providers.dart';

/// 服务端强制登出频道（`/logout/:user_id`）
///
/// 触发场景：管理员在后台登出该用户的设备、账号被删除
/// （服务端 `app/models/user.rb` 与 `app/services/user_destroyer.rb` 发布）。
///
/// 注意频道名带 user_id 后缀，不是裸 `/logout`——订阅错频道会永远收不到消息。
class LogoutChannelNotifier extends Notifier<void> {
  String? _subscribedChannel;
  MessageBusCallback? _callback;

  /// 一次会话只处理一次：服务端可能连发多条，或退出流程中又有消息抵达。
  /// 对齐网页版 logout.js 的 `_showingLogout` 闩锁。
  bool _handled = false;

  @override
  void build() {
    // 确保 MessageBus 已 configure（域名配置），避免用主站域名轮询
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_subscribedChannel != null && _callback != null) {
      messageBus.unsubscribe(_subscribedChannel!, _callback);
      _subscribedChannel = null;
      _callback = null;
    }

    if (currentUser == null) {
      // 已登出：闩锁复位，下一个会话可以再次响应
      _handled = false;
      return;
    }

    final channel = '/logout/${currentUser.id}';
    debugPrint('[LogoutChannel] 订阅频道: $channel');

    void onLogout(MessageBusMessage message) {
      if (_handled) return;
      _handled = true;

      debugPrint('[LogoutChannel] 收到服务端登出推送');
      // 不 await：回调在轮询循环里同步执行，登出会走网络与存储清理，
      // 阻塞在这里会拖住整条消息投递链。
      unawaited(
        ref
            .read(discourseServiceProvider)
            .handleServerForcedLogout(source: 'message_bus'),
      );
    }

    _subscribedChannel = channel;
    _callback = onLogout;
    messageBus.subscribe(channel, onLogout);

    ref.onDispose(() {
      if (_subscribedChannel != null && _callback != null) {
        debugPrint('[LogoutChannel] 取消订阅: $_subscribedChannel');
        messageBus.unsubscribe(_subscribedChannel!, _callback);
      }
    });
  }
}

final logoutChannelProvider = NotifierProvider<LogoutChannelNotifier, void>(
  LogoutChannelNotifier.new,
);

/// 站点是否处于只读模式（`/site/read-only` 频道）
///
/// 服务端进入/退出只读（备份、迁移、手动维护）时广播一个裸布尔值。
/// 对齐网页版 instance-initializers/read-only.js 的 `site.isReadOnly`。
///
/// 这是公开频道（不带 user_id），匿名用户也能收到，所以不依赖登录态。
///
/// 目前只维护状态、不接 UI：只读模式要管的写入口（回复栏、发新话题、
/// 点赞、收藏、聊天……）分散在很多 widget 里，一次性铺开回归面太大。
/// 需要时 `ref.watch(siteReadOnlyProvider)` 即可接入。
class SiteReadOnlyNotifier extends Notifier<bool> {
  MessageBusCallback? _callback;

  static const String _channel = '/site/read-only';

  @override
  bool build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);

    if (_callback != null) {
      messageBus.unsubscribe(_channel, _callback);
      _callback = null;
    }

    void onReadOnly(MessageBusMessage message) {
      // payload 就是个裸布尔值（Discourse.readonly_channel 发的 true/false），
      // 容错地再接一下字符串形态
      final data = message.data;
      final enabled = switch (data) {
        final bool v => v,
        final String v => v.toLowerCase() == 'true',
        _ => null,
      };
      if (enabled == null) return;

      debugPrint('[SiteReadOnly] 站点只读模式: $enabled');
      state = enabled;
    }

    _callback = onReadOnly;
    messageBus.subscribe(_channel, onReadOnly);

    ref.onDispose(() {
      if (_callback != null) {
        messageBus.unsubscribe(_channel, _callback);
      }
    });

    return false;
  }
}

final siteReadOnlyProvider =
    NotifierProvider<SiteReadOnlyNotifier, bool>(SiteReadOnlyNotifier.new);

/// 当前用户的草稿数量（`/user-drafts/:user_id`）
///
/// 服务端 `UserStat` 在草稿增删时推 `{draft_count: n}`。
/// 多端编辑时，这让草稿入口的计数不至于停在旧值。
class UserDraftCountNotifier extends Notifier<int?> {
  String? _channel;
  MessageBusCallback? _callback;

  @override
  int? build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_channel != null && _callback != null) {
      messageBus.unsubscribe(_channel!, _callback);
      _channel = null;
      _callback = null;
    }

    if (currentUser == null) return null;

    final channel = '/user-drafts/${currentUser.id}';

    void onDrafts(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final count = data['draft_count'];
      if (count is int) {
        debugPrint('[UserDrafts] 草稿数更新: $count');
        state = count;
      }
    }

    _channel = channel;
    _callback = onDrafts;
    messageBus.subscribe(channel, onDrafts);

    ref.onDispose(() {
      if (_channel != null && _callback != null) {
        messageBus.unsubscribe(_channel!, _callback);
      }
    });

    return null;
  }
}

final userDraftCountProvider =
    NotifierProvider<UserDraftCountNotifier, int?>(UserDraftCountNotifier.new);

/// 勿扰模式结束时间（`/do-not-disturb/:user_id`）
///
/// payload 是 `{ends_at: <httpdate 字符串或 null>}`；null 表示已退出勿扰。
/// 处于勿扰时不应再弹本地通知——这也是订阅它的主要目的。
class DoNotDisturbNotifier extends Notifier<DateTime?> {
  String? _channel;
  MessageBusCallback? _callback;

  @override
  DateTime? build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_channel != null && _callback != null) {
      messageBus.unsubscribe(_channel!, _callback);
      _channel = null;
      _callback = null;
    }

    if (currentUser == null) return null;

    final channel = '/do-not-disturb/${currentUser.id}';

    void onDoNotDisturb(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      // ends_at 为 null 是合法值（退出勿扰），不能当成“没字段”忽略
      final endsAt = TimeUtils.parseUtcTime(data['ends_at'] as String?);
      debugPrint('[DoNotDisturb] 勿扰结束时间: $endsAt');
      state = endsAt;
    }

    _channel = channel;
    _callback = onDoNotDisturb;
    messageBus.subscribe(channel, onDoNotDisturb);

    ref.onDispose(() {
      if (_channel != null && _callback != null) {
        messageBus.unsubscribe(_channel!, _callback);
      }
    });

    return null;
  }

  /// 当前是否处于勿扰中
  bool get isActive {
    final endsAt = state;
    return endsAt != null && endsAt.isAfter(DateTime.now());
  }
}

final doNotDisturbProvider =
    NotifierProvider<DoNotDisturbNotifier, DateTime?>(DoNotDisturbNotifier.new);

/// 待审队列计数（`/reviewable_counts/:user_id`）
class ReviewableCountsState {
  final int reviewableCount;
  final int unseenReviewableCount;

  const ReviewableCountsState({
    this.reviewableCount = 0,
    this.unseenReviewableCount = 0,
  });
}

/// 对齐网页版 onReviewableCounts，供版主/管理员入口展示待审徒章。
/// 普通用户服务端不会推，订阅也不产生额外代价。
class ReviewableCountsNotifier extends Notifier<ReviewableCountsState> {
  String? _channel;
  MessageBusCallback? _callback;

  @override
  ReviewableCountsState build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_channel != null && _callback != null) {
      messageBus.unsubscribe(_channel!, _callback);
      _channel = null;
      _callback = null;
    }

    if (currentUser == null) return const ReviewableCountsState();

    final channel = '/reviewable_counts/${currentUser.id}';

    void onCounts(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final total = data['reviewable_count'];
      final unseen = data['unseen_reviewable_count'];
      state = ReviewableCountsState(
        reviewableCount: total is int ? total : state.reviewableCount,
        unseenReviewableCount:
            unseen is int ? unseen : state.unseenReviewableCount,
      );
      debugPrint(
        '[ReviewableCounts] 待审: ${state.reviewableCount}, '
        '未查看: ${state.unseenReviewableCount}',
      );
    }

    _channel = channel;
    _callback = onCounts;
    messageBus.subscribe(channel, onCounts);

    ref.onDispose(() {
      if (_channel != null && _callback != null) {
        messageBus.unsubscribe(_channel!, _callback);
      }
    });

    return const ReviewableCountsState();
  }
}

final reviewableCountsProvider =
    NotifierProvider<ReviewableCountsNotifier, ReviewableCountsState>(
  ReviewableCountsNotifier.new,
);

/// 其他用户的自定义状态（`/user-status`）
///
/// 这是一个**全站广播**频道（不带 user_id），payload 形如
/// `{<userId>: {description, emoji, ends_at} | null}`，null 表示该用户清除了状态。
///
/// 缓存成 userId → 状态的表，帖子头像旁的状态表情可据此实时刷新。
class UserStatusNotifier extends Notifier<Map<int, UserStatus?>> {
  MessageBusCallback? _callback;

  static const String _channel = '/user-status';

  /// 防止长会话下无限增长（全站广播，作者基数可能很大）
  static const int _maxTracked = 500;

  @override
  Map<int, UserStatus?> build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);
    final currentUser = ref.watch(currentUserProvider).value;

    if (_callback != null) {
      messageBus.unsubscribe(_channel, _callback);
      _callback = null;
    }

    // 服务端限 trust_level_0 以上可见，匿名订也收不到
    if (currentUser == null) return const {};

    void onUserStatus(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;

      final next = Map<int, UserStatus?>.from(state);
      for (final entry in data.entries) {
        final userId = int.tryParse(entry.key);
        if (userId == null) continue;
        final value = entry.value;
        // null 是合法语义：用户清除了状态
        next[userId] = value is Map<String, dynamic>
            ? UserStatus.fromJson(value)
            : null;
      }

      state = next.length > _maxTracked
          ? Map.fromEntries(next.entries.skip(next.length - _maxTracked))
          : next;
    }

    _callback = onUserStatus;
    messageBus.subscribe(_channel, onUserStatus);

    ref.onDispose(() {
      if (_callback != null) {
        messageBus.unsubscribe(_channel, _callback);
      }
    });

    return const {};
  }
}

final userStatusProvider =
    NotifierProvider<UserStatusNotifier, Map<int, UserStatus?>>(
  UserStatusNotifier.new,
);

/// 站点级变更频道：`/categories`、`/client_settings`、`/refresh_client`
///
/// 三个频道合并到一个 Notifier：它们都是“站点侧变了，本地缓存该失效”，
/// 拆成三个 provider 只会多写三份同构的订阅/退订样板。
///
/// 处理策略是 invalidate 而非手打缓存：分类/站点设置在本地有多份派生
/// 缓存（categoriesProvider、预加载数据、可见分类集合……），逐字段去 patch
/// 很容易漏一处就不一致；这类广播频率极低（管理员改配置才发），
/// 重拉一次的代价可以忽略。
class SiteChangesNotifier extends Notifier<void> {
  final Map<String, MessageBusCallback> _callbacks = {};

  @override
  void build() {
    ref.watch(messageBusInitProvider);
    final messageBus = ref.watch(messageBusServiceProvider);

    for (final entry in _callbacks.entries) {
      messageBus.unsubscribe(entry.key, entry.value);
    }
    _callbacks.clear();

    void onCategories(MessageBusMessage message) {
      debugPrint('[SiteChanges] 分类变更，刷新分类列表');
      ref.invalidate(categoriesProvider);
    }

    // 预加载刷新要发 GET / 拉首页 HTML，可能撞 CF 盾、限流或解析失败。
    // 这里是 fire-and-forget，不吃掉异常会变成未捕获的异步错误；
    // 而且这只是一次缓存刷新，失败了等下次启动/下拉自然会追上。
    void refreshPreloadedQuietly(String reason) {
      unawaited(
        PreloadedDataService().refresh().catchError((Object e) {
          debugPrint('[SiteChanges] 预加载刷新失败($reason)，已忽略: $e');
        }),
      );
    }

    void onClientSettings(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final name = data['name'];
      debugPrint('[SiteChanges] 站点设置变更: $name');
      // 预加载数据里存着整份 siteSettings，重拉一次比就地改一个键安全
      refreshPreloadedQuietly('client_settings');
    }

    void onRefreshClient(MessageBusMessage message) {
      // 服务端要求客户端丢掉缓存重新拿。网页版是整页刷新，
      // 移动端不能把用户正在看的页面推倒，只重拉站点级数据。
      debugPrint('[SiteChanges] 服务端要求刷新客户端缓存');
      refreshPreloadedQuietly('refresh_client');
      ref.invalidate(categoriesProvider);
    }

    final handlers = <String, MessageBusCallback>{
      '/categories': onCategories,
      '/client_settings': onClientSettings,
      '/refresh_client': onRefreshClient,
    };

    handlers.forEach((channel, handler) {
      _callbacks[channel] = handler;
      messageBus.subscribe(channel, handler);
    });

    ref.onDispose(() {
      for (final entry in _callbacks.entries) {
        messageBus.unsubscribe(entry.key, entry.value);
      }
      _callbacks.clear();
    });
  }
}

final siteChangesProvider =
    NotifierProvider<SiteChangesNotifier, void>(SiteChangesNotifier.new);
