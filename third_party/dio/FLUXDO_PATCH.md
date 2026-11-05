# Dio 响应流生命周期补丁

基线为 pub.dev 官方 Dio 5.11.1（2026-11-05 查询仍为最新稳定版）。保留上游 LICENSE、pubspec、lib、README 与 CHANGELOG；UPSTREAM_SHA256.json 记录原始 lib 文件摘要。未修改全局 pub-cache。

- 来源：https://pub.dev/packages/dio/versions/5.11.1
- 上游实现：https://github.com/cfug/dio/blob/main/dio/lib/src/response/response_stream_handler.dart
- 仅修改 lib/src/response/response_stream_handler.dart。订阅响应后才读源；取消向下传递；暂停时停表，恢复沿用剩余接收预算；真正停滞仍超时；进度回调异常释放资源；正常结束后取消共享令牌不关闭已完成响应，且清除取消监听对象中的响应闭包，避免长期持有已完成流。
- 不改变请求、Cookie、TLS、HTTP 协议、适配器选择和 Transformer API。
- 应用回归：test/services/network/dio_stream_lifecycle_test.dart，以及真实 FFI 流测试。升级 Dio 时先移除覆盖验证上游是否解决，再决定是否保留补丁。

CF widget 回归覆盖正常 EOF 后的响应完成时序：正常结束不再次等待源取消；主动取消仍返回底层取消 Future。
