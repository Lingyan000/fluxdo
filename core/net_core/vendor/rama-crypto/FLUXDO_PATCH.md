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
  支持 Java 检查器的提供者沿用原路径；非 BoringSSL 构建保持无法验证即拒绝。
- `android_ocsp.rs` 只把平台已验证的证书链材料转入本地验证，不改变系统信任结论。
- 名称、期限、用途、信任链、应用证书策略、ECH 和失败重试策略不变。
- 其他平台源码不变。

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
