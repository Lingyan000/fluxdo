import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/discourse/discourse_service.dart';
import '../../services/message_bus_service.dart';
import '../discourse_providers.dart';
import '../message_bus/message_bus_service_provider.dart';
import '../message_bus/models.dart';
import '../message_bus/topic_tracking_providers.dart';

/// 聊天"正在输入"状态(chat 复用核心 PresenceChannel 系统,
/// 通道 /chat-reply/:channelId,与帖子回复 presence 同一套端点)
class ChatTypingNotifier extends Notifier<List<TypingUser>> {
  ChatTypingNotifier(this.channelId);

  final int channelId;

  MessageBusService? _bus;
  MessageBusCallback? _callback;
  Timer? _debounce;
  List<TypingUser>? _pending;
  bool _disposed = false;

  /// 卡死兜底:leave 广播依赖 MessageBus,断连窗口漏收会永远显示
  /// "正在输入"。名单非空时周期性拉 /presence/get 全量校准,
  /// 空名单时不轮询(零成本)。
  Timer? _recalibrate;

  String get _presenceChannel => '/chat-reply/$channelId';

  @override
  List<TypingUser> build() {
    _disposed = false;
    ref.watch(messageBusInitProvider);
    final bus = ref.watch(messageBusServiceProvider);
    _bus = bus;

    void onMessage(MessageBusMessage message) {
      final data = message.data;
      if (data is! Map<String, dynamic>) return;
      final currentUserId = ref.read(currentUserProvider).value?.id;

      // 防抖累积(同 TopicChannelNotifier presence:中间态互相覆盖丢更新)
      final users = List<TypingUser>.from(_pending ?? state);
      var changed = false;

      for (final u in data['entering_users'] as List<dynamic>? ?? []) {
        final map = u as Map<String, dynamic>;
        final user = TypingUser(
          id: map['id'] as int? ?? 0,
          username: map['username'] as String? ?? '',
          avatarTemplate: map['avatar_template'] as String? ?? '',
        );
        if (user.id > 0 &&
            user.id != currentUserId &&
            !users.any((e) => e.id == user.id)) {
          users.add(user);
          changed = true;
        }
      }
      for (final id in data['leaving_user_ids'] as List<dynamic>? ?? []) {
        if (id is int) {
          final before = users.length;
          users.removeWhere((u) => u.id == id);
          if (users.length != before) changed = true;
        }
      }

      if (changed) {
        _pending = users;
        _debounce ??= Timer(const Duration(milliseconds: 200), () {
          _debounce = null;
          final pending = _pending;
          if (_disposed || pending == null) return;
          _pending = null;
          state = pending;
          _syncRecalibration();
        });
      }
    }

    _callback = onMessage;
    // presence 通道用 -1 起点只收增量;初始在场名单异步拉取校准
    bus.subscribe(_presenceChannel, onMessage);
    _loadInitial(bus, onMessage);

    ref.onDispose(() {
      _disposed = true;
      _debounce?.cancel();
      _debounce = null;
      _recalibrate?.cancel();
      _recalibrate = null;
      _pending = null;
      if (_bus != null && _callback != null) {
        _bus!.unsubscribe(_presenceChannel, _callback);
      }
    });

    return const [];
  }

  Future<void> _loadInitial(
    MessageBusService bus,
    MessageBusCallback callback,
  ) async {
    try {
      final service = ref.read(discourseServiceProvider);
      final response = await service.dio.get(
        '/presence/get',
        queryParameters: {'channels[]': _presenceChannel},
      );
      final data = response.data as Map<String, dynamic>;
      final channelData = data[_presenceChannel] as Map<String, dynamic>?;
      if (channelData == null || _disposed) return;
      final currentUserId = ref.read(currentUserProvider).value?.id;
      final users = (channelData['users'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(
            (m) => TypingUser(
              id: m['id'] as int? ?? 0,
              username: m['username'] as String? ?? '',
              avatarTemplate: m['avatar_template'] as String? ?? '',
            ),
          )
          .where((u) => u.id > 0 && u.id != currentUserId)
          .toList();
      state = users;
      _syncRecalibration();
      // 用服务端 message_id 重订阅,避免回放旧的进出事件
      final messageId = channelData['message_id'] as int? ?? -1;
      if (messageId >= 0) {
        bus.unsubscribe(_presenceChannel, callback);
        bus.subscribeWithMessageId(_presenceChannel, callback, messageId);
      }
    } catch (e) {
      debugPrint('[ChatTyping#$channelId] 初始 presence 拉取失败: $e');
    }
  }

  /// 名单非空 → 起 15s 周期全量校准;清空 → 停表
  void _syncRecalibration() {
    if (_disposed) return;
    if (state.isEmpty) {
      _recalibrate?.cancel();
      _recalibrate = null;
      return;
    }
    _recalibrate ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => _recalibrateNow(),
    );
  }

  Future<void> _recalibrateNow() async {
    if (_disposed || state.isEmpty) {
      _syncRecalibration();
      return;
    }
    try {
      final service = ref.read(discourseServiceProvider);
      final response = await service.dio.get(
        '/presence/get',
        queryParameters: {'channels[]': _presenceChannel},
      );
      if (_disposed) return;
      final data = response.data as Map<String, dynamic>;
      final channelData = data[_presenceChannel] as Map<String, dynamic>?;
      final currentUserId = ref.read(currentUserProvider).value?.id;
      final users = (channelData?['users'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(
            (m) => TypingUser(
              id: m['id'] as int? ?? 0,
              username: m['username'] as String? ?? '',
              avatarTemplate: m['avatar_template'] as String? ?? '',
            ),
          )
          .where((u) => u.id > 0 && u.id != currentUserId)
          .toList();
      // 全量真值覆盖(丢 leave 事件的幽灵在这里被清掉)
      _pending = null;
      _debounce?.cancel();
      _debounce = null;
      state = users;
      _syncRecalibration();
    } catch (_) {
      // 校准失败不动现状,下个周期再试
    }
  }
}

final chatTypingProvider = NotifierProvider.family
    .autoDispose<ChatTypingNotifier, List<TypingUser>, int>(
      ChatTypingNotifier.new,
    );

/// 上报"我正在输入":输入时 enter、停止/发送/离开时 leave。
/// 官方 composer 语义:presence 有 ~10s 服务端超时,持续输入需周期续报。
///
/// [isEnabled] 每次上报前评估:用户开了 hide_presence(隐藏在线状态)
/// 时必须完全静默——对齐网页版 chat.js 的 user_option.hide_presence
/// 前置判断,不发任何 /presence/update 请求。
class ChatTypingReporter {
  ChatTypingReporter(
    this._readService,
    this.channelId, {
    required bool Function() isEnabled,
  }) : _isEnabled = isEnabled;

  /// 惰性取 service(避免持有 WidgetRef/Ref 类型分歧)
  final DiscourseService Function() _readService;
  final int channelId;
  final bool Function() _isEnabled;

  Timer? _keepAlive;
  bool _present = false;

  String get _channel => '/chat-reply/$channelId';

  /// 每次击键调用(内部节流:未在场时 enter,在场时靠 keepAlive 续)
  void onTyping() {
    if (!_isEnabled()) return;
    if (!_present) {
      _present = true;
      _update(present: true);
    }
    // 5s 无击键自动 leave(官方 composer 停止输入即退出在场)
    _keepAlive?.cancel();
    _keepAlive = Timer(const Duration(seconds: 5), stop);
  }

  void stop() {
    _keepAlive?.cancel();
    _keepAlive = null;
    if (_present) {
      _present = false;
      _update(present: false);
    }
  }

  void dispose() => stop();

  void _update({required bool present}) {
    unawaited(
      _readService().updatePresence(
        presentChannels: present ? [_channel] : null,
        leaveChannels: present ? null : [_channel],
      ),
    );
  }
}
