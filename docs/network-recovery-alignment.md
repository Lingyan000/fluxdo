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
- [x] ECH 只接受认证拒绝的重试配置，普通网络失败不关闭 ECH
- [x] 有效 Alt-Svc 保存与下次建连的 H3/TCP 备用
- [x] H3 并发、退避、取消、出口一致性与网络变化测试
- [x] 聚合故障/恢复诊断，区分核心运行与目标连通性
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

第一阶段结束时待做：H3 首次建连/能力保存、ECH 认证重试边界、分段/Fake-IP 受控对照、
故障聚合、图片性能对照和 Android 冒烟。主目录的玻璃 Logo 等未提交工作
不在本分支范围内。本记录不证明 Bettbox 历史故障的根因。

### 第二阶段：H3 冷连接（2026-11-09）

- 有效同源 Alt-Svc 现在参与下一次冷连接；TCP 与 QUIC 同时开始，先成功的
  连接胜出，再发送业务请求。没有公告时保留原 TCP 路径；显式代理跳过 QUIC，
  系统动态代理/PAC 仍经过目标出口检查，不把代理路由改成直接 UDP。
- 后台升级与冷连接共用原有两个探测名额，额外连接也占连接池容量。
  QUIC 探测上限仍为 3 秒，TCP 不等待这个上限；落败/失败探测沿用 5 分钟
  冷却，避免连续图片重复开 UDP。竞速落败不标记为网络故障。
  这些是项目资源参数，并非 Chromium 默认参数。Chromium 部分场景会让
  落败 QUIC 任务继续收集结果；这里随竞速结束取消，以限制移动端占用。
- 服务能力按 origin 保存，连接仍按模板代际隔离。依据
  [RFC 7838 §3.1](https://www.rfc-editor.org/rfc/rfc7838#section-3.1)，只有
  `persist=1` 的公告跨网络变化保留并写盘；启动时无法确认旧网络身份，
  所以没有该标志的公告仅在当前运行期使用。不能宣称所有站点重启后都走 H3。
- 持久化最多 64 项/64 KiB/24 小时，按 DNS/ECH/代理出口配置分区，仅保存
  origin、替代端口和到期时间，不保存 IP、连接或失败状态。60 秒合并写入，
  写失败继续使用内存。进程在写入窗口内被终止，最近学习的信息可能丢失。
- 新公告替换旧公告；`clear`、无可用同源 H3、TTL 归零均撤销旧能力。
  网络代际同时约束旧响应公告、失败回写及探针收尾，旧任务不能清掉新探针。
- 参考 Chromium `HttpStreamFactory::JobController` 的已知替代服务调度，
  本轮查阅 blob `2783d4d0b573e5767911e0b9314edee9565c3e16`；服务属性合并
  写入参考 `HttpServerProperties` blob `947d9915fd91a375776c2574ecb9706ebca19abe`。

验证：Rust 90 项通过（比第一阶段新增 7 项）；配置传递 Flutter 2 项通过。
真实回环 TLS 黑洞 + H3 服务中，两条并发 POST 通过同一 H3 连接各发送一次，
TCP 对端收到 ClientHello 后观测到 EOF；真实 UDP 黑洞 + TLS 服务中，请求在
1 秒测试窗口内完成，未等待 3 秒探测截止。取消后探测名额和连接容量释放，
QUIC 端点连接表也清空。缓存重载、出口分区、网络换代、公告撤销回归通过。
生产配置动态库编译通过，使用该动态库的 Flutter FFI 32 项通过；本次 Dart
文件静态分析无问题，Rust 格式与 diff 检查通过。
这仍是受控本机实验，不证明 Android/Bettbox 实际故障已修复；图片性能对照、
ECH 边界、代理实验及 Android 冒烟仍待完成。

### 第三阶段：ECH 与证书错误边界（2026-11-09）

- 删除“带 ECH 失败后直接去掉 ECH”及随后的 10 分钟按域名禁用缓存。
  超时/重置仍可尝试其他候选地址，但保持原 ECH 设置；后续请求不继承
  由一次网络故障推测出的 ECH 不可用状态。
- HTTP/TCP 只在 BoringSSL 的结构化错误栈确认 `ECH_REJECTED` 后读取
  `get_ech_retry_configs`。该错误要求公共名称握手已认证；读取其他失败的
  retry configs 会触发底层断言，因此不能按错误文本包含 ECH 来判断。
- 一次建连分支最多接受一次认证配置更新：有配置则替换 ECH 密钥，空配置
  则按认证服务端指示在该次连接中停用 ECH，不缓存为全站降级。
  参考 [Chromium SSLConnectJob](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/net/socket/ssl_connect_job.cc)
  blob `52d259d6c561b0cf4eff644e15019a54108dfee6` 及固定 rama-boring 0.7.0
  的 `ssl/test/ech.rs` 认证重试测试；没有修改证书信任要求。
- 证书错误即使在备用握手已启动后发生，也终止整次 TCP 主备连接；镜像
  出站的 `CertTrust` 分类同样保留为证书错误，不再按通用代理错误换地址。
- 当前 Rama MITM 错误接口不保留 SSL 对象及认证重试配置，WebView 镜像
  路径因此不会猜测性重试关闭 ECH。H3 拒绝仍走有证书校验的 TCP 备用，
  没有宣称 QUIC/MITM 已实现与 TCP 相同的认证配置更新能力。

验证：Rust 95 项通过。新增真实 TLS 测试验证服务端 ECH config_id 轮换、
认证服务端明确停用 ECH 后的新连接、公共名称证书不可信时拒绝重试；
另有普通超时保留 ECH、认证更新只重试一次、晚到证书错误取消在途备用的
边界测试。测试密钥是已有上游公开测试向量，仅在 cfg(test) 中编译。

剩余验收：TLS 备用的收益/成本、分段握手与 Fake-IP 的受控代理对照、
聚合诊断、图片性能对照、Android 冒烟。

### 第四阶段：被动故障汇总（2026-11-09）

- 观察真实核心请求，以 origin 汇总故障开始、恢复及重置；最多保存 32 个
  origin，不保存 URL 路径、参数、请求头或响应内容，不新增探测和轮询。
- HTTP 403 等响应表示传输有响应，不代表业务成功。响应体完成才结束故障
  记录；取消与静默长轮询的预期超时不算连接故障。网络换代丢弃旧结果，
  同代较旧请求不能覆盖较新请求已经确认的成功。
- 原有逐请求诊断保留；新增汇总只在故障开始、恢复或重置时写入。
  1,000 次正常同源请求的单元测试只触发一次状态通知、不增加汇总日志。
- 状态卡保留核心运行状态，另行显示最近请求结果及连续失败次数；没有
  请求证据时不展示“已连通”。沿用原有图形/列表布局，重启按钮直接可用。

验证：状态监控及组件 19 项测试通过，覆盖并发乱序、跨网络旧回调、容量、
响应体失败、375/768/812 宽度、深浅色和大字体。真实动态库 FFI 33 项通过，
新增慢响应超时→实际请求恢复→连接重置的观测链路。本次 Dart 静态分析
无问题。视觉与 Android 运行验收见后续记录。
