import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../constants.dart';
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

bool get _disableRealtimeOnIOS =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

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

  Dio _dio;

  final Map<String, _ChannelSubscription> _subscriptions = {};
  final String _clientId;

  bool _isPolling = false;
  bool _shouldStop = false;
  int _pollGeneration = 0; // 每次启动轮询递增，旧循环通过比对自动退出
  bool _backgroundMode = false; // 后台模式：使用更长的轮询间隔
  CancelToken? _currentCancelToken; // 当前请求的 CancelToken
  int _failureCount = 0;
  static const int _maxBackoffSeconds = 30;
  static const Duration _backgroundPollInterval = Duration(seconds: 60);
  // 对齐 Discourse message-bus minPollInterval (100ms)
  static const Duration _minPollInterval = Duration(milliseconds: 100);
  static const Duration _restartDebounce = Duration(milliseconds: 350);
  DateTime? _lastPollTime;
  Timer? _restartPollTimer;

  // MessageBus 独立域名配置
  String? _baseUrl;  // 独立域名（如 https://ping.linux.do），null 表示用主站
  String? _sharedSessionKey;  // 跨域认证 key

  // 消息流（用于全局监听）
  final _messageController = StreamController<MessageBusMessage>.broadcast();
  Stream<MessageBusMessage> get messageStream => _messageController.stream;

  String get clientId => _clientId;

  MessageBusService._internal()
      : _clientId = ClientIdGenerator.generate(),
        _dio = _createPollingDio();

  /// 配置 MessageBus 独立域名（登录后从预加载数据获取）
  void configure({String? baseUrl, String? sharedSessionKey}) {
    final changed = _baseUrl != baseUrl || _sharedSessionKey != sharedSessionKey;
    _baseUrl = baseUrl;
    _sharedSessionKey = sharedSessionKey;

    if (changed && baseUrl != null) {
      // 独立域名需要重建 Dio（不同 baseUrl）
      _dio = _createPollingDio(baseUrl: baseUrl, sharedSessionKey: sharedSessionKey);
      debugPrint('[MessageBus] 配置独立域名: $baseUrl');
    } else if (changed && baseUrl == null) {
      // 恢复主站
      _dio = _createPollingDio(sharedSessionKey: sharedSessionKey);
      debugPrint('[MessageBus] 恢复主站轮询');
    }
  }

  static Dio _createPollingDio({
    String? baseUrl,
    String? sharedSessionKey,
  }) {
    return DiscourseDio.create(
      receiveTimeout: const Duration(seconds: 60),
      defaultHeaders: {
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      baseUrl: baseUrl,
      // 长轮询不受并发限制，避免占用 API 请求的并发槽位
      maxConcurrent: null,
      enableCookies: !_shouldDisableCookiesForPolling(
        baseUrl: baseUrl,
        sharedSessionKey: sharedSessionKey,
      ),
    );
  }

  static bool _shouldDisableCookiesForPolling({
    String? baseUrl,
    String? sharedSessionKey,
  }) {
    if (sharedSessionKey != null && sharedSessionKey.isNotEmpty) {
      return true;
    }

    if (baseUrl == null || baseUrl.isEmpty) {
      return false;
    }

    final pollingUri = Uri.tryParse(baseUrl);
    if (pollingUri == null) {
      return false;
    }

    final appUri = Uri.parse(AppConstants.baseUrl);
    return pollingUri.origin != appUri.origin;
  }

  /// 订阅频道
  void subscribe(String channel, MessageBusCallback callback, {int lastMessageId = -1}) {
    if (_disableRealtimeOnIOS) {
      debugPrint('[MessageBus] iOS realtime disabled, skip $channel');
      return;
    }

    if (!_subscriptions.containsKey(channel)) {
      _subscriptions[channel] = _ChannelSubscription(
        channel: channel,
        lastMessageId: lastMessageId,
      );
    }
    _subscriptions[channel]!.callbacks.add(callback);

    if (!_isPolling) {
      _startPolling();
    } else {
      _schedulePollingRefresh();
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
    } else {
      _schedulePollingRefresh();
    }
  }

  /// 使用指定的 messageId 订阅
  void subscribeWithMessageId(String channel, MessageBusCallback callback, int messageId) {
    if (_disableRealtimeOnIOS) {
      debugPrint('[MessageBus] iOS realtime disabled, skip $channel');
      return;
    }

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

    if (!_isPolling) {
      _startPolling();
    } else {
      _schedulePollingRefresh();
    }
  }


  /// 开始轮询
  void _startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _shouldStop = false;
    _pollGeneration++;
    _poll(_pollGeneration);
  }

  /// 停止轮询
  void _stopPolling() {
    _shouldStop = true;
    _isPolling = false;
    _pollGeneration++; // 确保旧循环在任何 await 恢复后立即退出
    _restartPollTimer?.cancel();
    _restartPollTimer = null;
    _currentCancelToken?.cancel('[MessageBus] 停止轮询');
    _currentCancelToken = null;
  }

  void _schedulePollingRefresh() {
    if (!_isPolling || _shouldStop) return;

    _restartPollTimer?.cancel();
    _restartPollTimer = Timer(_restartDebounce, () {
      _restartPollTimer = null;
      if (!_isPolling || _shouldStop) return;

      final token = _currentCancelToken;
      _currentCancelToken = null;
      token?.cancel('[MessageBus] 订阅集合变更，重新轮询');
    });
  }

  /// 可被 CancelToken 中断的延迟
  Future<void> _cancelableDelay(Duration duration, CancelToken cancelToken) {
    final completer = Completer<void>();
    final timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    cancelToken.whenCancel.then((_) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  /// 执行长轮询（流式处理）
  Future<void> _poll(int generation) async {
    while (!_shouldStop && _subscriptions.isNotEmpty && generation == _pollGeneration) {
      _currentCancelToken = CancelToken();

      try {
        // 最小轮询间隔保护，防止频繁 subscribe/cancel 导致请求风暴
        if (_lastPollTime != null) {
          final elapsed = DateTime.now().difference(_lastPollTime!);
          if (elapsed < _minPollInterval) {
            await _cancelableDelay(_minPollInterval - elapsed, _currentCancelToken!);
            if (_shouldStop || (_currentCancelToken?.isCancelled ?? false)) {
              if (_shouldStop) break;
              continue;
            }
          }
        }

        // 后台模式使用更长的轮询间隔（对齐 Discourse backgroundCallbackInterval）
        if (_backgroundMode) {
          await _cancelableDelay(_backgroundPollInterval, _currentCancelToken!);
          if (_shouldStop || (_currentCancelToken?.isCancelled ?? false)) {
            if (_shouldStop) break;
            continue;
          }
        }

        final payload = <String, String>{};
        for (final sub in _subscriptions.values) {
          payload[sub.channel] = sub.lastMessageId.toString();
        }

        debugPrint('[MessageBus] 发起轮询: $payload');
        _lastPollTime = DateTime.now();

        // 使用流式响应 + CancelToken
        final extraHeaders = <String, dynamic>{};
        if (_sharedSessionKey != null) {
          extraHeaders['X-Shared-Session-Key'] = _sharedSessionKey;
        }
        extraHeaders['X-SILENCE-LOGGER'] = 'true';
        extraHeaders['Discourse-Background'] = 'true';

        final response = await _dio.post<ResponseBody>(
          '/message-bus/$_clientId/poll',
          data: payload,
          cancelToken: _currentCancelToken,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            responseType: ResponseType.stream,
            headers: extraHeaders.isNotEmpty ? extraHeaders : null,
            extra: {
              'isSilent': true,
              'skipCsrf': true,
            },
          ),
        );

        _failureCount = 0;

        // 流式处理响应
        String buffer = '';
        await for (final chunk in response.data!.stream) {
          if (_currentCancelToken?.isCancelled ?? false) {
            debugPrint('[MessageBus] 检测到取消信号，中断当前响应处理');
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
        if (!(_currentCancelToken?.isCancelled ?? false) && buffer.trim().isNotEmpty) {
          _processChunk(buffer.trim());
        }
        
        // 请求结束后清空 token，避免后续误 cancel 已结束的请求。
        _currentCancelToken = null;

      } on DioException catch (e) {
        _currentCancelToken = null;

        if (e.type == DioExceptionType.cancel) {
          if (_shouldStop) {
            debugPrint('[MessageBus] 请求已取消，停止轮询');
            break;
          }
          debugPrint('[MessageBus] 请求已取消，重新轮询');
          continue;
        }

        // 处理速率限制（429 Too Many Requests）
        if (e.response?.statusCode == 429) {
          final retryAfter = int.tryParse(
            e.response?.headers.value('Retry-After') ?? '',
          );
          final waitSeconds = (retryAfter ?? 60) + Random().nextInt(30);
          debugPrint('[MessageBus] 触发速率限制，$waitSeconds秒后重试');
          await Future.delayed(Duration(seconds: waitSeconds));
          if (generation != _pollGeneration) break;
          continue;
        }

        if (e.type == DioExceptionType.receiveTimeout) {
          debugPrint('[MessageBus] 长轮询超时，继续...');
          _failureCount = 0;
          continue;
        }

        _failureCount++;

        final backoffSeconds = min(pow(2, _failureCount).toInt(), _maxBackoffSeconds);
        debugPrint('[MessageBus] 轮询失败: ${e.type}, ${e.message}');
        debugPrint('[MessageBus] $backoffSeconds秒后重试');

        await Future.delayed(Duration(seconds: backoffSeconds));
        if (generation != _pollGeneration) break;
      } catch (e, stack) {
        // 出错后也清空 token，避免重试期间误 cancel。
        _currentCancelToken = null;
        
        _failureCount++;
        final backoffSeconds = min(pow(2, _failureCount).toInt(), _maxBackoffSeconds);
        debugPrint('[MessageBus] 未知错误: $e');
        debugPrint('[MessageBus] $stack');
        debugPrint('[MessageBus] $backoffSeconds秒后重试');
        await Future.delayed(Duration(seconds: backoffSeconds));
        if (generation != _pollGeneration) break;
      }
    }

    // 只有当前活跃的循环才重置 _isPolling，避免旧循环退出时误清新循环的状态
    if (generation == _pollGeneration) {
      _isPolling = false;
    }
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

  /// 当前是否正在轮询
  bool get isPolling => _isPolling;

  /// 进入后台模式：使用更长的轮询间隔（不取消当前请求）
  void enterBackgroundMode() {
    if (_backgroundMode) return;
    _backgroundMode = true;
    debugPrint('[MessageBus] 进入后台模式，轮询间隔 ${_backgroundPollInterval.inSeconds}s');
  }

  /// 退出后台模式：取消当前请求以立即重新轮询
  void exitBackgroundMode() {
    if (!_backgroundMode) return;
    _backgroundMode = false;
    _failureCount = 0;
    debugPrint('[MessageBus] 退出后台模式，立即恢复轮询');
    if (_isPolling) {
      // 取消可能正在等待的后台间隔延迟或长轮询请求，立即重新轮询
      final token = _currentCancelToken;
      _currentCancelToken = null;
      token?.cancel();
    } else if (_subscriptions.isNotEmpty) {
      _startPolling();
    }
  }

  /// 停止轮询并清除所有订阅（登出时直接调用，不依赖 provider 链）
  void stopAll() {
    _stopPolling();
    _subscriptions.clear();
  }

  /// 释放资源
  void dispose() {
    _stopPolling();
    _restartPollTimer?.cancel();
    _messageController.close();
  }
}
