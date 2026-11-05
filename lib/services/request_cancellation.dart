import 'package:dio/dio.dart';
export 'package:dio/dio.dart' show CancelToken;

extension RequestCancellationCheck on CancelToken {
  void throwIfCancellationRequested() {
    if (isCancelled) throw cancelError!;
  }
}
