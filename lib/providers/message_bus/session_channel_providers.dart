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

import '../../services/message_bus_service.dart';
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
