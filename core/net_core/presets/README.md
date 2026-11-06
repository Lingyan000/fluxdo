# 网络预置模板

自动模式优先真实采样和缓存，预置用于启动后备。网络设置也允许用户指定任一预置档，固定用于核心 TLS/HTTP2 请求；手动档不读写自动缓存、不启动采样探针、不被后续采样覆盖。切回自动恢复原缓存。切换会重建核心。宿主 UA、WebView 自身指纹不改变，QUIC 行为不属于这些模板。不能保证减少 CF 挑战。

- Android：本机 WebView 133 实际探针、Rama Android Chrome 149 样本；后者为同内核浏览器后备，并非 WebView 149 采样。
- Windows：Rama Edge 152/153/154，同 Chromium 内核后备，并非声称逐字匹配 WebView2。
- iOS：Rama Safari 17/18 + curl-impersonate Safari 26；macOS：Safari 18/26。都是平台内样本，不跨苹果平台混用。
- Linux WebKitGTK 没有可核验样本，保持标准 TLS 后备；等待真实采样。不能用 Linux Chrome 或 macOS Safari 冒充。

来源固定 Rama 23d59722e125fb6f2de66df588f772205318e555 的 rama-ua/src/profile/format/legacy/tests/browser_profiles.json；manifest.json 保存来源行、版本和 SHA256。上游 legacy 格式记录各项观测，但不能证明 TLS/H2/头来自同一条连接；这里只作近似后备。许可证随目录保留。

提取仅保留 TLS 能力、H2 早期帧与伪头顺序、fetch 头名顺序和 Accept-Encoding。SNI、ECH 密文、会话票据、key-share 公钥已清除/置零，握手时由 BoringSSL 重新生成；不带 Cookie、授权或采样设备 UA。

更新时应加入真实采样及来源摘要，更新 manifest 和 src/presets.rs 的索引，运行全部预置解析/TLS 构造、匹配、采样替换和缓存隔离回归。不要手改版本号制造不存在的样本。


追加来源：curl-impersonate 5b1c3542fc7fc0e9fe623a6c9a848d16f92fe99a 的 tests/signatures/safari_26.0_iOS.yaml，完整冷连接 TLS/H2 签名，原 YAML 和 LICENSE-curl-impersonate 已保留。导航头不当作 fetch 头，因此该档 fetch_header_order 为空。公开库还包含 Safari 27，但其测试 YAML 标注 partial，缺失字段不在此次转换时推测补齐。

线上对照：https://curl-impersonate.readthedocs.io/en/latest/fingerprints.html 、https://github.com/bogdanfinn/tls-client/blob/master/profiles/profiles.go 、https://github.com/refraction-networking/utls 。uTLS 的 ClientHello 预设不包含完整 HTTP/2 行为，因此不是本仓库模板格式的直接替代。
