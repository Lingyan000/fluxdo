# Android 可选撤销检查兼容补丁

上游：`plabayo/rama`，固定提交 `23d59722e125fb6f2de66df588f772205318e555`。
除展开 workspace 清单与此处列出的补丁外，保留上游源码及许可证。

## 问题与版本关系

FluxDO 0.2.29 使用 Cronet/Cupertino/Dart IO、旧网关或可选 rhttp；
0.2.30 的 `eac274bd` 引入统一 Core，使用此版本的 Android 平台校验器。
在名称、有效期、用途、系统 TrustManager 校验通过后，上游会对符合条件的证书
调用 `CertPathValidator.getRevocationChecker()`。它只检查 SDK >= 24，
没有检查当前 PKIX 提供者是否实现该可选接口。

Android 官方 BouncyCastle 提供者映射到 `PKIXCertPathValidatorSpi`，没有覆盖
`engineGetRevocationChecker()`；Java SPI 默认实现抛出
`UnsupportedOperationException`。原 JNI 代码将异常直接转换为证书校验失败。

证据：

- [Android PKIX 提供者映射](https://android.googlesource.com/platform/external/bouncycastle/+/refs/heads/main/bcprov/src/main/java/org/bouncycastle/jce/provider/BouncyCastleProvider.java)
- [Android PKIX 实现](https://android.googlesource.com/platform/external/bouncycastle/+/refs/heads/main/bcprov/src/main/java/org/bouncycastle/jce/provider/PKIXCertPathValidatorSpi.java)
- [可选接口默认抛出不支持异常](https://android.googlesource.com/platform/libcore/+/refs/heads/main/ojluni/src/main/java/java/security/cert/CertPathValidatorSpi.java)
- 本地执行 Android 15 `android-all:15-robolectric-12650502` 中的真实提供者，
  确认 `getRevocationChecker()` 抛出该异常。该验证运行于宿主 JVM，不等于真机网络复现。

这是已证实的升级后误拒绝条件，但尚不能独立解释 issue #433 的 Wi-Fi/蜂窝差异。
是否命中该用户仍需新日志；不能据此关闭 issue。

## 改动范围

- `android_revocation.rs`：通过真实 JNI 调用探测能力，只将
  `UnsupportedOperationException` 识别为“不支持”；其他异常保留。
- `android.rs`：系统校验已成功、无 OCSP staple 且补充接口不支持时，
  清除已处理的 Java 异常并跳过补充检查，记录明确警告。
- 存在 staple 且提供者不支持时，BoringSSL 构建改走本地验证，只有完整验证成功才放行。
  `ocsp_verify.rs` 使用已有 yasna/x509-parser 解码，BoringSSL 验签，不引入其他加密库。
  校验 CertID 的序列号与签发者摘要、响应者身份/授权、签名算法参数、响应时间和状态；
  受委托响应者必须由可信链中的直接签发者签发，并具有 OCSPSigning 用途。
  自带证书不能充当信任锚点；revoked、unknown、未知关键扩展和无法验证的数据均拒绝。
  支持 Java 检查器的提供者继续校验 staple；非 BoringSSL 构建保持无法验证即拒绝。
- `android_ocsp.rs` 只把平台已验证的证书链材料转入本地验证，不改变系统信任结论。
- 名称、期限、用途、信任链、应用证书策略、ECH 和失败重试策略不变。
- 其他平台源码不变。

## 无 OCSP 地址的补充校验（2026-11-17）

beta.7 用户历史日志明确出现 `Certificate does not specify OCSP responder`。
这不同于可选 API 不支持：真实 Java PKIX 校验器把缺少地址归为 UNSPECIFIED，
仅配置 SOFT_FAIL 不能容忍它，因为 SOFT_FAIL 只处理 UNDETERMINED_REVOCATION_STATUS。

平台信任链、域名、期限、用途校验仍先执行。随后读取叶子证书 AIA 中真正的
id-ad-ocsp URI，不把 caIssuers/CRL 地址当作 OCSP 入口，损坏或重复 AIA 拒绝。
无 staple 且无 OCSP 地址时使用 ONLY_END_ENTITY + PREFER_CRLS + NO_FALLBACK + SOFT_FAIL：
保留 CRL 吊销校验，仅在无法获取撤销状态时软失败，不再尝试不存在的 OCSP 地址。
有 OCSP 地址沿用原网络查询策略；有 staple 仍强制验证，不允许 CRL 或软失败覆盖响应拒绝。
增加 tls_revocation_crl_only 与 tls_revocation_rejected（含 stapled/阶段），不记录证书原文或查询地址。

本地真实 JVM 对照可复现上述同名错误；生产 JNI 选项修复后无入口/有效 CRL 通过，
吊销 CRL、吊销/未知/错误签名/损坏 staple、过期证书仍被拒绝。CRL 由本地 CertStore 注入，
证书/CRL/OCSP 由 OpenSSL 生成，测试不依赖网络。它不等同于用户设备/ROM 的现场复测。

## 握手中不再在线查询吊销（2026-11-20）

真机日志对照：同一设备完整握手 283–599 ms，会话恢复握手（跳过证书校验）222–229 ms，
不做在线吊销查询的同类客户端完整握手均值 216 ms。linux.do（GTS WE1）与
ldstatic（Let's Encrypt）证书已不提供 OCSP 地址，上一节的策略因此在每次完整握手中
同步下载 CRL（明文 HTTP，实测 0.3–1.0 s）；该地址不可达时又回到 #433 的误拒绝来源。

现策略：系统 TrustManager、名称、期限、用途校验不变；未装订 OCSP 时不再联网取
CRL/OCSP，直接放行已通过系统校验的链（与 Android 系统 TLS、Chrome、Cronet 一致）；
服务器装订的响应仍严格验证（ONLY_END_ENTITY + NO_FALLBACK，不软失败、不回退 CRL），
提供者不支持检查器时走本地验证。随之删除系统根判定、OCSP 入口探测与 CRL-only 分支。
上两节的「无 staple 时」描述仅为历史记录。
Windows 同步改为 `CERT_CHAIN_REVOCATION_CHECK_CACHE_ONLY`（只用系统已缓存的吊销信息），
与 Chromium `cert_verify_proc_win.cc` 未要求在线吊销检查时的做法一致。

## 可执行验证

Linux 的 `cargo test --locked --lib` 包含真实 JVM/JNI 回归，需要 Java 运行时包含
`jdk.compiler` 模块，并可通过 `java` 和 `JAVA_HOME` 或系统安装路径找到 JVM。
测试直接加载生产能力探测和 OCSP 桥接模块，覆盖“不支持、真实异常、可用”及 staple 边界。
OpenSSL 在临时目录生成并独立验证正向响应；29 组响应还覆盖撤销、未知状态、错误签名、
错误证书、同名伪造 CA、无授权/过期响应者、关键扩展、RSA-PSS 参数和损坏编码。
另测过期/未来/无 nextUpdate 旧响应，并逐字节截断和翻转响应验证解析失败边界。
此测试需 `openssl`、`python3`，不访问外部 OCSP 服务，不安装测试证书，临时私钥测试后删除。

已有公开 Android 15 系统 JAR 时，可在上述 `cargo test` 前设置
`FLUXDO_ANDROID_ALL=/path/to/android-all-15-robolectric-12650502.jar`，
以实际 Android BC 提供者再次执行同一组 JNI 回退用例；常规 CI 不下载这个大文件。

另可下载上述公开 Android 系统类到仓库外，然后执行：

```sh
java -cp /path/to/android-all-15-robolectric-12650502.jar tests/AndroidRevocationProbe.java
```

预期输出为 `provider=BC`、实际 PKIX 实现类名及
`confirmed=java.lang.UnsupportedOperationException`。此探针不联网、不读取用户证书。

上游修复后可删除本地补丁，恢复固定版本依赖；不要同时升级其他网络组件。
