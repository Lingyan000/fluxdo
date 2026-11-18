# FluxDO 后台 JavaScript 运行时

编辑器和元宇宙可以复用 `JsWorker` 与本地 `qjs`，但不共享全局对象、内存或生命周期。每次 `spawn` 创建一个后台 Dart isolate 和一个 QuickJS 实例。Android、iOS、macOS、Windows、Linux 使用同一套执行接口；Web 上 `JsWorker.isSupported` 为 `false`，由业务选择降级路径。

```dart
final worker = await JsWorker.spawn(debugName: 'editor');
try {
  await worker.evaluate(bundle, name: 'editor.js');
  final html = await worker.evaluateString('render()', name: 'render');
  consume(html);
} finally {
  worker.dispose();
  await worker.terminated;
}
```

同一实例按提交顺序执行，每次成功求值后处理微任务。`evaluate` 忽略返回值；`evaluateString` 只接受同步返回的 JS 字符串，不会隐式 stringify 或等待 Promise。结构化结果由调用方按协议序列化。普通脚本错误只拒绝本次调用；超时或致命错误使整个实例不可复用，并拒绝排队中的调用。主动 `dispose` 不触发 `onFatal`。

## 元宇宙插件分支接入

1. 插件宿主给每个插件单独创建 `JsWorker`，传自己的 `debugName`、执行预算以及现有消息通道 `messageChannel: 'fluxdoMetaverse'`。未指定通道时不会注入 `sendMessage`。
2. 在加载插件脚本**之前**绑定 `onMessage`（收到 JS `sendMessage(channel, jsonString)` 解码后的值）与 `onFatal`。请求 ID、权限校验、桥接 API、宿主响应和插件异常类型仍由插件适配层负责。
3. 卸载时调用 `dispose()` 并等待 `terminated`。超时后新建实例，不复用失效实例。编辑器的销毁或重建不影响插件，反之亦然。

默认每次执行限时 5 秒，每个 JS 实例堆上限 64 MiB、栈上限 512 KiB；调用方可调整。独立实例不是操作系统进程沙箱，公共层不授予网络、文件、账号或 Flutter UI 权限。
