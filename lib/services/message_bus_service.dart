import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../utils/client_id_generator.dart';
import 'network/discourse_dio.dart';

/// MessageBus 消息
class MessageBusMessage {
  final String channel;
  final int messageId;
  final dynamic data;

  MessageBusMessage({
    required this.channel,
    required this.messageId,
    required this.data,
  });

  factory MessageBusMessage.fromJson(Map<String, dynamic> json) {
    return MessageBusMessage(
      channel: json['channel'] as String,
      messageId: json['message_id'] as int,
      data: json['data'],
    );
  }
}

/// MessageBus 频道订阅
typedef MessageBusCallback = void Function(MessageBusMessage message);

class _ChannelSubscription {
  final String channel;
  int lastMessageId;
  final List<MessageBusCallback> callbacks;

  _ChannelSubscription({
    required this.channel,
    this.lastMessageId = -1,
    List<MessageBusCallback>? callbacks,
  }) : callbacks = callbacks ?? [];
}

/// Discourse MessageBus 客户端
/// 使用 HTTP 长轮询实现实时消息推送
class MessageBusService {
  static final MessageBusService _instance = MessageBusService._internal();
  factory MessageBusService() => _instance;

  final Dio _dio;

  final Map<String, _ChannelSubscription> _subscriptions = {};
  final String _clientId;
  
  bool _isPolling = false;
  bool _shouldStop = false;
  bool _shouldRestart = false; // 标记是否需要重启轮询
  CancelToken? _currentCancelToken; // 当前请求的 CancelToken
  Timer? _reconnectTimer;
  int _failureCount = 0;
  static const int _maxBackoffSeconds = 30;

  // 消息流（用于全局监听）
  // ignore: close_sinks — closed in dispose()
  final _messageController = StreamController<MessageBusMessage>.broadcast();
  Stream<MessageBusMessage> get messageStream => _messageController.stream;

  String get clientId => _clientId;

  MessageBusService._internal()
      : _clientId = ClientIdGenerator.generate(),
        _dio = DiscourseDio.create(
          receiveTimeout: const Duration(seconds: 60),
          defaultHeaders: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        );

  /// 订阅频道
  void subscribe(String channel, MessageBusCallback callback, {int lastMessageId = -1}) {
    final isNewChannel = !_subscriptions.containsKey(channel);
    
    if (!_subscriptions.containsKey(channel)) {
      _subscriptions[channel] = _ChannelSubscription(
        channel: channel,
        lastMessageId: lastMessageId,
      );
    }
    _subscriptions[channel]!.callbacks.add(callback);
    
    // 如果是新频道且正在轮询，重启轮询
    if (isNewChannel && _isPolling) {
      debugPrint('[MessageBus] 新频道加入: $channel，重启轮询');
      _restartPolling();
    } else if (!_isPolling) {
      _startPolling();
    }
  }

  /// 取消订阅
  void unsubscribe(String channel, [MessageBusCallback? callback]) {
    if (!_subscriptions.containsKey(channel)) return;
    
    if (callback != null) {
      _subscriptions[channel]!.callbacks.remove(callback);
      if (_subscriptions[channel]!.callbacks.isEmpty) {
        _subscriptions.remove(channel);
      }
    } else {
      _subscriptions.remove(channel);
    }
    
    // 无订阅时停止轮询
    if (_subscriptions.isEmpty) {
      _stopPolling();
    }
  }

  /// 使用指定的 messageId 订阅
  void subscribeWithMessageId(String channel, MessageBusCallback callback, int messageId) {
    final isNewChannel = !_subscriptions.containsKey(channel);
    
    if (_subscriptions.containsKey(channel)) {
      _subscriptions[channel]!.callbacks.add(callback);
      // 更新 messageId（使用较大的值）
      if (messageId > _subscriptions[channel]!.lastMessageId) {
        _subscriptions[channel]!.lastMessageId = messageId;
      }
    } else {
      _subscriptions[channel] = _ChannelSubscription(
        channel: channel,
        lastMessageId: messageId,
        callbacks: [callback],
      );
    }
    
    // 如果是新频道且正在轮询，重启轮询
    if (isNewChannel && _isPolling) {
      debugPrint('[MessageBus] 新频道加入: $channel，重启轮询');
      _restartPolling();
    } else if (!_isPolling && _subscriptions.isNotEmpty) {
      _startPolling();
    }
  }
  
  /// 批量订阅多个频道（避免多次启动轮询）
  /// [subscriptions] 格式: {'/latest': {messageId: 123, callback: fn}, ...}
  void subscribeMultiple(Map<String, ({int messageId, MessageBusCallback callback})> subscriptions) {
    for (final entry in subscriptions.entries) {
      final channel = entry.key;
      final messageId = entry.value.messageId;
      final callback = entry.value.callback;
      
      if (_subscriptions.containsKey(channel)) {
        _subscriptions[channel]!.callbacks.add(callback);
        if (messageId > _subscriptions[channel]!.lastMessageId) {
          _subscriptions[channel]!.lastMessageId = messageId;
        }
      } else {
        _subscriptions[channel] = _ChannelSubscription(
          channel: channel,
          lastMessageId: messageId,
          callbacks: [callback],
        );
      }
    }
    
    // 所有订阅添加完成后，统一启动轮询
    if (!_isPolling && _subscriptions.isNotEmpty) {
      debugPrint('[MessageBus] 批量订阅完成，启动轮询: ${_subscriptions.keys}');
      _startPolling();
    }
  }


  /// 开始轮询
  void _startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _shouldStop = false;
    _poll();
  }

  /// 停止轮询
  void _stopPolling() {
    _shouldStop = true;
    _isPolling = false;
    _currentCancelToken?.cancel('[MessageBus] 停止轮询');
    _currentCancelToken = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }
  
  /// 重启轮询（取消当前请求并重新开始）
  void _restartPolling() {
    if (!_isPolling) return;
    
    debugPrint('[MessageBus] 取消当前请求，准备重启');
    _shouldRestart = true;
    _currentCancelToken?.cancel('[MessageBus] 重启轮询');
  }

  /// 执行长轮询（流式处理）
  Future<void> _poll() async {
    while (!_shouldStop && _subscriptions.isNotEmpty) {
      _shouldRestart = false;
      _currentCancelToken = CancelToken();
      
      try {
        final payload = <String, String>{};
        for (final sub in _subscriptions.values) {
          payload[sub.channel] = sub.lastMessageId.toString();
        }
        
        debugPrint('[MessageBus] 发起轮询: $payload');
        
        // 使用流式响应 + CancelToken
        final response = await _dio.post<ResponseBody>(
          '/message-bus/$_clientId/poll',
          data: payload,
          cancelToken: _currentCancelToken,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            responseType: ResponseType.stream,
            extra: {'isSilent': true},
          ),
        );
        
        _failureCount = 0;
        _currentCancelToken = null;
        
        // 流式处理响应
        String buffer = '';
        await for (final chunk in response.data!.stream) {
          // 检查是否需要重启
          if (_shouldRestart) {
            debugPrint('[MessageBus] 检测到重启信号，中断当前响应处理');
            break;
          }
          
          final text = utf8.decode(chunk);
          buffer += text;
          
          // 按 | 分割处理每个完整的消息块
          while (buffer.contains('|')) {
            final delimiterIndex = buffer.indexOf('|');
            final messageChunk = buffer.substring(0, delimiterIndex).trim();
            buffer = buffer.substring(delimiterIndex + 1);
            
            if (messageChunk.isNotEmpty) {
              _processChunk(messageChunk);
            }
          }
        }
        
        // 处理剩余的数据
        if (!_shouldRestart && buffer.trim().isNotEmpty) {
          _processChunk(buffer.trim());
        }
        
        // 如果是因为重启而中断，立即继续下一次轮询
        if (_shouldRestart) {
          debugPrint('[MessageBus] 重启轮询');
          continue;
        }
        
      } on DioException catch (e) {
        _currentCancelToken = null;
        
        // 如果是取消请求（重启轮询），直接继续
        if (e.type == DioExceptionType.cancel) {
          if (_shouldRestart) {
            debugPrint('[MessageBus] 请求已取消，重启轮询');
            continue;
          } else {
            debugPrint('[MessageBus] 请求已取消，停止轮询');
            break;
          }
        }
        
        _failureCount++;
        
        if (e.type == DioExceptionType.receiveTimeout) {
          debugPrint('[MessageBus] 长轮询超时，继续...');
          continue;
        }
        
        final backoffSeconds = min(pow(2, _failureCount).toInt(), _maxBackoffSeconds);
        debugPrint('[MessageBus] 轮询失败: ${e.type}, ${e.message}');
        debugPrint('[MessageBus] $backoffSeconds秒后重试');
        
        await Future.delayed(Duration(seconds: backoffSeconds));
      } catch (e, stack) {
        _failureCount++;
        final backoffSeconds = min(pow(2, _failureCount).toInt(), _maxBackoffSeconds);
        debugPrint('[MessageBus] 未知错误: $e');
        debugPrint('[MessageBus] $stack');
        debugPrint('[MessageBus] $backoffSeconds秒后重试');
        await Future.delayed(Duration(seconds: backoffSeconds));
      }
    }
    
    _isPolling = false;
  }
  
  /// 处理单个消息块
  void _processChunk(String chunk) {
    try {
      final parsed = jsonDecode(chunk);
      if (parsed is List) {
        for (final item in parsed) {
          if (item is Map<String, dynamic>) {
            final message = MessageBusMessage.fromJson(item);
            _handleMessage(message);
          }
        }
      }
    } catch (e) {
      debugPrint('[MessageBus] JSON 解析失败: $e, chunk: $chunk');
    }
  }

  /// 处理收到的消息
  void _handleMessage(MessageBusMessage message) {
    debugPrint('[MessageBus] 收到消息: ${message.channel} #${message.messageId}');
    
    // 处理 __status 消息：更新各频道的 lastMessageId
    if (message.channel == '/__status') {
      final data = message.data;
      if (data is Map<String, dynamic>) {
        for (final entry in data.entries) {
          final channelName = entry.key;
          final lastId = entry.value;
          if (_subscriptions.containsKey(channelName) && lastId is int) {
            _subscriptions[channelName]!.lastMessageId = lastId;
            debugPrint('[MessageBus] 更新频道 $channelName 的 lastMessageId: $lastId');
          }
        }
      }
      return; // __status 消息不需要通知订阅者
    }
    
    // 更新 lastMessageId
    if (_subscriptions.containsKey(message.channel)) {
      final sub = _subscriptions[message.channel]!;
      if (message.messageId > sub.lastMessageId) {
        sub.lastMessageId = message.messageId;
      }
      
      // 通知订阅者
      for (final callback in sub.callbacks) {
        try {
          callback(message);
        } catch (e) {
          debugPrint('[MessageBus] 回调执行错误: $e');
        }
      }
    }
    
    // 广播到全局流
    _messageController.add(message);
  }

  /// 释放资源
  void dispose() {
    _stopPolling();
    _messageController.close();
  }
}
