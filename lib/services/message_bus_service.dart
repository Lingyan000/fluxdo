import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../constants.dart';
import '../utils/client_id_generator.dart';
import 'network/discourse_dio.dart';
import 'preloaded_data_service.dart';

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
///
/// 对齐 message-bus-client (v4) 的调度规则:
/// - 无数据正常返回: 按 `callbackInterval - elapsed` 补足下一轮
/// - 收到数据(long poll) / 客户端 abort: 100ms 后重试
/// - 429: 尊重 Retry-After,且最小 15s
/// - failCount > 2: 线性退避 `callbackInterval * failCount`,最大 180s
/// - iOS native stream 行为不可靠时,自动降级为 `Dont-Chunk: true` 普通长轮询
class MessageBusService {
  static final MessageBusService _instance = MessageBusService._internal();
  factory MessageBusService() => _instance;

  Dio _dio;

  final Map<String, _ChannelSubscription> _subscriptions = {};
  final String _clientId;

  bool _isPolling = false;
  bool _shouldStop = false;
  int _pollGeneration = 0; // 每次启动轮询递增,旧循环通过比对自动退出
  bool _backgroundMode = false;
  CancelToken? _currentCancelToken;
  int _failureCount = 0;
  int _totalPollCalls = 0; // 对齐官方 totalAjaxCalls,用于 __seq
  int _chunkedBackoffRemaining = 0; // 首 chunk 超时后临时禁用 chunked 的剩余次数
  Timer? _restartPollTimer;

  // 对齐官方 message-bus-client 的默认值
  static const Duration _minPollInterval = Duration(milliseconds: 100);
  static const Duration _maxPollInterval = Duration(minutes: 3);
  static const Duration _defaultCallbackInterval = Duration(seconds: 3);
  static const Duration _defaultBackgroundCallbackInterval = Duration(seconds: 60);
  static const Duration _firstChunkTimeout = Duration(seconds: 3);
  static const int _retryChunkedAfterRequests = 30;
  static const int _minRateLimitedSeconds = 15;
  static const Duration _restartDebounce = Duration(milliseconds: 350);

  // MessageBus 独立域名配置
  String? _baseUrl;
  String? _sharedSessionKey;

  // 消息流(用于全局监听)
  final _messageController = StreamController<MessageBusMessage>.broadcast();
  Stream<MessageBusMessage> get messageStream => _messageController.stream;

  String get clientId => _clientId;

  MessageBusService._internal()
      : _clientId = ClientIdGenerator.generate(),
        _dio = _createPollingDio();

  /// 当前前台/后台轮询间隔(从 PreloadedDataService 读取站点设置)
  Duration get _callbackInterval {
    final settings = PreloadedDataService().siteSettingsSync;
    final raw = settings?['polling_interval'];
    final ms = _asInt(raw);
    return ms != null && ms > 0
        ? Duration(milliseconds: ms)
        : _defaultCallbackInterval;
  }

  Duration get _backgroundCallbackInterval {
    final settings = PreloadedDataService().siteSettingsSync;
    final raw = settings?['background_polling_interval'];
    final ms = _asInt(raw);
    return ms != null && ms > 0
        ? Duration(milliseconds: ms)
        : _defaultBackgroundCallbackInterval;
  }

  bool get _siteAllowsChunkedEncoding {
    final settings = PreloadedDataService().siteSettingsSync;
    final value = settings?['enable_chunked_encoding'];
    if (value is bool) return value;
    if (value is String) return value.toLowerCase() == 'true';
    return true;
  }

  static int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// 配置 MessageBus 独立域名(登录后从预加载数据获取)
  void configure({String? baseUrl, String? sharedSessionKey}) {
    final changed = _baseUrl != baseUrl || _sharedSessionKey != sharedSessionKey;
    _baseUrl = baseUrl;
    _sharedSessionKey = sharedSessionKey;

    if (changed && baseUrl != null) {
      _dio = _createPollingDio(baseUrl: baseUrl, sharedSessionKey: sharedSessionKey);
      debugPrint('[MessageBus] 配置独立域名: $baseUrl');
    } else if (changed && baseUrl == null) {
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

    if (_subscriptions.isEmpty) {
      _stopPolling();
    } else {
      _schedulePollingRefresh();
    }
  }

  /// 使用指定的 messageId 订阅
  void subscribeWithMessageId(String channel, MessageBusCallback callback, int messageId) {
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

  void _startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _shouldStop = false;
    _pollGeneration++;
    _poll(_pollGeneration);
  }

  void _stopPolling() {
    _shouldStop = true;
    _isPolling = false;
    _pollGeneration++;
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
      token?.cancel('[MessageBus] 订阅集合变更,重新轮询');
    });
  }

  /// 可被 CancelToken 中断的延迟
  Future<void> _cancelableDelay(Duration duration, CancelToken cancelToken) {
    if (duration <= Duration.zero) return Future.value();
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

  /// 当前请求是否使用 chunked transfer
  ///
  /// 策略:
  /// - 前台优先 chunked,服务端 flush 即到,延迟 <500ms
  /// - iOS 后台改用 Dont-Chunk,让 URLSession 系统级 suspend 接管,省电
  ///   (后台用户看不到 UI,差几秒到达不影响体验,exitBackgroundMode 时会立刻 poll
  ///   一次取回积压消息)
  /// - chunked 首 chunk 超时(代理缓冲、stream 不可靠)时临时降级,30 次后自愈
  /// - 站点关闭 enable_chunked_encoding 时强制不走
  bool _shouldUseChunkedEncoding() {
    if (!_siteAllowsChunkedEncoding) return false;
    if (_chunkedBackoffRemaining > 0) return false;
    if (Platform.isIOS && _backgroundMode) return false;
    return true;
  }

  /// 执行长轮询
  Future<void> _poll(int generation) async {
    while (!_shouldStop && _subscriptions.isNotEmpty && generation == _pollGeneration) {
      _currentCancelToken = CancelToken();
      final cancelToken = _currentCancelToken!;
      final startedAt = DateTime.now();

      bool rateLimited = false;
      int? rateLimitedSeconds;
      bool abortedByClient = false;
      bool gotData = false;
      bool requestFailed = false;
      bool useChunked = false;

      try {
        _totalPollCalls += 1;

        final payload = <String, String>{};
        for (final sub in _subscriptions.values) {
          payload[sub.channel] = sub.lastMessageId.toString();
        }
        payload['__seq'] = _totalPollCalls.toString();

        if (_chunkedBackoffRemaining > 0) {
          _chunkedBackoffRemaining -= 1;
        }
        useChunked = _shouldUseChunkedEncoding();

        debugPrint(
          '[MessageBus] 发起轮询 (seq=$_totalPollCalls, chunked=$useChunked, bg=$_backgroundMode): $payload',
        );

        final extraHeaders = <String, dynamic>{
          'X-SILENCE-LOGGER': 'true',
        };
        if (_sharedSessionKey != null) {
          extraHeaders['X-Shared-Session-Key'] = _sharedSessionKey;
        }
        if (!useChunked) {
          extraHeaders['Dont-Chunk'] = 'true';
        }

        final response = await _dio.post<ResponseBody>(
          '/message-bus/$_clientId/poll',
          data: payload,
          cancelToken: cancelToken,
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            responseType: ResponseType.stream,
            headers: extraHeaders,
            extra: {
              'isSilent': true,
              'skipCsrf': true,
              'skipNetworkLog': true,
            },
          ),
        );

        final responseContentType =
            response.headers[Headers.contentTypeHeader]?.join(',').toLowerCase() ??
                '';
        final serverSaysJson = responseContentType.contains('application/json');

        if (useChunked && !serverSaysJson) {
          gotData = await _readChunkedResponse(response, cancelToken);
        } else {
          gotData = await _readWholeBodyResponse(response, cancelToken);
        }

        _failureCount = 0;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          abortedByClient = true;
        } else if (e.response?.statusCode == 429) {
          final retryAfter = int.tryParse(
            e.response?.headers.value('Retry-After') ?? '',
          );
          rateLimited = true;
          rateLimitedSeconds = retryAfter;
        } else if (e.type == DioExceptionType.receiveTimeout) {
          // 长轮询超时是正常行为,与官方一致按"无数据返回"处理
          _failureCount = 0;
        } else {
          requestFailed = true;
          _failureCount += 1;
          debugPrint('[MessageBus] 轮询失败: ${e.type}, ${e.message}');
        }
      } catch (e, stack) {
        requestFailed = true;
        _failureCount += 1;
        debugPrint('[MessageBus] 未知错误: $e');
        debugPrint('[MessageBus] $stack');
      } finally {
        _currentCancelToken = null;
      }

      if (_shouldStop || generation != _pollGeneration) break;

      final inBackground = _backgroundMode;
      final delay = _computeNextDelay(
        rateLimited: rateLimited,
        rateLimitedSeconds: rateLimitedSeconds,
        abortedByClient: abortedByClient,
        requestFailed: requestFailed,
        gotData: gotData,
        inBackground: inBackground,
        startedAt: startedAt,
      );

      if (delay > Duration.zero) {
        final waitToken = CancelToken();
        _currentCancelToken = waitToken;
        try {
          await _cancelableDelay(delay, waitToken);
        } finally {
          if (identical(_currentCancelToken, waitToken)) {
            _currentCancelToken = null;
          }
        }
        if (_shouldStop || generation != _pollGeneration) break;
      }
    }

    if (generation == _pollGeneration) {
      _isPolling = false;
    }
  }

  /// 计算下一轮请求的延迟,对齐官方 reqComplete 调度逻辑
  @visibleForTesting
  Duration computeNextDelayForTest({
    required bool rateLimited,
    int? rateLimitedSeconds,
    required bool abortedByClient,
    required bool requestFailed,
    required bool gotData,
    required bool inBackground,
    required DateTime startedAt,
  }) {
    return _computeNextDelay(
      rateLimited: rateLimited,
      rateLimitedSeconds: rateLimitedSeconds,
      abortedByClient: abortedByClient,
      requestFailed: requestFailed,
      gotData: gotData,
      inBackground: inBackground,
      startedAt: startedAt,
    );
  }

  Duration _computeNextDelay({
    required bool rateLimited,
    int? rateLimitedSeconds,
    required bool abortedByClient,
    required bool requestFailed,
    required bool gotData,
    required bool inBackground,
    required DateTime startedAt,
  }) {
    if (rateLimited) {
      final raw = rateLimitedSeconds ?? _minRateLimitedSeconds;
      final seconds = raw < _minRateLimitedSeconds ? _minRateLimitedSeconds : raw;
      final candidate = Duration(seconds: seconds);
      return candidate < _minPollInterval ? _minPollInterval : candidate;
    }
    if (abortedByClient) {
      return _minPollInterval;
    }
    if (requestFailed && _failureCount > 2) {
      final base = _callbackInterval.inMilliseconds * _failureCount;
      final capped = base > _maxPollInterval.inMilliseconds
          ? _maxPollInterval.inMilliseconds
          : base;
      return Duration(milliseconds: capped);
    }
    if (gotData) {
      return _minPollInterval;
    }

    final target = inBackground ? _backgroundCallbackInterval : _callbackInterval;
    final elapsed = DateTime.now().difference(startedAt);
    final remaining = target - elapsed;
    return remaining < _minPollInterval ? _minPollInterval : remaining;
  }

  /// 读取 chunked transfer 响应,按官方 `\r\n|\r\n` 分隔符拆分
  ///
  /// 首 chunk 在 `_firstChunkTimeout` 内未到则视为代理在缓冲,
  /// 临时禁用 chunked 一段时间(对齐官方 firstChunkTimeout 行为)。
  Future<bool> _readChunkedResponse(
    Response<ResponseBody> response,
    CancelToken cancelToken,
  ) async {
    var gotData = false;
    final buffer = StringBuffer();
    var pending = '';
    var receivedAnyChunk = false;

    final firstChunkTimer = Timer(_firstChunkTimeout, () {
      if (!receivedAnyChunk && !cancelToken.isCancelled) {
        debugPrint('[MessageBus] 首 chunk 超时,降级为非 chunked 长轮询');
        _chunkedBackoffRemaining = _retryChunkedAfterRequests;
        cancelToken.cancel('[MessageBus] first chunk timeout');
      }
    });

    try {
      await for (final chunk in response.data!.stream) {
        if (cancelToken.isCancelled) break;
        receivedAnyChunk = true;

        try {
          buffer.write(utf8.decode(chunk, allowMalformed: true));
        } catch (_) {
          continue;
        }

        pending = buffer.toString();
        var consumed = 0;
        while (true) {
          final next = _extractNextChunk(pending, consumed);
          if (next == null) break;
          consumed = next.endOffset;
          if (next.payload.isNotEmpty) {
            if (_processChunk(next.payload)) gotData = true;
          }
        }

        if (consumed > 0) {
          buffer.clear();
          buffer.write(pending.substring(consumed));
        }
      }
    } finally {
      firstChunkTimer.cancel();
    }

    // 流结束时如果还剩"完整 JSON 但缺末尾分隔符"的内容,作为一个块处理。
    // 服务端 long_polling 25s 超时无数据时,返回的是 `[]` 而不会带分隔符。
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty && !cancelToken.isCancelled) {
      if (_processChunk(tail)) gotData = true;
    }

    return gotData;
  }

  /// 读取非 chunked(整体 JSON)响应
  Future<bool> _readWholeBodyResponse(
    Response<ResponseBody> response,
    CancelToken cancelToken,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response.data!.stream) {
      if (cancelToken.isCancelled) return false;
      bytes.addAll(chunk);
    }
    if (bytes.isEmpty) return false;
    final body = utf8.decode(bytes, allowMalformed: true).trim();
    if (body.isEmpty) return false;
    return _processChunk(body);
  }

  /// 提取下一个 chunk 块,返回 `(payload, endOffset)`;无完整 chunk 时返回 null
  ///
  /// 对齐官方实现:
  /// - 分隔符: `\r\n|\r\n`
  /// - 内容内的字面 `\r\n||\r\n` 会被还原为 `\r\n|\r\n`(转义)
  @visibleForTesting
  static ({String payload, int endOffset})? extractNextChunkForTest(
    String input,
    int start,
  ) {
    return _extractNextChunk(input, start);
  }

  static const String _chunkSeparator = '\r\n|\r\n';
  static const String _chunkEscaped = '\r\n||\r\n';

  static ({String payload, int endOffset})? _extractNextChunk(
    String input,
    int start,
  ) {
    final index = input.indexOf(_chunkSeparator, start);
    if (index < 0) return null;
    final raw = input.substring(start, index);
    final payload = raw.replaceAll(_chunkEscaped, _chunkSeparator);
    return (payload: payload, endOffset: index + _chunkSeparator.length);
  }

  /// 处理单个消息块,返回是否产生了实际的数据消息
  bool _processChunk(String chunk) {
    try {
      final parsed = jsonDecode(chunk);
      if (parsed is! List) return false;
      var got = false;
      for (final item in parsed) {
        if (item is Map<String, dynamic>) {
          final message = MessageBusMessage.fromJson(item);
          _handleMessage(message);
          if (message.channel != '/__status') got = true;
        }
      }
      return got;
    } catch (e) {
      debugPrint('[MessageBus] JSON 解析失败: $e, chunk: $chunk');
      return false;
    }
  }

  /// 处理收到的消息
  void _handleMessage(MessageBusMessage message) {
    debugPrint('[MessageBus] 收到消息: ${message.channel} #${message.messageId}');

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
      return;
    }

    if (_subscriptions.containsKey(message.channel)) {
      final sub = _subscriptions[message.channel]!;
      if (message.messageId > sub.lastMessageId) {
        sub.lastMessageId = message.messageId;
      }

      for (final callback in sub.callbacks) {
        try {
          callback(message);
        } catch (e) {
          debugPrint('[MessageBus] 回调执行错误: $e');
        }
      }
    }

    _messageController.add(message);
  }

  /// 当前是否正在轮询
  bool get isPolling => _isPolling;

  /// 进入后台模式:下一轮使用 backgroundCallbackInterval
  void enterBackgroundMode() {
    if (_backgroundMode) return;
    _backgroundMode = true;
    debugPrint(
      '[MessageBus] 进入后台模式,轮询间隔 ${_backgroundCallbackInterval.inSeconds}s',
    );
  }

  /// 退出后台模式:取消当前等待立即重新轮询
  void exitBackgroundMode() {
    if (!_backgroundMode) return;
    _backgroundMode = false;
    _failureCount = 0;
    debugPrint('[MessageBus] 退出后台模式,立即恢复轮询');
    if (_isPolling) {
      final token = _currentCancelToken;
      _currentCancelToken = null;
      token?.cancel();
    } else if (_subscriptions.isNotEmpty) {
      _startPolling();
    }
  }

  /// 停止轮询并清除所有订阅(登出时直接调用,不依赖 provider 链)
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
