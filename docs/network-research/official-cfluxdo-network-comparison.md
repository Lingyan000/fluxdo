# 官方 iOS 与 CFluxDo 网络实现对照

2026-11-06，只读源码与二进制核对。没有在同一台 Android 真机上完成三款应用的网络对照，不能据此宣称已定位或解决用户的慢图现象。本轮没有改动网络运行逻辑，也没有推送。

## 固定样本

- CFluxDo：1.2.2-beta.9，`fa4b92d29e533cd7aa69b2a136a8f8b0400b161d`。默认 main 是较早正式版，本次没有用 main 代表最新 beta。
- 它锁定的 fluxdo_doh：`9efbcc65f9c541753b98d4bf6d89b5fa85cc5f4f`。
- 官方：本地 LINUX DO iOS 1.0.4 build 9，主程序 SHA256 `b68f916172e491437d0c6878b248c6e887020ea9cde3b65c80136fa3c0a76bc7`，本轮重新校验一致。不是官方 Android APK。
- FluxDO：网络分支 `eeacc0dd` 加本地头像修复；本轮没有修改 Rust 核心。

## 关键差异

| 方面 | 官方 iOS 样本 | CFluxDo beta.9 | 当前 FluxDO |
| --- | --- | --- | --- |
| 普通图片 CDN 入口 | 非 linux.do 域名进入系统 URLSession | Dart IO → 本地 Rust gateway，DoH 模式可参与边缘优选 | 统一网络核心；DoH/ECH/连接池覆盖图片请求 |
| DoH | 自定义 curl 路径实际设置 CURLOPT_DOH_URL | 公共 DoH 搜集 CF 候选，再实测选址；另有加速路由表 | 合并重复查询、TTL 缓存、A/AAAA/HTTPS 查询及成功地址记忆 |
| ECH 与图片域 | 不能把主站 curl 路径结论套用到普通 CDN | ldstatic.com 及子域共用优选赢家与 ECH | 默认策略已将 linux.do、ldstatic.com 映射到 cloudflare-ech.com 查询；并非遗漏图片域 ECH |
| H3 | 自定义 curl 配置允许 H1/H2/H3 Alt-Svc；不等于 CDN 实际使用 H3 | 默认 gateway 上游池实现 H1/H2，不能将可选 rhttp 的 all 协议配置当默认 H3 实测 | 已实现有界 Alt-Svc H3 后台升级、失败退避及连接复用 |
| 更值得借鉴的差距 | 系统图片传输路径值得作为诊断对照 | 实际 TLS + HTTP 验证候选节点，持久化并在失败/换网时更新 | 尚无对应的跨候选主动边缘优选；已有地址 RTT 排序和成功地址缓存不能等同于它 |

## CFluxDo 已确认的实现及限制

1. `network_settings_service.dart:364`：本地优选要求 Android/Linux/Windows、DoH 开启、无应用上游代理且 gateway 可用。默认选择模式为 localAtlas；rhttp 默认关闭。
2. 同文件 `:981`：extraCoveredHosts 明确包含 ldstatic.com。Rust `edge_pin.rs:184` 按完整域名或带点子域匹配；`dns.rs:2153` 在覆盖域名优先返回赢家 IP，现成路由表地址补作候选；`:1940` 优先使用选择器 ECH 配置。
3. `select.rs` 从持久化赢家、atlas、公共 DoH 解析的 CF 域名与 CF 网段样本收集候选。`probe.rs:345` 执行 TCP、TLS/ECH、GET /cdn-cgi/trace，并检查 HTTP 200 和正文 h=目标主机。不是只做 ping 或 TCP 延迟排名。
4. 重要限制：选择器的 PROBE_INNER_SNI 固定 linux.do。它把该赢家用于图片域，并没有逐个 CDN 实测头像响应速度。可用性和下载速度仍需按真实图片域验证；短 trace 也不代表大图吞吐。
5. `select.rs:40` 等处：探测并发 8、候选最多 32、竞速窗口 4 秒，首次成功后最多追加等待 400ms，成功 4 个即收敛并取消剩余任务。自动竞速最短间隔 60 秒、每小时最多 4 次；网络变化防抖 1.5 秒。候选收集和慢网复核另有时限，不能把 4 秒当总启动上限；冷启动 lookup 最多等赢家 4 秒。
6. 候选域名收集的并发 6 不等于全部 DNS 网络请求并发 6：`public_query` 对每条查询会再向多家端点并发竞速，A/AAAA 也并行。照搬会扩大启动开销与外部请求范围。社区 atlas/cfhub 是额外服务依赖；测量上报默认关闭。
7. `upstream_pool.rs` 使用跨回环连接共享的 H2 池、冷建连共享、H1 复用、按网络代数作废。配置为每 key 最多 3 条 H2、64 流软阈值、H1 空闲最多 4 条，H2 空闲仍发 20 秒 PING，接收连接窗口 32 MiB。窗口是流控配置，不是预分配内存证明；这些参数也不是适合我们的性能结论。
8. 默认网关以 H1/H2 建连；rhttp 是用户可选路径，虽设置 HttpVersionPref.all，也不能据此说整个应用靠 H3 解决了慢图。
9. beta.8 发布说明明确承认：修了错误提示与重复失败路径造成的白等，仍没有解决部分地区为何连不上服务器边缘节点。因此结论是“有值得参考的实现”，不是“已经证明解决相同症状”。

固定源码：
- [Flutter 配置与图片域覆盖](https://github.com/1molchuan/CFluxDo/blob/fa4b92d29e533cd7aa69b2a136a8f8b0400b161d/lib/services/network/doh/network_settings_service.dart#L981)
- [选择器与预算](https://github.com/1molchuan/fluxdo_doh/blob/9efbcc65f9c541753b98d4bf6d89b5fa85cc5f4f/src/select.rs)
- [实际探测](https://github.com/1molchuan/fluxdo_doh/blob/9efbcc65f9c541753b98d4bf6d89b5fa85cc5f4f/src/probe.rs#L345)
- [连接池](https://github.com/1molchuan/fluxdo_doh/blob/9efbcc65f9c541753b98d4bf6d89b5fa85cc5f4f/src/upstream_pool.rs)
- [beta.8 作者说明](https://github.com/1molchuan/CFluxDo/releases/tag/1.2.2-beta.8)

## 官方二进制补充复核

此前完整图片分流证据见 [official-ios-image-pipeline.md](official-ios-image-pipeline.md)。其中“当前 FluxDO”一节是当时快照，已有后续改动，不能代表本轮状态。

本轮直接复核 CommunityFoundation 反汇编：
- `0x3778c` 与 `0x47028` 设置选项 0x2827，随后调用 curl_easy_setopt；错误字符串同样是 CURLOPT_DOH_URL。确认解析和请求配置路径确有 DoH 接线，不是仅有库符号。
- `0x35044–0x3506c` 设置 curl multi 每主机最大连接数 6、连接缓存参数 50。后者不是全局同时活动连接硬上限。
- `0x46c68–0x46c7c` 设置 CURLOPT_ALTSVC_CTRL 为 0x38（H1/H2/H3）。这仅确认配置允许值；curl 文档说明未编译对应协议时相应位会被忽略，不能只凭此断言实际协商 H3。
- 主程序 `0x100149ca0` 附近有 DoH 探测请求、application/dns-message 响应检查和耗时统计，后续有 task group；尚未完整恢复调用者与生产选址策略，不能称为“自动择优 DNS”或“多 DNS 生产竞速”。
- 主程序图片入口 `0x10009cd18` 调用 usesCustomTransport，普通 CDN 非命中走 SystemURLSessionTransport；共享 URLCache 和 TLS session 持久化证据仍见前文。自定义 curl 优化不能直接解释普通 CDN 图片速度。

没有确认：官方 Android 的实现；官方普通 CDN 运行时最终协议、重定向每跳路径；生产 DoH 是否有应用自建重复查询合并或跨提供商自动优选。这些不以符号名称或库自带能力补全。

选项语义依据：[DoH](https://curl.se/libcurl/c/CURLOPT_DOH_URL.html)、[Alt-Svc](https://curl.se/libcurl/c/CURLOPT_ALTSVC_CTRL.html)、[每主机连接限制](https://curl.se/libcurl/c/CURLMOPT_MAX_HOST_CONNECTIONS.html)。

## 下一步范围

优先检验“当前选址得到的边缘在真实头像域是否可用/快速”，而非继续扩大下载并发。对同一图片及缓存状态记录实际远端地址、DNS/TCP/TLS/首字节/下载耗时和复用状态，对照默认 DoH 路径与少量已验证候选。主站成功不能代替 CDN 成功，代理快也不能单独证明 DNS 慢。

若引入优选，应保持明确的候选、并发、时间、流量和缓存预算；先利用已有地址与成功记录，不直接引入第三方社区服务依赖或全厂商竞速，不静默绕过用户选择的 DoH。健康连接继续复用，失败和网络变化再触发更新；按目标图片域验证并保留标准证书校验。该方向仍需真机证据，不能提前承诺速度改善。
