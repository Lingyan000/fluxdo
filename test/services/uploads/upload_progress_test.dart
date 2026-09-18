import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/uploads/upload_progress.dart';

void main() {
  test('未知网络总量不提供百分比依据', () {
    const progress = UploadProgress(phase: UploadPhase.uploading);
    expect(progress.sentBytes, 0);
    expect(progress.totalBytes, isNull);
  });

  test('准备或退避等待可立即取消', () async {
    final token = CancelToken();
    final pending = Completer<void>();
    final waiting = waitForUpload(pending.future, token);
    token.cancel('用户取消');
    await expectLater(
      waiting,
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          '取消类型',
          DioExceptionType.cancel,
        ),
      ),
    );
    // 后台工作之后失败也应被消费，不产生未处理异常。
    pending.completeError(StateError('后台加载失败'));
    await Future<void>.delayed(Duration.zero);
  });

  test('不传取消参数保持原调用行为', () async {
    expect(await waitForUpload(Future.value(42), null), 42);
    checkUploadCancelled(null);
  });
}
