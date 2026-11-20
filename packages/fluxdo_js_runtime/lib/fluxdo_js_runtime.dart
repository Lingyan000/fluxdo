import 'src/unsupported.dart'
    if (dart.library.io) 'src/native.dart'
    as platform;

abstract interface class JsWorker {
  static const isSupported = bool.fromEnvironment('dart.library.io');

  static Future<JsWorker> spawn({
    required String debugName,
    String? messageChannel,
    Duration timeout = const Duration(seconds: 5),
    int memoryLimit = 64 * 1024 * 1024,
    int stackLimit = 512 * 1024,
  }) {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
    if (memoryLimit <= 0) throw ArgumentError.value(memoryLimit, 'memoryLimit');
    if (stackLimit <= 0) throw ArgumentError.value(stackLimit, 'stackLimit');
    return platform.spawn(
      debugName,
      messageChannel,
      timeout,
      memoryLimit,
      stackLimit,
    );
  }

  Future<void> evaluate(String source, {String name = '<script>'});
  Future<String> evaluateString(String source, {String name = '<script>'});
  set onMessage(void Function(Object? message)? handler);
  set onFatal(void Function(String reason)? handler);
  void dispose();
  Future<void> get terminated;
}

final class JsWorkerException implements Exception {
  const JsWorkerException(this.message);
  final String message;

  @override
  String toString() => message;
}
