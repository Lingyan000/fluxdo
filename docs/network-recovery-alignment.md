# 网络恢复机制对齐（实施记录）

基线：`8859544f`，2026-11-09。分支：`codex/network-recovery-align`。

## 目标与依据

改善持续连接失败时的等待、资源释放及协议备用，不将改动宣称为
`app_log_share(16).jsonl` 的根因修复。该日志只能证明核心 TLS 持续超时、
WebView 收到 HTTP 响应；Bettbox 当时实际出站与握手报文尚不可得。

| 机制 | 参考 | 项目适配 |
| --- | --- | --- |
| 完整调用时限、可取消重试 | [OkHttp 5.3.0 OkHttpClient](https://github.com/square/okhttp/blob/parent-5.3.0/okhttp/src/commonJvmAndroid/kotlin/okhttp3/OkHttpClient.kt)、[RetryAndFollowUpInterceptor](https://github.com/square/okhttp/blob/parent-5.3.0/okhttp/src/commonJvmAndroid/kotlin/okhttp3/internal/http/RetryAndFollowUpInterceptor.kt) | 在一次逻辑调用边界控制生命周期，复用现有恢复协调器；参数是项目选择，不冒称上游默认 |
| 候选连接、取消落败连接 | [OkHttp FastFallbackExchangeFinder](https://github.com/square/okhttp/blob/parent-5.3.0/okhttp/src/commonJvmAndroid/kotlin/okhttp3/internal/connection/FastFallbackExchangeFinder.kt) | TCP 竞速与 TLS 备用分别验证，不能宣称两者等价 |
| Alt-Svc、H3/TCP 调度 | [Chromium JobController](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/net/http/http_stream_factory_job_controller.cc)、[HttpServerProperties](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/net/http/http_server_properties.cc) | 同源、有效期、出口隔离、有限并发；网络变化丢弃连接但区分服务能力与网络失败状态 |
| 受控代理故障 | [Mihomo tunnel](https://github.com/MetaCubeX/mihomo/blob/Alpha/tunnel/tunnel.go)、[TLS sniffer](https://github.com/MetaCubeX/mihomo/blob/Alpha/component/sniffer/tls_sniffer.go) | 检验分段/Fake-IP/代理路径，不将当前上游代码等同于用户安装版本 |

Chromium/Mihomo 链接为查阅分支，最终验证记录应补充实验使用的版本。
本轮不升级网络依赖，不新增域名熔断，不自动改变指纹、DoH 或 WebView 模式。

## 完成检查表

- [x] 现有 Rust/Dart 相关测试基线与回归
- [x] 逻辑请求总时限涵盖首次请求、排队、退避、自动重试及响应体
- [x] 显式取消和截止到期贯通当前核心，释放在途/备用任务
- [x] JSON、图片与上传/长轮询的配置边界；不安全请求不重放
- [x] 地址切换、建连共享、旧连接/旧任务隔离的故障测试
- [ ] TLS 备用握手收益对照，证书错误不改变安全策略
- [ ] 有效 Alt-Svc 保存与下次建连的 H3/TCP 备用
- [ ] H3 并发、退避、取消、出口一致性与网络变化测试
- [ ] 聚合故障/恢复诊断，区分核心运行与目标连通性
- [ ] 分段握手与 Fake-IP 状态变化受控验证
- [ ] 并发图片延迟、连接数、CPU/内存基线对照
- [ ] Android 正常环境冒烟（账号场景仍人工验收）

## 实施顺序

1. 故障基线与总时限：保留现有次数限制；总时限属于额外上限，重试不续期。
2. 连接恢复：区分连接尝试与请求重放；优先修复受控实验暴露的实际缺口。
3. H3：经认证 HTTPS 得到同源 Alt-Svc 后允许复用服务信息；不重复发送业务请求。
4. 汇总验证与交付。每项只在有对应证据后勾选，不以单元测试代替真机结论。

## 验证记录

### 第一阶段：调用生命周期（2026-11-09）

- 普通 GET/HEAD/OPTIONS 采用 30 秒调用预算；流式、写操作、显式关闭恢复的
  请求不套该默认值。`FluxRequestKeys.callTimeoutMillis` 支持逐请求覆盖，0 关闭。
  图片 `fetchBytes` 显式采用 2 分钟预算（含下载队列及响应体，调用方可覆盖）。
  这些是项目参数，不是 OkHttp 默认值；正常路径的性能仍需后续对照。
- 截止只取消本调用的子 token；重定向、恢复重放继承同一上下文。父 token
  共享的其他请求不受影响。等待退避、浏览器信任门和共享恢复动作均可退出。
  CF 验证本身可以继续，已取消调用在验证结束后不再重放或切换传输方式。
- Rust 出站预算移到解析/候选/备用握手外层；25 秒上限与连接器配置取较小值。
  HTTP 与镜像握手采用 tokio-util 的 `AbortOnDropHandle`，修复丢弃普通
  `JoinHandle` 仍会让握手任务继续运行的问题。
- 证书及取消错误不参与地址/ECH 重试。通用 ECH 失败降级仍待第二阶段核对，
  **目前没有宣称已完成 ECH 策略对齐**。
- 日志把调用截止记为 `call_deadline`，避免误记成普通用户取消。

验证证据：

| 检查 | 结果 | 覆盖与边界 |
| --- | --- | --- |
| Rust 原始基线 | 77 通过 | 修改前已有测试 |
| `cargo test --manifest-path core/net_core/Cargo.toml --lib --offline` | 83 通过 | 新增 6 项覆盖握手/ECH 等待截止、主备 socket 关闭、证书错误、12 请求共享真实 TLS 黑洞失败、清池后旧请求不回填 |
| 网络目录及头像/下载相关 Flutter 回归 | 255 通过、47 跳过 | 账号/外部环境相关条件跳过不算已验证；其中真实核心本地测试另行启用执行 |
| `FLUXDO_LIVE=1 flutter test test/services/network/core/net_core_local_test.dart` | 32 通过 | 使用本次编译动态库；新增截止经 FFI 关闭慢响应体上游连接，已有上传/代理/背压等回归通过 |
| 本次 Dart 文件静态分析 | 0 error、0 warning | 仅原有 RecoveryCoordinator 构造函数的 initializing-formal 风格提示 |
| `cargo fmt --check`、`git diff --check` | 通过 | 不代替运行验证 |

本地 FFI 动态库 SHA-256：
`d9873ded4777b95b6b47725d9cc9ee69b283f09b5df49b37ce3f097af407b084`。
Flutter 3.47.9 / Dart 3.13.7；按仓库脚本生成 l10n 后执行回归，未修改依赖。

头像隔离测试原先假定异步磁盘查找后 animated0/1 必然先入队；全量回归出现
等待超时、单独运行通过。现改为等待任意两条动图进入适配器，并断言第三条
仍排队、静态头像正常完成，保留原有并发约束而消除无效的顺序假设。

待做：H3 首次建连/能力保存、ECH 认证重试边界、分段/Fake-IP 受控对照、
故障聚合、图片性能对照和 Android 冒烟。主目录的玻璃 Logo 等未提交工作
不在本分支范围内。本记录不证明 Bettbox 历史故障的根因。
