import 'package:dio/dio.dart';

/// preparing 为本地准备，uploading 为传输，processing 为等待服务端处理。
enum UploadPhase { preparing, uploading, processing }

typedef UploadProgressCallback = void Function(UploadProgress progress);

/// totalBytes 为空表示无法获得真实网络进度，不能据此显示百分比。
/// sentBytes 是当前文件去重后的字节进度，不包含重试产生的重复流量。
class UploadProgress {
  const UploadProgress({
    required this.phase,
    this.sentBytes = 0,
    this.totalBytes,
  });

  final UploadPhase phase;
  final int sentBytes;
  final int? totalBytes;
}

/// 在本地准备及重试间隙也响应取消，不启动后续请求。
void checkUploadCancelled(CancelToken? cancelToken) {
  if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
}

Future<T> waitForUpload<T>(Future<T> work, CancelToken? cancelToken) async {
  if (cancelToken == null) return work;
  if (cancelToken.isCancelled) {
    // 消费无法中止的共享准备任务的迟到错误。
    work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    throw cancelToken.cancelError!;
  }
  return Future.any<T>([
    work,
    cancelToken.whenCancel.then<T>((error) => throw error),
  ]);
}
