# MessageBus iOS CPU / 耗电问题分析

日期: 2026-06-11

## 背景

PR #246 的方向是检测到 iOS 后直接禁用 MessageBus 轮询。这个方案能降低耗电，但属于绕过问题：实时通知、话题更新、帖子更新等能力都会退化，而且它没有解释为什么一个长连接轮询会在 iOS 上表现异常。

从现有代码和官方 Discourse 实现对比看，问题更像是 Fluxdo 的 MessageBus 客户端状态机没有完整对齐官方逻辑。iOS 本身不应该因为普通长轮询就持续高 CPU。异常更可能来自请求被快速结束后，客户端用 100ms 间隔不断重连，形成请求风暴，再叠加日志写入和 native stream 处理成本。

## 结论

不建议合并“iOS 直接禁用 MessageBus”的一刀切方案。

建议改为：

1. 保留 iOS MessageBus。
2. 对齐官方 Discourse message-bus-client 的轮询协议和调度规则。
3. iOS 默认不走 chunked streaming，改走 `Dont-Chunk: true` 的普通长轮询响应。
4. 正常无数据返回后，按官方 `polling_interval` / `background_polling_interval` 等待，而不是只等待 100ms。
5. 去掉当前非官方的 `Discourse-Background: true` 请求头。
6. 给每次 poll 加 `__seq`。
7. 补齐 429、cancel、失败重试、chunk fallback 的官方行为。

## 当前 Fluxdo 的关键问题

代码位置: `lib/services/message_bus_service.dart`

### 1. 正常结束后几乎立即重连

当前 `_poll` 每轮请求结束后会直接进入下一轮。唯一保护是 `_minPollInterval = 100ms`。

如果 iOS 的 native Dio stream 或服务端响应因为 chunked / 代理 / URLSession 行为很快结束，客户端就会变成：

```text
POST /message-bus/:client_id/poll
100ms
POST /message-bus/:client_id/poll
100ms
...
```

这才是 CPU 和耗电异常最可疑的根因。

官方不是这样处理。官方在没有数据时会以“距离上次请求开始时间”的方式补足 `callbackInterval`：

```text
startNextRequestAfter = callbackInterval - elapsedSinceRequestStarted
floor = 100ms
```

也就是说，如果一次 long poll 立刻无数据返回，下一次不会马上发，而是等到接近 `polling_interval`。

### 2. iOS 走的是 native stream，不是网页 XHR

`platform_adapter.dart` 会排除 `ResponseType.stream`，所以 MessageBus 不会走 WebView adapter：

```dart
if (options.responseType == ResponseType.stream ||
    options.responseType == ResponseType.bytes) {
  return false;
}
```

官方网页使用的是浏览器 XHR 的 `onprogress` 能力。Fluxdo iOS 当前走的是 native Dio / URLSession stream。两者不是同一个实现，不能直接假设 chunked streaming 行为一致。

所以“网页也有 MessageBus 没问题”这个判断是对的，但需要注意：网页正常的是浏览器 XHR 版本；Fluxdo iOS 当前不是这个路径。

### 3. 缺少官方的 `Dont-Chunk` fallback

官方 message-bus-client 的逻辑是：

1. 默认允许 chunked。
2. 如果当前不使用 chunked，发送 `Dont-Chunk: true`。
3. 如果首个 chunk 在 `firstChunkTimeout = 3000ms` 内没到，就 abort 当前请求。
4. 然后禁用 chunked 一段时间，`retryChunkedAfterRequests = 30`。

Fluxdo 当前总是 `ResponseType.stream`，没有 `Dont-Chunk: true` fallback，也没有首 chunk 超时降级。

在 iOS native stream 不可靠或被代理缓冲时，缺少 fallback 会把问题放大。

### 4. 缺少 `__seq`

官方每次 poll 都会提交递增的 `__seq`：

```text
data.__seq = totalAjaxCalls
```

Fluxdo 当前 payload 只有频道和 last id。虽然这不一定直接导致 CPU 问题，但协议上没有对齐官方。

### 5. 请求头和官方不同

Fluxdo 当前 MessageBus 请求带：

```text
X-SILENCE-LOGGER: true
Discourse-Background: true
```

官方 MessageBus 基础头是：

```text
X-SILENCE-LOGGER: true
Dont-Chunk: true  // 仅非 chunked 时
X-Shared-Session-Key // 跨域 long polling base URL 时
Discourse-Present: true // 用户 present 时
```

`Discourse-Background: true` 不是官方 MessageBus 客户端行为。这里建议移除，避免让后端一直按后台请求语义处理。

### 6. 429 和失败退避没有对齐官方

当前 429 逻辑是：

```text
(Retry-After ?? 60) + random(0..29)s
```

官方逻辑是：

```text
Retry-After 最小 15s
startNextRequestAfter = max(minPollInterval, Retry-After * 1000)
```

当前失败退避是指数退避，最大 30s。官方是失败超过 2 次后线性退避：

```text
callbackInterval * failCount
max = 180s
```

这不是 CPU 问题主因，但建议一起对齐。

### 7. 日志会放大请求风暴成本

MessageBus 请求设置了 `extra['isSilent'] = true`，但 `NetworkLogInterceptor.onResponse` 仍然会把成功响应记录为 info，并通过 `LogWriter` flush 到文件。

如果 MessageBus 进入 100ms 请求风暴，这会变成频繁文件写入，进一步增加 CPU 和耗电。

日志不是根因，但会放大现象。

## 官方 Discourse 行为摘要

官方来源：

```text
/Users/pengyongteng1/f/discourse/frontend/discourse/package.json
/Users/pengyongteng1/f/discourse/frontend/discourse/app/instance-initializers/message-bus.js
/private/tmp/message-bus-client-4.4.1/assets/message-bus.js
/Users/pengyongteng1/f/discourse/config/site_settings.yml
/Users/pengyongteng1/f/discourse/config/initializers/004-message_bus.rb
```

关键默认值：

```text
enable_chunked_encoding = true
polling_interval = 3000ms
anon_polling_interval = 25000ms
background_polling_interval = 60000ms
minPollInterval = 100ms
maxPollInterval = 180000ms
firstChunkTimeout = 3000ms
retryChunkedAfterRequests = 30
server long_polling_interval = 25s
```

官方每轮 poll 的关键规则：

1. 同一时间只允许一个 ajax in progress。
2. 每次请求递增并提交 `__seq`。
3. long poll 且支持 chunked 时才用 chunked。
4. 非 chunked 时发送 `Dont-Chunk: true`。
5. 首 chunk 超过 3s 未到，abort 并临时禁用 chunked。
6. 429 尊重 `Retry-After`，且最小 15s。
7. abort 后 100ms 重试。
8. 失败超过 2 次后线性退避，最大 180s。
9. long poll 收到数据后 100ms 继续。
10. 没数据时按 `callbackInterval` 或 `backgroundCallbackInterval` 补足下一次请求间隔。

## 推荐改法

### 第一阶段: 修 MessageBusService

优先修改 `lib/services/message_bus_service.dart`。

建议状态字段：

```dart
int _totalPollCalls = 0;
int _chunkedBackoffRemaining = 0;

static const Duration _callbackPollInterval = Duration(milliseconds: 3000);
static const Duration _backgroundPollInterval = Duration(milliseconds: 60000);
static const Duration _minPollInterval = Duration(milliseconds: 100);
static const Duration _maxPollInterval = Duration(milliseconds: 180000);
static const Duration _firstChunkTimeout = Duration(milliseconds: 3000);
static const int _retryChunkedAfterRequests = 30;
```

站点设置优先从 `PreloadedDataService().siteSettingsSync` 读取：

```text
polling_interval
anon_polling_interval
background_polling_interval
enable_chunked_encoding
```

因为 Fluxdo 主要在登录后启动 MessageBus，登录用户默认 interval 应该接近官方 `polling_interval = 3000ms`。

### 第二阶段: iOS 走非 chunked 长轮询

iOS 不要禁用 MessageBus，只禁用 native chunked streaming：

```dart
final useChunked = _shouldUseChunkedPolling();
if (!useChunked) {
  headers['Dont-Chunk'] = 'true';
}
```

建议策略：

```text
iOS: 默认 useChunked = false
其他平台: 根据 enable_chunked_encoding 和 chunkedBackoff 决定
```

这不是“一刀切禁用 iOS”，而是承认 Flutter iOS native stream 和浏览器 XHR 不同。iOS 仍然使用官方支持的 long polling，只是不使用 chunked transfer 的流式进度解析。

### 第三阶段: 对齐下一轮调度

请求开始时记录：

```dart
final startedAt = DateTime.now();
```

请求完成后根据结果计算下一轮延迟：

```text
429:
  max(100ms, Retry-After * 1000)，Retry-After 至少 15s

client abort:
  100ms

failCount > 2:
  min(callbackInterval * failCount, 180s)

long poll 且 gotData:
  100ms

其他:
  targetInterval - elapsedSinceRequestStarted
  targetInterval = foreground ? polling_interval : background_polling_interval
  floor = 100ms
```

这个点是解决 CPU 的关键。只要无数据快速返回不再 100ms 重连，请求风暴就会停。

### 第四阶段: 修 chunk parser

官方 chunk 分隔符是：

```text
\r\n|\r\n
```

并且会把转义的：

```text
\r\n||\r\n
```

还原成分隔符内容。

Fluxdo 当前用任意 `|` 分割，比较脆弱。建议改成按官方 separator 解析。非 chunked 模式则把完整 body 当 JSON list 解析。

### 第五阶段: 控制日志放大

MessageBus 成功响应也可以避免写网络日志，或者至少降为 debug：

```dart
extra: {
  'isSilent': true,
  'skipCsrf': true,
  'skipNetworkLog': true,
}
```

然后在 `NetworkLogInterceptor` 里尊重 `skipNetworkLog`。

这不是根因修复，但能降低异常期间的 CPU 和磁盘写入。

## 不建议的方案

### 不建议 iOS 直接 return

原因：

1. 会丢失实时通知和话题更新。
2. 不能解释问题来源。
3. 如果根因是请求风暴，其他平台在类似网络条件下也可能出现。
4. 官方支持非 chunked long polling，没必要直接禁用。

### 不建议只把间隔调大

单纯把 `_minPollInterval` 从 100ms 改成几秒可以缓解 CPU，但仍然不符合官方逻辑。正确做法是区分：

```text
abort / got data: 100ms
无数据正常结束: callbackInterval 补足
后台: backgroundCallbackInterval
失败: backoff
```

## 验证建议

### 单元测试

建议给 `MessageBusService` 增加可测试的纯函数，覆盖：

1. payload 包含频道 last id 和递增 `__seq`。
2. iOS 非 chunked 请求带 `Dont-Chunk: true`。
3. 非 iOS chunked 请求不带 `Dont-Chunk`。
4. 无数据快速返回时，下一轮 delay 接近 `polling_interval - elapsed`。
5. gotData 时 delay 为 100ms。
6. cancel 时 delay 为 100ms。
7. 429 的 `Retry-After` 最小为 15s。
8. failCount > 2 后线性退避，最大 180s。
9. chunk parser 按 `\r\n|\r\n` 分割，不按普通 `|` 分割。

### 真机验证

iOS 真机抓以下指标：

```text
1 分钟内 /message-bus/*/poll 请求次数
每次 poll duration
是否大量 100ms 间隔重连
CPU
能耗
日志文件写入频率
```

修复前如果存在请求风暴，通常会看到一分钟数百次 poll。修复后，前台空闲状态应接近：

```text
每 25s 左右服务端 long poll 返回一次，或按 polling_interval 补足，不会 100ms 连续重连
```

后台应接近：

```text
background_polling_interval，默认 60s
```

## 对这次 Codex 流断开的说明

你看到的：

```text
stream disconnected before completion: stream closed before response.completed
```

是 Codex / 客户端到模型服务之间的响应流中断，不是 Fluxdo 的代码问题，也不是 MessageBus 的运行时错误。

这类问题通常发生在：

1. 单次回复或工具输出太长。
2. 网络或代理中间层关闭长时间 HTTP stream。
3. CLI / 客户端版本和服务端流式协议兼容性问题。
4. 长时间执行工具时，上层连接被回收。

本次规避方式：

1. 把长内容写入仓库 Markdown 文件，减少单次对话输出。
2. 工具输出控制 `max_output_tokens`。
3. 少跑超长命令，优先分段读取和分段总结。

如果要从配置上缓解，优先检查：

1. 升级 Codex CLI / 客户端到最新版本。
2. 避免让 Codex 流量走会截断长连接的代理。
3. 如果必须走代理，调大代理的 idle timeout / read timeout。
4. 减少单次任务输出量，复杂分析落文件。
5. 避免一次性让模型输出超长文档，改为写文件后只回摘要。

这和本仓库要修的 iOS MessageBus CPU 问题是两件事。
