# 网络核心迁移接续记录

最新性能实施与统一包见 [network-performance-plan.md](network-performance-plan.md)。2026-11-05 已接入 H3、有界连接池、TCP/ECH 重叠、加密 TCP TLS 票据持久化、共享图片取消及解码字节预算。统一包为 `app-network-performance-arm64.apk`，已构建并安装到模拟器。Rust 66 项、图片 34 项通过；公网回归存在环境 TLS 中断，真实手机性能及账号场景待人工验收。未提交/推送。

原 Claude Code 会话：`de1333ec-67fc-4572-998a-b10d317a0682`。

## 检查点

- `3bd3040c`：保存接手前全部网络迁移代码（未验证完成），仅本地提交。
- `.openidea/` 为工具配置，未纳入提交。
- 不要用首页能加载作为核心正常工作的证据：此前实际回退到 Dart IO。

## 本轮修复

Android 的 libdartjni.so 不导出 GetApplicationContext。改由现有 NetCoreBridge 在 Application.onCreate 调 JNI 原生入口，Rust 获取 JavaVM 并持有 Application Context 全局引用；Dart 读取 fluxdo_net_android_ready 就绪标志，失败仍走既有应急路径。依赖增加 jni-sys 0.4（锁文件已有该版本）。

## 验证与环境

- Dart 绑定静态分析通过。
- 网络适配器、Client Hints、请求配置、健康状态共 27 项测试通过。
- Android Rust release 核心编译通过。
- 构建命令（需保留 NDK 和 CMake 配置）：

```sh
PATH=/tmp/ext-review/cmake-venv/bin:$PATH ANDROID_NDK_HOME=/opt/homebrew/share/android-commandlinetools/ndk/27.0.12077973 dart tool/flutterw.dart build apk --release --target-platform android-arm64
```

- 本轮 APK 构建日志：`/tmp/fluxdo-codex-apk.log`（临时文件）。
- 已连接模拟器：`emulator-5580`，包名 `com.github.lingyan000.fluxdo`。
- 普通 cargo check --target 会因没有设置 NDK/clang 而失败；使用项目包装构建命令。

## 后续验收

1. 新包安装并冷启动，检查 NetCoreBridge/FluxdoNet 日志；确认无 JNI 符号错误，真实 HTTPS 连接由核心建立。
2. 验证 CF、Cookie、登录、上传下载、长轮询、取消、DoH/ECH 与代理切换。
3. 多平台构建与系统证书信任回归尚未完成，不能据 Android 冒烟结果宣布整个迁移可发布。

## 2026-11-04 15:21 实机运行结果（Android 模拟器）

- APK 构建成功：99.3 MB；安装成功，冷启动成功。
- 日志：`Network core started (listener port 39119)`。
- 探针：`Probe finished: template ready = true`。
- 核心建立 `doh.pub:443` 的 HTTP/2 连接，以及 `linux.do:443`、`cdn.ldstatic.com:443`、`ping.ldstatic.com:443` 的 HTTP/2 + ECH 连接。
- 截图确认首页话题和头像加载；本次启动未见 NetCoreBridge/JNI 错误。
- 证据临时文件：`/tmp/fluxdo-core-android.log`、`/tmp/fluxdo-core-android.png`。
- JNI 修复与本接续文档保留在工作区，尚未额外提交；原检查点仍为 `3bd3040c`。
- 以上只证明当前模拟器已有 DoH 配置下的启动和连接成功，不代表 CF 挑战、证书信任策略、其他模式及平台全部验收。

## 2026-11-04 继续验收结果

### 本轮代码修复（工作区，未额外提交）

1. 明文 HTTP：不再对 http:// 做 TLS 握手；保留协议、默认端口、编码路径与 IPv6 URI，连接池区分 HTTP/HTTPS。继续复用同一套 DNS 和上游代理选址。
2. 适配器隔离：close(force:true) 只取消当前适配器的请求，避免某个 Dio 销毁连带取消其他请求。
3. 上传后超时：请求体消费完成后开始等待响应头的 receiveTimeout；慢上传本身不计入该超时。
4. 连接池：检查 rama ConnectionHealthWatcher，避免复用超时或取消后已损坏的 HTTP/1.1 连接。
5. CocoaPods 锁文件清理已移除的 rhttp / ua_client_hints（按平台现存项）。iOS 构建产生的其他插件版本和校验和刷新未纳入本次改动。

### 已完成的验证

- Rust：28 项测试通过（含 HTTP/HTTPS 端口、IPv6 URI、ECH 与地址回退）。
- 最终网络全量回归：`FLUXDO_LIVE=1 dart tool/flutterw.dart test --no-pub test/services/network`，187 项通过，3 项 Windows CDP 用例跳过。
- 上述包含 14 项本地 FFI + 5 项公网 FFI 测试：HTTP、1 MB 上传、multipart、重复 Set-Cookie、Cookie 传递、gzip、无效证书拒绝、流式暂停恢复、取消令牌、跨适配器关闭隔离、GET/POST 接收超时、慢上传、三轮各 2 秒的长轮询、应用代理开启/关闭后的实际 CONNECT 路由。
- 修改文件及本地测试的 Dart 静态分析：No issues found。网络目录分析仅有既有 32 条 info 风格提示，没有 error/warning。
- Android arm64 release 构建通过（99.4 MB）、模拟器安装及冷启动通过；首页、匿名话题详情、正文图片加载成功。日志确认核心 HTTP/2 连接，CDN 使用 ECH；这次主站连接日志为 ECH:false，不能声称所有连接都使用 ECH。
- macOS debug 应用最终构建通过。
- iOS device debug 无签名构建通过，产物 `build/ios/iphoneos/Runner.app`；未做真机运行验证。
- `git diff --check` 通过。

### 证据日志（临时目录，可能被清理）

- `/tmp/fluxdo-network-final-tests.log`：187 项网络回归。
- `/tmp/fluxdo-rust-tests.log`：28 项 Rust 测试。
- `/tmp/fluxdo-core-tests.log`：18 项 FFI 测试的前一轮结果；最终以全量网络回归为准。
- `/tmp/fluxdo-local-tests.log`、`/tmp/fluxdo-proxy-test.log`：本地测试迭代日志；早期失败已修复，最终以全量回归为准。
- `/tmp/fluxdo-changed-analyze.log`：修改文件静态检查。
- `/tmp/fluxdo-codex-apk.log`、`/tmp/fluxdo-macos-build.log`、`/tmp/fluxdo-ios-build.log`：三平台构建日志。
- `/tmp/fluxdo-core-android-final.log`、`/tmp/fluxdo-core-android-final.png`、`/tmp/fluxdo-topic-android.png`：最新 Android 运行证据。

### 人工/其他环境验收边界

用户明确选择“先完成无需账号的验证，登录场景留待人工验收”。因此真实登录、账号上传、真实 CF 挑战后会话续用仍待人工验收，单元测试不代表这些现场已验证。

Windows/Linux 缺少本机运行环境，未构建/运行；iOS 后台独立 Isolate、长时间挂机、切网/Doze、企业及用户 CA 信任策略、纯 IPv6 网络仍待目标环境验收。短时长轮询测试不等同于一小时稳定性验证；也未取得 CF 挑战率长期改善的对照数据。

原检查点仍为 `3bd3040c`。当前修复和测试均在工作区；没有推送、发布或合并。`.openidea/` 保持未跟踪。

## 2026-11-04 Android DoH / 图片网络性能优化

用户反馈 Android 开启 DoH 后延迟和图片加载明显变慢，授权借鉴成熟网络实现改进。

### 实现

- `client.rs`：按连接身份协调 HTTPS 冷建连，等待者再次检查 H2 连接池；同批请求共享建连失败，避免失败时串行重复握手。不同域名不互锁，H1 和明文路径维持原行为。清池使用 epoch，清池前的在途建连不能重新填入旧连接。
- `egress.rs`：仅 HTTP 客户端采用最多两个候选的 TCP+TLS 竞速，250 ms 后允许备用候选；单直连地址允许一次备用连接。成功后取消其余候选。WebView 镜像保留原串行入站握手路径。此竞速只做连接握手，不重放业务请求。
- `mirror.rs`：模板版本按稳定能力归一化，忽略 SNI 值、ECH 密文、key share 公钥、票据和 GREASE 随机值；Chromium 扩展顺序归一化。实际原始模板完整保留，真实密码套件、协议能力、HTTP/2 设置及 UA 变化仍更新版本。载入缓存时初始化同一套身份哈希。
- `dns.rs`：A/AAAA 有一族返回可用地址后，另一族最多等待 100 ms；空答案/错误仍等待另一族。用可记忆完成状态的 watch 通知和 RAII 清理替代 Notify，leader 被取消时也释放查询合并槽并唤醒等待者。
- `core.rs`：状态增加 `established_connections` 计数，便于验证共享连接。
- 图片层已有分通道并发、可见优先和下载去重。本轮优化落在其共用网络出口，没有上调下载并发或调整图片解码/UI。

### 设计参照

Chromium 的 H2 会话/建连协调，Mihomo 的有限双栈等待和 DoH 生命周期，OkHttp 的路由/连接复用边界。均为按设计独立实现，未整库替换或复制其源码。

### 验证与对照

- `cargo test --offline --lib`：33 项通过，新增模板稳定性、真实能力变化、慢协议族、查询 leader 取消、慢握手备用竞速测试。
- `FLUXDO_LIVE=1 dart tool/flutterw.dart test --no-pub test/services/network`：188 项通过，3 项平台相关用例跳过。新增 8 个同域冷并发请求只建立一条可用 H2 会话的回归。
- 本机 8 个并发 HTTPS 小图 GET（www.cloudflare.com/favicon.ico，响应 200、每次 908 字节）抽样：
  - 优化前建立 8 条 H2 会话，全部完成约 1.39 秒，中位约 0.86 秒。
  - 中间“仅合并建连”的版本曾因首条握手慢而全部等约 4.54 秒，因此补入有界备用握手。
  - 最终版共享 1 条 H2 会话，全部完成约 0.86 秒，中位约 0.86 秒。备用 TLS 尝试上限为 2，不等于物理握手永远只有 1 次。
  - 此结果仅为同机公网小图抽样，不能等同于 Android DoH 全场景或大图吞吐提升比例。
- 对照用的是优化前后核心，未拿更早的 Cronet/rhttp APK 做同机 A/B。
- 临时证据：`/tmp/fluxdo-perf-rust-tests.log`、`/tmp/fluxdo-perf-network-tests.log`、`/tmp/fluxdo-image-before.log`、`/tmp/fluxdo-image-after.log`（中间版）、`/tmp/fluxdo-image-after-final.log`。
- 优化前动态库仅临时保存在 `/tmp/fluxdo-net-before-perf.dylib`。

Android 性能版构建/运行记录见下方续记。原检查点仍为 `3bd3040c`，本轮改动未提交/推送。

### 性能版 Android 续记

- arm64 release APK 构建成功（99.5 MB），产物 `build/app/outputs/flutter-apk/app-release.apk`。
- 已安装到 emulator-5580，沿用 DNSPod DoH 配置冷启动，核心成功运行。
- 此次日志中 doh.pub、linux.do、cdn.ldstatic.com、cdn3.ldstatic.com、ping.ldstatic.com 各建立 1 条可用 H2 会话；主站及 CDN 为 ECH:true。
- 对照之前那次 Android 启动日志，cdn.ldstatic.com 从 6 条会话变为本次 1 条。两次不是受控页面/缓存/网络 A/B，不据此计算整页加载提速。
- 首页头像、匿名话题详情和正文图片已通过截图检查。证据 `/tmp/fluxdo-perf-android.log`、`/tmp/fluxdo-perf-android.png`、`/tmp/fluxdo-perf-topic.png`。
- 图片下载优先级和并发上限保留，性能优化来自共用网络核心。现有图片磁盘缓存会影响页面体感，真机比较应使用相同缓存条件。
- 本轮未改变 DoH 服务器配置、ECH 策略或系统证书校验，也未新增不受控请求重放。DoH 引导解析仍使用原有系统 DNS 路径，本轮未新增固定 IP 配置。
- 此性能版本验证覆盖 macOS 本机核心/FFI 和 Android；未重新构建性能版 iOS/Windows/Linux 应用。此前 iOS/macOS 应用构建成功记录属于此前版本，不能混同。
- 本轮 `git diff --check` 通过。未额外提交或推送。

## 2026-11-04 晚间接手 BAD CSRF 调查

Claude 会话 de1333ec 的最新状态：app_log_share(6).jsonl 中 core timings 11 次200、67 次403，emergency 3 次200。各窗口登录凭据不同，不能当固定会话的传输 A/B。回显头/体正确与 JA4 一致也不足以排除实际会话配对或完整传输行为问题。独立核验说明临时存放 `/tmp/fluxdo-csrf-investigation-for-claude.md`。

### 本轮修复

- 保留恢复层与 Cookie 拦截器顺序。RequestHeaderInterceptor 在必要的 CSRF 刷新结束后，调用同一个 AppCookieManager 的 refreshRequestCookies，重新加载原 POST 的 Cookie。显式 skipCookieManager 仍旁路，不覆盖手工 Cookie。
- 回归测试模拟刷新期间 CookieJar 轮换：原 POST 使用新会话 Cookie＋新 CSRF；旧逻辑的旧 Cookie＋新令牌组合已在临时测试中复现。
- 此漏洞旧版也存在。实际日志的持续失败期间未看到对应 _forum_session 轮换，故不宣称已找到或修复线上持续 BAD CSRF 根因。

### 会话关联诊断 schema 1

新增 csrf_session_trace.dart：对 CSRF 请求和携带 CSRF 的写请求，在适配器入口捕获请求快照，关联 CsrfTokenService 的刷新事件。

- csrfTraceVersion=1、csrfDispatchId、csrfRefreshId：定位具体派发与刷新。
- csrfTokenHash：Rails 64字节 masked token 去掩码后 SHA256 前16位；同真实令牌不同掩码可关联。
- sentForumSessionHash、csrfFetchSessionHash、csrfResponseSessionHash、csrfEffectiveSessionHash：会话 Cookie 短哈希。
- csrfCookieMatchesRefresh：仅比较 Cookie wire 值，不证明解密后的 Rails 会话语义相同/不同；Cookie 加密随机化也可能造成哈希不同。
- csrfContextKnown=false：缓存/外部注入令牌没有已知刷新记录，不伪造配对结论。
- csrfFetchAdapter、csrfCookieAuthority：区分 core/emergency 与浏览器管理 Cookie。WebView 不把 RequestOptions 中的 Cookie 当成实际浏览器 Cookie，因此不生成匹配判断。
- sentHeaderNames、sentContentLength；FFI 另记 sentBodyBytes/sentBodyChunks/sentBodyComplete。
- csrfTraceStage=adapter-input，bodyCountStage=core-input：只证明交入适配器/核心的数据，不等同于服务端实际收到的 wire 抓包。
- 不记录 token、Cookie 或请求体明文；普通图片 GET 不做这些哈希。关联缓存最多16项，登出清空。

### 验证与交付

- 网络目录：172 项通过，24 项跳过（21项依赖本机核心/公网，3项平台用例）。
- 显式开启真实核心用例：21 项全部通过。合计193项通过，3项平台用例未运行。
- network + 新测试静态分析无 error/warning；有代码风格 info。
- Android arm64 release APK 构建成功，99.5 MB；`build/app/outputs/flutter-apk/app-release.apk`。日志 `/tmp/codex-csrf-apk.log`。
- 单元测试日志 `/tmp/codex-csrf-network-tests.log`、真实 FFI 日志 `/tmp/codex-csrf-ffi-tests.log`。
- 本轮不改 Rust 出口、TLS 指纹或 CF 判定，不安装设备、不提交、不推送。当前仅有模拟器连接，没有用户真机。

### 继续方式

用户沿用改包名共存方式更新测试版，保留当前登录态，进入少量话题触发 timings 并导出应用日志，确认存在 csrfTraceVersion=1。先核对刷新和 POST 的会话/令牌关联，再决定是否需要固定凭据的 core/IO（或旧 gateway）差分；不要因空 DATA 或 Origin 等猜测继续盲改传输。

## app_log_share(7).jsonl：恢复转折（22:08—22:10）

新 schema 1 记录：timings 2 次403，随后14次200。

- 22:08:41.404（文件第4503行）：POST403。CSRF刷新已完成，csrfContextKnown=true，csrfCookieMatchesRefresh=true，body152字节已完整交入核心。
- 22:09:26.294（第4535行）：从后台恢复，调用 ensureProxyAlive→resetConnections，日志确认清掉4条业务H2连接及1条DoH H2连接。
- 22:09:28.447（第4559行）：linux.do 同一地址104.18.11.118重新建立H2，ECH:true、resumed:true。
- 22:09:28.985（第4565行）：新连接GET /session/csrf 200。
- 22:09:29.524（第4572行）：POST200，此后14次timings连续200。

两次关键POST之间，sentForumSessionHash与去掩码csrfTokenHash均相同，Cookie总长度1793、头名集合和body长度152也相同。恢复窗口未见_t/_forum_session轮换或新的bootstrap成功记录，cf_clearance刷新报告未变化；始终core，没有切WebView/emergency。失败的第二个POST与成功POST都不含_rt，故_rt是否存在不能解释本次转折。

结论边界：恢复紧随前台清池/重建连接，主要嫌疑收敛到旧连接的复用、握手或服务端连接级状态；不能从一段日志单独断定TLS恢复、H2实现或某个风控机制就是根因。此前修补的Cookie/CSRF时序漏洞不解释本次已关联且仍403的请求。本次未修改业务代码。

## 2026-11-05 app_log_share(9) 复发：新连接仍失败

只分析 2026-11-05 新增记录（第5394行起），不混入文件中此前的历史记录。

- 09:04:23（第5402行）VPN自动设置已关闭DoH：系统代理127.0.0.1:7890，WebView直连；第5430行linux.do新H2连接，ECH=false、TLS恢复=false。
- 09:04:30～09:06:44，22次timings POST与1次mark-read PUT均403（第5603～6581行）。其中22次已关联刷新且csrfCookieMatchesRefresh=true；首次缓存令牌无已知关联。所有请求体字节数与Content-Length相等，且完整交入核心；这不是服务端wire证据。
- 09:06:45（第6587行）CSRF GET出现429并触发CF验证；验证通过后GET重试200（第6620行）。不要持续刷请求测试，以免增加限流干扰。
- 09:08:17应用重新启动（第6625～6631行），第6651行又建立全新H2连接，ECH=false、TLS恢复=false。随后另一组Cookie/CSRF哈希下5次timings POST仍全部403（第6830～6949行），其中4次已关联刷新并匹配Cookie。
- 09:52重新启动后，09:53两次前台清池；文件结束前没有新的主站CSRF写请求。ping.ldstatic.com MessageBus POST200不能作为主站恢复证据。

更新判断：关闭DoH、应用重启、新建完整TLS连接都未充分解决；不能把上次恢复归因为清池，也不能以旧连接损坏作为唯一解释。适配器输入的Cookie/令牌配对和body计数一致，仍不能排除核心后续传输、浏览器实际Cookie状态差异或服务端策略。

本次只更新调查记录，不更改网络行为。最小下一步使用已有网络设置中的WebView兼容模式，在复发时保持登录和代理不变，少量浏览触发timings，再关闭兼容模式复测并导出同一份日志。比较core→webview→core状态，同时核对Cookie变更；WebView实际Cookie不由RequestOptions代表，若切换期间会话发生变化，不能称为固定凭据A/B。当前Android实际登录场景仍需用户手机执行，不用未登录模拟器冒充验收。

## 2026-11-05 app_log_share(10)：切换WebView后恢复

用户按前述步骤开启WebView网络引擎，反馈切换后可以；本文件新增部分为第7186～7798行。

- 09:58:38.250（第7426行）、09:58:40.838（第7448行）：core timings两次403。后一次已刷新、Cookie哈希配对一致。
- 09:58:40.545（第7444行）core CSRF刷新与09:58:57.440（第7536行）WebView CSRF刷新，去掩码令牌哈希同为2b3726441ae42b28。
- 09:58:57.744～09:59:08.747（第7558～7794行）WebView timings连续6次200。不能将恢复解释为更换真实CSRF令牌。
- 两个状态之间未记录新的登录Cookie轮换，WebView请求前对_forum_session等Cookie的sweep均为noop；但这些记录不能替代WebView实际出站Cookie快照。
- 截止日志末尾仍为compat=persistent；没有关闭兼容模式后的core写请求，因此尚非完整core→webview→core复测。

结论：已获得紧邻时间窗内core失败、WebView成功的传输路径对照；重点是实际出站Cookie/请求头及核心序列化、HTTP/TLS行为差异。它不足以单独证明H2、TLS指纹、CF策略或某一个Cookie是根因。WebView请求的sentCookieLen等旧字段来自RequestOptions，不能当作浏览器实际发出的Cookie。本次仅更新调查记录，未更改业务代码，也未再次打包。

## 2026-11-05 后续处理：诊断 schema 2

用户询问下一步。当前保留WebView兼容模式可用，仍未宣称core根因修复；补充以下诊断以减少下一次真机对照的不确定性，不修改引擎选择、Cookie同步或重试策略：

- `csrfInputHeaderHashes`：Dart适配器入口处Cookie、CSRF、Origin、Referer、UA、Content-Type、Content-Length的SHA256前16位，逐值保留重复头。
- `corePreparedRequest.stage=core-prepared-headers`及`header_hashes`：Rust完成协议适配、逐跳头剔除与模板重排后，交给HTTP后端编码前的同口径快照，经FFI响应头事件返回。可核对FFI/核心整理是否改变关键头；**不是HPACK编码后抓包或服务端收到的证据**。
- `browserCookieSnapshotStage=store-before-fetch`、`browserStoreCookieHashes`、`adapterInputCookieHashes`：WebView请求完成priming/sweep后，只读CookieManager中_forum_session、_t、cf_clearance的值哈希，与应用准备的Cookie同时记录；多变体保留，缺失项不伪造匹配。
- 浏览器读取限制1秒，失败记`browserCookieSnapshotAvailable=false`且继续原请求；仍不是浏览器wire抓包，无法单凭store快照排除partition/上下文差异。
- 图片和普通GET不新增哈希/浏览器Cookie读取；不新增服务端探测请求，不写凭据明文。

验证：Rust43项通过（含重复头/不泄露原文/GET不采样）；网络模块174项通过、25项条件跳过。随后启用本地真实核心FFI，15项全部通过（含新增关键头哈希返回与服务端Cookie/请求体核对），上述跳过项中仍有7项公网和3项平台测试未运行。静态检查无error/warning，仅1项已有集合语法info；git diff --check通过。浏览器平台Cookie读取和实际账号行为尚需真机，不能用本地FFI代替验收。日志：`/tmp/fluxdo-csrf-trace2-{rust,network,ffi,analyze}.log`。

本机构建需把已安装CMake路径加入PATH，并指定ANDROID_NDK_HOME=/opt/homebrew/share/android-commandlinetools/ndk/28.2.13676358。Android arm64 release诊断包构建成功（99.4MB）：`build/app/outputs/flutter-apk/app-release.apk`；日志`/tmp/fluxdo-csrf-trace2-apk.log`。没有安装设备、提交或推送。

真机下一步：沿用此前共存测试包的更新方式保留登录态；保持代理和DoH状态，短暂关闭WebView引擎浏览一个话题，再开启浏览一个话题，导出同一份应用日志。先看schema2的输入与核心准备头哈希，再看WebView store与输入Cookie哈希。日常仍保持WebView开启；这是定位包，不是core根因修复。

## 2026-11-05 app_log_share(11)：确认核心重复CSRF头并修复

schema2首次在真机抓到直接的输入/核心整理差异：

- 第8105～8375行：前段core timings 8次403；第8534、8560行WebView timings 2次200；切回core后第8622、8654行再出现2次403。
- 所有10次失败的core POST，在`csrfInputHeaderHashes.x-csrf-token`均只有1个哈希，`corePreparedRequest.header_hashes.x-csrf-token`均为同值2份；其余采样的6种头值和数量均一致。8次core CSRF GET的输入/整理后哈希无差异。
- 真实CSRF令牌哈希始终cc590bfee90666a6；WebView store与应用输入的_forum_session哈希cf8b05b36f398c41、_t哈希442240e80b07b1d5一致。cf_clearance哈希不同是另一个观察项，不在本轮顺带修改同步策略。

代码机制：固定Rama提交的HeaderName::as_str对标准头返回小写，对自定义头保留原始拼写。client.rs的reorder_headers第一遍按模板复制值，第二遍用区分大小写的字符串判断是否已复制。输入X-CSRF-Token、模板x-csrf-token时，第一遍复制1次，第二遍又补1次；模板重复同名头还会倍增原值。之前普通回显模板没有覆盖这个条件，不能排除此缺陷。

先补回归再修复：旧代码单个CSRF值变2个，重复模板名把原2个值变6个，两个回归均失败，证据`/tmp/fluxdo-csrf-duplicate-before.log`。修复使用HashSet<HeaderName>按HTTP头名语义忽略大小写匹配，模板同名项只处理一次，原有多值头完整保留，不靠强制覆盖或删除多值头来掩盖问题。旧缓存无需清理。Rust全量45项通过，证据`/tmp/fluxdo-csrf-duplicate-after.log`。

本轮只改核心头重排及对应回归，保留schema2诊断；不修改Cookie/CF同步、TLS/H2参数、引擎选择或重试策略。真实FFI测试增加浏览器排序模板并核对本地服务端收到恰好1条CSRF；修复包继续构建。该代码缺陷已复现并修复，但用户账号下403消失仍待安装修复包确认。

补充验证：更新后的本机release核心加载模板成功；本地真实FFI15项全部通过，新增断言确认服务端收到`['secret-token']`而非重复值，日志`/tmp/fluxdo-csrf-duplicate-ffi.log`。新增测试静态检查无问题，`git diff --check`通过。本轮未重复公网或账号测试，未安装设备、提交或推送。

Android arm64修复APK构建成功（99.4MB），独立文件名`build/app/outputs/flutter-apk/app-csrf-header-fix-arm64.apk`，避免与上一版诊断包混淆。核心产物已核对：本轮Cargo输出、jniLibs暂存、AGP合并产物逐字节一致；AGP裁剪符号后的产物与APK内核心逐字节一致（裁剪前后差8字节，不直接比较两者）。APK SHA256为5bdc784e3c63abc8182608864e297c58417c5623c6c6d36db3451eac554fe77d。构建日志`/tmp/fluxdo-csrf-duplicate-apk.log`。下一步沿用共存包方式保留登录态更新，关闭WebView正常浏览一两个话题，导出日志检查core POST200以及CSRF输入/核心准备值均为单条。真机403是否完全消失尚待确认。

## 2026-11-05 app_log_share(12)：真机恢复确认

用户反馈症状消失。仅分析前一份导出8686行之后的新记录：修复版11:14:56～11:15:24的11次core timings POST全部200（第8943～9182行），每次CSRF入口与核心准备阶段数量均为1，采样关键头哈希无差异；新增窗口没有csrf_bad_response_detected事件。另有11次core GET200。确认本次复现路径在修复后恢复，仍不把短窗口等同于所有账号写操作/长期网络场景验收。

间歇性触发的代码条件：仅当fetch排序模板包含自定义头名、且模板拼写与原请求头拼写不一致时，旧代码会重复追加；模板按采样请求更新并可落盘。由此可解释为何不同模板状态下结果不同，但历史每次自愈时未记录模板内容，不能断言每次恢复均由模板变化造成。修复按HeaderName身份处理，使大小写和重复模板条目均不改变原请求值数量。

## 2026-11-05 人工复审第一批：重放语义与上传背压

用户明确要求不使用yunxiao-smartcr，已停止该流程，按调用链直接审查。此次优先覆盖client.rs、ffi.rs、Dart核心适配器，以及连接/DNS/恢复链的相关调用；不是整个迁移所有平台已审完的声明。

确认并处理：

1. P1 空请求体不等于幂等。旧核心只检查is_end_stream，复用连接上服务端执行空POST后丢失响应，核心会换连接重复POST。真实本地TCP服务回归已在旧实现复现（第二次执行被误报成成功），现限制为无请求体且HTTP幂等方法；原有GET断连恢复仍保留。Dart恢复策略已有方法限制，Rust内部重放此前绕开了它。
2. P2 Connection声明的逐跳头未删除。原来只删固定列表，本地回归确认Connection: X-Local后X-Local仍被发到下一跳。现解析所有Connection值，再移除所指定的头和固定逐跳头。多个字段、逗号列表和大小写均覆盖。
3. 上传队列满仍先to_vec再try_send，退避期间反复分配/复制/释放整块数据。改用Tokio try_reserve先取得容量；100次满队列重试的回归确认复制闭包调用0次，腾出容量后恰好复制一次，关闭队列不复制。保留现有背压返回码。另避免对(null,0)调用from_raw_parts，零长写对有效请求直接成功。

参考：OkHttp RetryAndFollowUpInterceptor的发送状态/一次性body区分与RealConnectionPool的连接状态和空闲清理设计；Hyper Incoming的按需消费/流量控制；Tokio Sender.try_reserve容量预留；RFC9110 §9.2.2重放语义、§7.6.1逐跳头。实现独立编写，并非直接复制项目代码。
- https://raw.githubusercontent.com/square/okhttp/master/okhttp/src/commonJvmAndroid/kotlin/okhttp3/internal/http/RetryAndFollowUpInterceptor.kt
- https://raw.githubusercontent.com/square/okhttp/master/okhttp/src/commonJvmAndroid/kotlin/okhttp3/internal/connection/RealConnectionPool.kt
- https://raw.githubusercontent.com/hyperium/hyper/master/src/body/incoming.rs
- https://docs.rs/tokio/latest/tokio/sync/mpsc/struct.Sender.html#method.try_reserve
- https://www.rfc-editor.org/rfc/rfc9110.html

后续设计审查重点：全局空闲连接预算/淘汰（当前H1只在借用时剔除过期，H2无全局空闲预算）、跨FFI下载按字节确认消费以约束回调积压、上传停滞与取消时流订阅释放。上述不能靠调大并发或改变指纹解决，应分别做内存峰值/取消时延/慢消费者测试再决定改法。尚未对其完成修复或验收。

验证：修复前两项协议回归失败，`/tmp/fluxdo-review-before.log`；修复后Rust48项通过，`/tmp/fluxdo-review-after.log`。性能结论仅为避免满队列无效拷贝，不声明Android图片加载百分比提升。本批未提交、推送或重新构建Android APK。

本批最新macOS release核心已构建，并通过真实FFI本地15项回归（大上传、multipart、Cookie/CSRF单头、取消、超时、暂停恢复），`/tmp/fluxdo-review-ffi.log`；git diff --check通过。手机仍使用前一批已验收的CSRF修复包，本轮源代码变更尚未做Android真机验收。

## 2026-11-05 持续优化第二批：上传生命周期与下载回调预算

继续按源码调用链审查，未使用yunxiao-smartcr、未启动子代理、未提交/推送。

本轮实现：

1. 上传原来的await-for只能在下一块数据到达时发现取消。改用StreamIterator和独立停止信号，CancelToken、适配器force close、核心终态均主动取消源订阅；正常上传EOF也释放停止回调。取消令牌回调按id查当前请求，避免长寿命令牌持有已完成的PendingRequest。
2. 服务器提前返回400及以上响应时停止源流，继续读取错误响应。**此时不能调用requestFinish伪造上传EOF**：声明Content-Length尚未写满会让HTTP/1关闭连接并丢失响应体。原生写入端留到请求终态统一释放。原始HttpServer测试会等请求体，换成真实TCP先回413头、收到源取消后再发响应体，以覆盖该时序。
3. 宿主上传块最大64KiB，原生8块队列对应至多512KiB排队数据（不包含源流持有的原始大块、协议栈缓冲）。1MiB+17字节单源块拆成17次FFI写，服务端字节和诊断计数一致。
4. Rust每请求增加1MiB未归还DATA载荷预算，许可与回调指针一起登记，buffer_free释放载荷后归还许可。无需新增FFI符号；先移除指针记录再释放地址，避免地址被并发复用。小块至少计4KiB许可，最多256个未归还DATA回调。单事件硬上限256KiB，超大底层块用Bytes余片分段，不丢失尾部。
5. 新宿主发送defer_response_body=true，响应流onListen后恢复核心读取，旧宿主不传时保留旧启动方式。暂停发生在等待下一块期间也暂停核心receiveTimeout；等待字节预算同样不计接收超时。上游真正停滞仍按原超时处理。
6. 补齐ResponseBody.onClose。Dio在receiveDataWhenStatusError=false时会直接close响应；现在会取消核心请求，真实TCP测试确认上游连接关闭。

验证和范围：
- 原上传取消回归在旧实现2秒内等不到源取消；日志`/tmp/fluxdo-upload-cancel-before.log`。最初提前413用HttpServer的用例不具备有效响应时序，不用它的超时作为产品根因证据。
- 新Dart配旧核心的延迟订阅用例复现receiveTimeout；`/tmp/fluxdo-download-before.log`，同批普通慢消费对照通过。
- Rust51项通过，含未归还预算耗尽/归还恢复、超大块尾部完整性、暂停不消耗接收时限；`/tmp/fluxdo-stream-rust.log`。
- 最新macOS release核心已构建，真实FFI23项全部通过；`/tmp/fluxdo-stream-native.log`和`/tmp/fluxdo-stream-ffi.log`。覆盖停滞上传取消/强制关闭、提前413、大单块上传、放弃错误响应关闭连接、延迟订阅、慢消费、8MiB+17字节下载逐块校验及事件上限。
- 静态检查两文件无问题，`/tmp/fluxdo-stream-analyze.log`；git diff --check通过。网络模块总回归和Android构建继续进行。

设计参考：Dart StreamIterator.cancel会取消底层订阅并使待决moveNext返回false；Hyper Incoming的按需消费/释放流控容量；Tokio Semaphore的容量许可与OwnedSemaphorePermit生命周期。独立实现，没有复制上游源码。
- https://api.dart.dev/dart-async/StreamIterator/cancel.html
- https://raw.githubusercontent.com/hyperium/hyper/master/src/body/incoming.rs
- https://docs.rs/tokio/latest/tokio/sync/struct.Semaphore.html
- https://raw.githubusercontent.com/cfug/dio/main/dio/lib/src/adapters/io_adapter.dart

尚未完成的边界：1MiB仅是每请求FFI未归还载荷预算，不是进程总内存上限，也不包含解压器/网络栈/已复制到Dart的数据。安装的Dio5.11.1 handleResponseStream会预先订阅源并使用另一层controller，其接收超时计时和消费方取消/延迟订阅的语义仍需单独处理；本轮不篡改pub-cache、不扩大依赖升级。适配器暂停/订阅时限的新增验收直接调用HttpClientAdapter.fetch，不能当作Dio上层所有流消费路径已解决。全局连接闲置预算/定时清理、sendTimeout分阶段实现、Dio流包装、Android图片时延/内存峰值实测仍是后续项。不宣称图片速度提升比例。

图片调用链补充修复：DioHttpClient.fetchBytes原来接收所有状态码，非200直接抛http.ClientException，未关闭仍在接收的响应。现每次下载持有独立CancelToken，未完整读完响应（非200、进度回调抛错、传输错误）离开时取消请求，正常成功不取消；同时释放原有并发槽。新增仅供测试的双Dio注入构造，不改生产客户端选择、Cookie、并发通道或缓存策略。真实TCP服务返回403/200但故意不发完body，分别验证错误状态和消费者回调异常后连接关闭。

最终本地验证：最新真实FFI24项，以及图片队列/缓存9项，共33项通过，`/tmp/fluxdo-image-ffi.log`。网络模块常规回归174项通过、33项环境条件跳过，`/tmp/fluxdo-stream-network.log`（在随后新增图片用例前执行，跳过项中23项本地FFI已单独跑通；之后真实FFI新增图片用例并全部重跑通过）。不把公网7项和平台3项跳过计入通过。Android构建日志`/tmp/fluxdo-stream-apk.log`，最终增量重构建会单独记录以保证包含图片取消修复。

本批交付：最终三文件静态检查无问题，`/tmp/fluxdo-image-analyze-final.log`。首次Flutter打包在uploadCrashlyticsMappingFileRelease因SSLHandshakeException失败，自动重试仍走同一步，已停止本轮重试进程。最后直接使用同一工程Gradle assembleRelease及arm64/release参数，**仅本次命令用-x :app:uploadCrashlyticsMappingFileRelease跳过映射上传**，未修改正式构建配置；重新编译最新Dart代码后BUILD SUCCESSFUL，`/tmp/fluxdo-stream-apk-final.log`。测试包沿用本机debug签名回退，不能当作正式签名发布包。

独立APK：`build/app/outputs/flutter-apk/app-network-stream-fix-arm64.apk`，99,464,249字节，仅arm64-v8a；SHA256 `1df60099699d0896e4321ee612a60f3d065269a2a1fbac875eb848f139021322`。Cargo输出、jniLibs暂存、AGP合并产物逐字节一致；AGP裁剪后与APK内libfluxdo_net.so逐字节一致。旧`app-csrf-header-fix-arm64.apk`保留。没有安装手机、提交或推送；仍需沿用共存包更新方式保留登录态，在Android上对比图片密集列表、来回滚动与取消上传，观察日志、耗时与内存，不能以本地FFI测试代替真机性能结论。

## 2026-11-05 阿里云 DoH 图片慢：查询复用、直连选址与无模板 ECH

用户补充：Android使用阿里云DNS；本身可达的网络上关DoH也快、开DoH仍较快，慢时没有VPN/代理。因此不能把慢图简单归结为DoH固定开销，关注受限直连的选址、TLS与响应阶段。未使用审查skill/子代理，未修改系统网络配置。

确认与修复：

- **无浏览器模板时标准TLS漏注入ECH。** client.rs::tls_config(None,...)原来接收ech参数但完全不用；外层connect却把ech.is_some记为已启用。实际ClientHello回归在旧实现失败：外层SNI为linux.do，预期测试公用名ech.com，证据`/tmp/fluxdo-standard-ech-before.log`。现标准配置也调用BoringSSL set_ech_config_list；模板配置则使用BrowserEgress.ech_applied真实结果。平台证书校验保留。新增连接元数据echApplied和echAccepted，后一项读取完成握手后的ssl.ech_accepted()；随FFI/Dart连接信息和图片诊断透出。egress日志标注ECH requested，避免和实际注入/接受混淆。此缺陷会影响模板缺失时的冷启动，但尚未证明用户本次慢图一定发生在该分支。
- **相同实际DoH问题按原域名重复。** 六个映射到cloudflare-ech.com的域名各发A/AAAA/HTTPS，旧回归测到18次而非3次，`/tmp/fluxdo-doh-sharing-before.log`。新增按完整查询URL（包含服务商/查询名/类型）共享的响应缓存和弱引用查询锁。并发成功/失败共享；失败不持久缓存；首发者取消后等待者能接手。仅缓存有效NoError且正TTL的答案，按剩余TTL返回，条目最多1000；清缓存时换代，旧在途查询不回填共享缓存。原主机IP/ECH缓存和TLS SNI/证书身份保持各自域名。新增回复类型、ID、问题、截断和rcode校验，避免错误回复被写入共享结果或“无ECH”负缓存。
- **直连粘性IP可能已不在DNS答案中。** 改用preferred_host_ip_for_addrs，失效地址不再排头；有IPv4粘性地址时下一候选优先IPv6，避免连续两个IPv4把另一族推迟到第二次250ms之后。未调整并发数、TCP错开间隔、TLS超时或原有ECH回退策略。
- **图片阶段诊断。** fetchBytes记录queueMs、headMs、bodyMs、totalMs、字节数、状态、完成标记、协议及连接复用/ECH状态。只记录域名，不记录路径/查询串/Cookie/令牌；失败、总耗时>=1500ms或详细日志开启才落盘。事件为image_download_timing。核心新建连接额外记录解析与ECH准备耗时、候选数，后续可按域名/时间与TLS和图片事件对照。

参考：OkHttp DnsOverHttps按查询工厂接入DnsCache的做法；RFC8305的双栈候选交错。实现独立编写，不直接复制源码。
- https://raw.githubusercontent.com/square/okhttp/master/okhttp-dnsoverhttps/src/main/kotlin/okhttp3/dnsoverhttps/DnsOverHttps.kt
- https://www.rfc-editor.org/rfc/rfc8305.html
- ECH API与测试配置核对固定Rama提交23d59722的rama-tls-boring/src/tests/ech.rs以及本仓库browser_tls.rs测试；没有关闭证书校验。

本机只读证据（不是手机网络测量）：

- `/tmp/fluxdo-alidns-probe.json`：curl直发阿里云DoH，9个A/AAAA/HTTPS查询200，本轮总耗时约133～433ms。公共入口IPv4为104.18.10.118/104.18.11.118，cdn.ldstatic.com与cdn3的原生记录为104.26.2.74/104.26.3.74/172.67.70.20；只能说明选址不同，不能据此判定哪个在手机上更优，未自动切换公共ECH入口策略。
- 新增只读诊断例程`core/net_core/examples/doh_probe.rs`，默认使用生产Rust DoH传输测冷/暖解析，`--connect`额外读取两个公共CDN的/cdn-cgi/trace。只打印状态/字节数/耗时，不输出trace中的公网IP。运行`cargo run --manifest-path core/net_core/Cargo.toml --example doh_probe -- --connect`。
- `/tmp/fluxdo-alidns-core-probe.log`：三个映射域名冷解析139～150ms，暖解析记录为0ms（毫秒精度）。
- `/tmp/fluxdo-alidns-ech-probe.log`：最终标准TLS无模板路径对两个CDN均完成ECH accepted=true。cdn3返回HTTP200且完整206字节约749ms；cdn完成TLS约605ms后等响应头8秒超时。说明本机也存在DNS/握手之后的延迟，不能宣布所有慢图根因已解决；该trace路径也不是实际图片吞吐测试。

验证：Rust58项通过（查询共享/失败共享/缓存老化与服务商隔离/异常回复/首发者取消/粘性地址与双栈顺序/实际ClientHello ECH注入），`/tmp/fluxdo-doh-final-rust.log`；最终macOS核心与Android arm64核心构建通过，`/tmp/fluxdo-doh-native-final.log`、`/tmp/fluxdo-doh-android-native.log`；真实FFI24项+图片队列/缓存9项共33项通过，`/tmp/fluxdo-doh-ffi.log`，含FFI传出的明文HTTP ECH状态为false。两文件静态检查无问题，`/tmp/fluxdo-doh-analyze.log`。本轮未重复公网冒烟整套或登录验收。Android APK正在本地构建，日志`/tmp/fluxdo-doh-apk.log`，沿用单次-x跳过Crashlytics映射上传而不修改正式配置。

下一步真机：保留阿里云DNS和当前ECH入口策略，无VPN/代理，在“慢”的实际网络上冷启动后打开多图话题、再回看同一批图片，导出日志。用image_download_timing判断排队/响应头/响应体阶段，再看对应连接的解析耗时、fingerprint template/standard、ECH applied/accepted及握手重试。不要先调高并发或把本机成功当作手机受限网络已验收。全局闲置池、Dio上层流生命周期与sendTimeout等前轮后续项仍未完成。

本批APK已完成：`build/app/outputs/flutter-apk/app-doh-image-fix-arm64.apk`，99,497,017字节，仅arm64-v8a；SHA256 `c35eddbebd4eaa78ea152afe0919a76921df3b8d37d91fa708c50171edbe05d2`。`/tmp/fluxdo-doh-apk.log`记录BUILD SUCCESSFUL（4m52s）。Cargo/暂存/AGP合并核心一致，AGP裁剪后与APK内核心一致，APK生成时间晚于最终源文件；先前两个独立测试包保留。沿用本地测试签名及共存包更新方式。未安装设备、提交或推送。

## 2026-11-05 原计划核对与 H3 收尾

[原计划核对表](network-plan-audit.md) 明确：核心迁移主干已实施，但 sendTimeout、无模板平台内置档、WebView 本机 CA 密码学校验没有完全按原计划落地；多端与长期/账号验收也未完成。

本轮源码增加 H3 最多双地址（另一协议族优先、250ms 备用）、直接读取 BoringSSL ECH 接受状态、连接 ID 经 FFI 与 Dart 请求/图片元数据透传。日志整理和上述源码改动尚未生成新 APK；不可用旧包验收这些新行为。验证：67 项 Rust 全量、随后 4 项 H3 专项、5 项 Dart 相关测试及两文件静态检查通过。没有提交或推送。

Android arm64 最终原生 release 编译通过（1m06s，无警告）；本轮未重新生成 APK。

## 2026-11-05 WebView 信任与上传时限

后续头像修复已独立落入本地 dev：`51f9a813`，再 cherry-pick 为 `f1d83ed3` 到 `codex/network-core-optimization`。此前此目录实际上处于 dev 且网络改动未提交，因此先创建网络分支保留工作区。两边分别通过 14 项头像/站点设置回归；全改动静态检查只有 dev 原有聊天页 prefer_is_not_empty 提示，最终通知缓存及辅助类检查无问题。带回提交前后原网络 diff 与 458 个未跟踪文件逐字节一致。未推送，旧 APK 不含这次头像修复。

继续网络任务应明确使用 `/Users/pengyongteng1/m/fluxdo`。临时 dev 测试工作树 `/Users/pengyongteng1/.codex/worktrees/avatar-size-fix/fluxdo` 已干净并 detached；Codex 将其标为当前主工作区，archive_worktree 因保护规则拒绝移除，attach_worktree 也不支持切回非 managed 的原始目录，因此未强删该工作树。

- WebView 不再按 issuer CN 或缺失字段放行；原始 DER 交当前运行核心配置的 CA 校验签名链、有效期、主机名/IP。缺少 DER、接口不可用或验证失败返回 null，由平台正常验证。已核对当前 Android/iOS 插件默认处理代码；不安装新 CA，不改变设备/内置 CA 偏好。
- 新增可选 FFI `fluxdo_net_verify_webview_certificate`。旧核心缺少此符号时仅拒绝额外信任，不影响其他网络绑定。限制 DER 64 KiB、主机 253 字节、JSON 100 KB。
- sendTimeout 对齐 Dio IO：连接池/解析/TLS 不占上传预算，从连接就绪到传输层消费完请求体计总时限，不按每块续期；不代表服务端已收到最后一字节。发送后等待响应切换为 receiveTimeout；服务端提前响应优先处理，超时沿已有路径释放上传订阅。
- GET 与未设置 sendTimeout 的请求不分配新增计时通道，无轮询或额外网络探测。证书验证仅发生在 WebView 信任回调，不添加图片请求前置检查。
- 对照来源：[Dio IO 适配器](https://raw.githubusercontent.com/cfug/dio/main/dio/lib/src/adapters/io_adapter.dart)，以及本机 dio 5.11.1 的 addStream / future.timeout 实现。
- 初次验证：70 项 Rust、真实本地 FFI/证书回调 31 项通过，覆盖新生成的两份同名 CA、错误主机、缺失证书、核心关闭、停滞上传和发送后慢响应。最终构建及验证记录随后补充；账号场景仍留人工验收。

最终源码验证：70 项 Rust 全通过（`/tmp/fluxdo-trust-upload-rust.log`），最终 macOS 动态库构建后真实 FFI/证书回调 31 项全通过（`/tmp/fluxdo-trust-upload-ffi.log`），5 文件静态检查无问题（`/tmp/fluxdo-trust-upload-analyze.log`）。Android arm64 release 原生核心构建成功，耗时 1m17s（`/tmp/fluxdo-trust-upload-android-native.log`）。

统一测试包：`build/app/outputs/flutter-apk/app-network-complete-arm64.apk`，102036537 字节，仅 arm64-v8a，SHA256 `a187756eaae8ecb7bdf00726e93d5741c8fbe93fe494d23133206a717345a3f1`。完整构建 6m58s 成功（`/tmp/fluxdo-trust-upload-apk.log`），核心暂存与 merged native 一致、stripped native 与 APK 一致，包内确认新证书校验符号。模拟器覆盖安装成功、冷启动首页及头像可见，主站 H3 升级成功，CDN H2 ECH accepted=true；ping 的 H3 探测超时后保留 TCP 并退避。启动日志 `/tmp/fluxdo-trust-upload-emulator.log`，截图 `/tmp/fluxdo-trust-upload-home.png`。这是模拟器冒烟，不代表真机性能或账号场景验收；未提交或推送。


## 2026-11-05 Dio 流生命周期与重定向完善

继续在 `/Users/pengyongteng1/m/fluxdo` 的 `codex/network-core-optimization` 工作。头像提交已单独推送 dev；网络迁移仍未提交、未推送。

- 先用 Dio 公开接口复现上层提前订阅、消费者取消不传递两项缺陷：`/tmp/fluxdo-dio-lifecycle-before.log`。此前适配器直接调用的回归不能覆盖这一层。
- pub.dev 最新稳定仍为 5.11.1，上游 main 也仍有同一实现。项目内 `third_party/dio` 固定同版本，仅修改 `response_stream_handler.dart`，保留 LICENSE、上游版本及原始源码 SHA256 清单；没有修改 pub-cache。没有添加二进制库。
- 改为消费者订阅后读源；暂停停表、恢复沿用剩余预算；取消、超时、进度回调异常会关闭响应并取消源；正常完成后清除取消回调引用，防止共享长寿命 CancelToken 留住响应。上游真正停滞依旧超时。
- 重定向使用完整 RequestOptions 保留 CancelToken、超时、编码器和进度回调；相对 Location 不重复旧查询；301/302 POST 与 303 非 HEAD 转 GET 并清除实体头，307/308 保留可重放内容，FormData clone，一次性 Stream 不重放、不静默发空请求。OTP 的 skipRedirect/skipCsrf 豁免保留。
- 跨源移除授权、CSRF、User-Api-Key 等源站头，并禁止下一跳重新注入 CSRF；Cookie 仍按目标 URL 重取。仅跟随无 userinfo 的 HTTP(S) 地址，遵守调用方上限且最高 10 跳。
- 重定向流：已知长度不超过 8 KiB 的响应最多用 100ms 排空，实际超过预算仍停止；其余立即取消。避免无限 drain，也尽量保留 HTTP/1.1 连接复用。真实核心已验证小响应后下一跳 connectionId 相同、reused=true。
- 图片日志增加 `redirectHops`（域名、状态、每跳耗时、请求/连接 ID、协议、连接与首字节时间），不含路径和查询串。保持整条 traceId，各跳独立 attemptId；最终连接也带 connectionId。`headMs` 仍是包含所有跳转的总响应头等待，不能直接减最后一跳 ttfbMs 后归因为 Dart 卡顿。

参考与维护说明：
- https://pub.dev/packages/dio/versions/5.11.1
- https://github.com/cfug/dio/blob/main/dio/lib/src/response/response_stream_handler.dart
- https://www.rfc-editor.org/rfc/rfc9110.html#name-redirection-3xx
- https://github.com/golang/go/blob/master/src/net/http/client.go
- https://github.com/square/okhttp/blob/master/okhttp/src/commonJvmAndroid/kotlin/okhttp3/internal/http1/Http1ExchangeCodec.kt

本轮验证：
- 先通过 34 项真实 FFI/证书测试，含公共 Dio 的延迟订阅、暂停与小重定向连接复用；日志 `/tmp/fluxdo-redirect-ffi-final.log`。
- 全量首次发现 3 个 CF widget 回归失败。对照上游原文件全部通过（`/tmp/fluxdo-cf-lifecycle-upstream.log`），确认是补丁正常 EOF 时重复等待源取消导致完成时序变化；改为正常完成不再次取消源，CF + 流 10 项通过（`/tmp/fluxdo-cf-lifecycle-fixed.log`）。没有把失败归咎于环境或跳过。
- 最终完整网络、图片及头像回归 **257 项通过、3 项 Windows 条件跳过**，包含真实 FFI；`/tmp/fluxdo-network-verified.log`。未运行依赖公网的 net_core_live_test，不把公网可用性记为通过。
- 7 文件静态检查无问题，`/tmp/fluxdo-redirect-analyze-final.log`；diff --check 通过；按原始摘要核对 Dio 仅一个源码文件不同，LICENSE 完整相同。本轮没有改 Rust，无需重复原生 70 项测试证明同一源码。
- Android 包构建中，日志 `/tmp/fluxdo-redirect-apk.log`，沿用单次跳过 Crashlytics 映射上传，未改正式构建配置。

不把本地网络和流控制验证等同 Android 真机提速幅度；模板内置档、30 分钟 MessageBus/后台切网、多端构建和同场景资源基准仍未完成。


## 2026-11-05 预置模板与 beta 收尾

用户明确要求补齐 Claude 计划的预置模板，并授权「工作完成后提交、推送并打 beta tag」。此前“网络迁移暂不推送”限制已被这次授权替代；头像仍是单独的 dev 修复。

- 原生预置 10 档：Android WebView 133 / Android Chrome 149、Windows Edge 152/153/154、iOS Safari 17/18/26、macOS Safari 18/26。平台与内核先匹配，再取最接近大版本；未知版本取平台最新档，已知不匹配内核不硬套。
- 实际 WebView 采样与 UA 一致的磁盘缓存优先。预置单独存放，不写成真实采样，不让 ready=true 抑制探针。采样完成后 generation 改变，新请求切换连接身份；在途响应不强制中断。缓存最多读取 256 KiB，损坏/过大/UA 变化均忽略并用后备。
- 数据仅约 40 KiB 量级，编译进核心，只解析选中的一个档；无额外下载、服务、隐藏 WebView 或运行期随机切换。仅应用当前 UA，不将样本设备 UA 发出。清理 SNI、ECH 密文、票据、key-share 公钥；真实握手由 BoringSSL 重建。
- 完整来源、固定提交和摘要见 core/net_core/presets/manifest.json，许可随目录。Rama legacy 数据各字段有观测但不能证明来自同一连接；Android Chrome/Windows Edge 是同内核后备，不能声称等同实际 WebView/WebView2。curl-impersonate Safari 26 使用完整 TLS/H2 签名，导航头不充当 fetch 头。线上 Safari 27 文件标注 partial，未推测补齐缺失字段。Linux WebKitGTK 仍待真实样本。
- 模板来源经 Core status/Dart NetCoreStatus 暴露，连接日志显示实际 preset ID/cached/sampled/standard。采样完成同步刷新状态；有预置可用时 UI 不把核心标成不可用或一直预热。
- 探针按代次合并；切网先取消并销毁旧探针，再启动新探针；旧完成结果不覆盖新状态。运行与状态响应体都有超时。

验证：Rust 74 项全通过（/tmp/fluxdo-presets-rust.log），包括 10 档真实 ClientHello 发出、TLS 配置构造、采样替换、UA 升级、损坏缓存、预置不落盘。探针与配置 5 项 Dart 通过，6 文件静态检查无问题。macOS 新核心构建并复制、Android arm64 release 核心构建成功，日志 /tmp/fluxdo-presets-{macos-native,android-native}.log。最终网络/真实 FFI/日志/MessageBus 策略/图片/头像 **291 项通过，3 项 Windows 条件跳过**（/tmp/fluxdo-beta-network-tests.log）。未把条件跳过、公网或人工账号验收计为通过。

前一批（无预置）APK 已保存为 build/app/outputs/flutter-apk/app-network-redirect-arm64.apk，SHA256 3c71992fd3a426b2ed0f6494e699821c7856f649f50731b0475dad25e8f3c912。它包含头像及 Dio/重定向修复，但不能用于验证预置模板。包含预置的最终包仍在构建，日志 /tmp/fluxdo-presets-apk.log。


### 最终 Android 包与冷启动冒烟

- 最终构建成功（3m41s），APK：build/app/outputs/flutter-apk/app-network-presets-arm64.apk；SHA256：2c74229867bc7f9f88a5caaa506f53ad84d5aee1f207398a9a278e752dda1fde。包含预置模板、Dio 流生命周期与重定向修复及头像尺寸修复。
- APK 内原生库与 Gradle stripped_native_libs 摘要一致（d5407b6c46e4468eda439658ae9dc6e4d7188f061411c38421b0cf6fb9ec962b）。
- emulator-5580 覆盖安装成功，保留账号与应用数据，仅把旧 fingerprint_template.json 重命名备份。20:50:49 日志确认 builtin android-webview133 可用，20:50:50 探针完成，随后主站连接使用 sampled，首页列表和头像正常显示。证据：/tmp/fluxdo-presets-android-smoke.log、/tmp/fluxdo-presets-android-smoke.png。此环境使用 DNSPod DoH，不能替代用户阿里云 DoH 真机速度验收。
- 最后两文件静态检查无错误，有 platform_adapter.dart 两处现有单行 if 的括号风格提示；未把它们宣称为无提示。完整功能回归结果仍为 291 通过、3 条件跳过。
- 发布范围：本轮网络实现和相应验证、来源、维护文档；排除 .openidea/、test/_probe/、标注“不入库”的 docs/network-egress-core-plan.md。beta 标签计划使用 v0.2.30-beta.5，远端推送结果以实际 Git 记录为准。

提交前暂存检查：617 个文件，包含完整 vendored Rama QUIC 源码与许可证，不含原生构建产物、私钥、临时探针或个人配置。diff --check 仅在原样保留的上游 Safari YAML 与 Dio README 中发现 5 处尾随空格；其余文件通过。保留来源文件字节，避免破坏来源摘要核对。
