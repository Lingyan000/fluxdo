import 'dart:async';
import 'dart:io';

typedef MetaverseSocketStart = Future<ConnectionTask<Socket>> Function(
  InternetAddress address,
  int port,
);
typedef MetaverseSocketSecure = Future<Socket> Function(
  Socket socket,
  String host,
);

Future<Socket> _secure(Socket socket, String host) =>
    SecureSocket.secure(socket, host: host);

/// 保留解析器的首选地址族，同时给另一地址族尽早尝试的机会。
List<InternetAddress> interleaveMetaverseAddresses(
  List<InternetAddress> addresses,
) {
  if (addresses.isEmpty) return const [];
  final primary = addresses.first.type;
  final preferred = addresses.where((ip) => ip.type == primary).iterator;
  final alternate = addresses.where((ip) => ip.type != primary).iterator;
  final ordered = <InternetAddress>[];
  while (true) {
    final hasPreferred = preferred.moveNext();
    final hasAlternate = alternate.moveNext();
    if (!hasPreferred && !hasAlternate) break;
    if (hasPreferred) ordered.add(preferred.current);
    if (hasAlternate) ordered.add(alternate.current);
  }
  return ordered;
}

/// Dart 应急出口使用本次已筛选的候选，交错尝试双栈并校验原域名证书。
/// 只有一个完成 TLS 的连接会交给 HttpClient，HTTP 请求体只发送一次。
Future<ConnectionTask<Socket>> startMetaverseConnection(
  Uri uri,
  List<InternetAddress> addresses, {
  MetaverseSocketStart start = Socket.startConnect,
  MetaverseSocketSecure secure = _secure,
  Duration attemptDelay = const Duration(milliseconds: 250),
  Duration attemptTimeout = const Duration(seconds: 5),
}) async {
  if (addresses.isEmpty) throw const SocketException('没有可用的连接地址');
  final ordered = interleaveMetaverseAddresses(addresses);

  final result = Completer<Socket>();
  final timers = <Timer>[];
  final tasks = <int, ConnectionTask<Socket>>{};
  final sockets = <int, Socket>{};
  var remaining = ordered.length;

  void closeAttempt(int index) {
    tasks.remove(index)?.cancel();
    sockets.remove(index)?.destroy();
  }

  void stop({int? winner}) {
    for (final timer in timers) {
      timer.cancel();
    }
    for (var i = 0; i < ordered.length; i++) {
      if (i != winner) closeAttempt(i);
    }
  }

  Future<void> attempt(int index) async {
    var expired = false;
    Future<Socket?> connect() async {
      final task = await start(ordered[index], uri.port);
      tasks[index] = task;
      if (result.isCompleted || expired) {
        closeAttempt(index);
        unawaited(
          task.socket.then<void>((socket) => socket.destroy(), onError: (_) {}),
        );
        return null;
      }
      final socket = await task.socket;
      sockets[index] = socket;
      if (result.isCompleted || expired) {
        closeAttempt(index);
        return null;
      }
      final secured = await secure(socket, uri.host);
      sockets[index] = secured;
      if (result.isCompleted || expired) {
        closeAttempt(index);
        return null;
      }
      return secured;
    }

    try {
      final socket = await connect().timeout(attemptTimeout);
      if (socket == null) return;
      if (result.isCompleted) {
        closeAttempt(index);
        return;
      }
      result.complete(socket);
      stop(winner: index);
    } catch (error, stack) {
      expired = true;
      closeAttempt(index);
      remaining--;
      if (remaining == 0 && !result.isCompleted) {
        result.completeError(error, stack);
        stop();
      }
    }
  }

  for (var i = 0; i < ordered.length; i++) {
    timers.add(Timer(attemptDelay * i, () => unawaited(attempt(i))));
  }
  return ConnectionTask.fromSocket(result.future, () {
    if (!result.isCompleted) {
      result.completeError(const SocketException('连接已取消'));
      stop();
    }
  });
}
