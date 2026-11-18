# 开发环境与日常命令

## 分层约定

- `melos`：仅用于 workspace bootstrap
- `just`：本地开发者入口，定位接近 `npm run`
- `tool/*.dart`：真实脚本实现，也是 CI / IDE / 自动化调用入口

## 快速开始

1. 初始化 workspace：

   ```bash
   melos bootstrap
   ```

   如果没有全局 `melos`，可改用：

   ```bash
   dart run melos bootstrap
   ```

2. 安装 `just`：

   - Windows：`winget install --id Casey.Just --exact`
   - Windows：`scoop install just`
   - Windows：`choco install just`
   - 通用：`cargo install just`

3. 显式同步项目状态：

   ```bash
   just sync
   ```

4. 运行应用：

   ```bash
   just run -- -d windows
   just run -- -d macos
   just run -- -d linux
   just run -- --dart-define=cronetHttpNoPlay=true
   ```

如果你不想安装 `just`，可以直接调用 Dart 入口：

```bash
dart run tool/project_prep.dart app
dart run tool/flutterw.dart run -d windows
```

## Flutter SDK 与 UI 包

项目通过 `.fvmrc` 固定 Flutter 3.50.0（Dart 3.14）。使用 FVM 时，在仓库根目录执行
`fvm use --skip-pub-get`，再运行 `just sync` 或 `just run`。`just` 按 `.fvmrc` 选择
`.fvm/versions/<版本>/bin` 下的 Dart 和 Flutter。切换分支后若提示缺少对应版本，再执行一次
`fvm use --skip-pub-get` 即可。没有本地 `.fvm` 目录时，`just` 使用 `PATH` 中的 SDK，其版本需与项目匹配。

应用、公共 UI 包与 `fluxdo_render` 使用独立的 `material_ui` / `cupertino_ui`。
主窗口和小程序启动窗口通过官方兼容桥为尚未迁移的第三方组件提供旧主题和本地化。
独立的 `devtools_extension` 仍跟随 `devtools_extensions` 宿主使用旧 Material，
待宿主支持独立 UI 包后一起迁移，避免新旧主题上下文不匹配。

Apple 工程继续使用现有 CocoaPods 配置，Android 继续使用现有 AGP 配置；
SDK 升级不同时启用 HCPP 或改动平台构建方式。

## 常用命令

- `just sync`：显式同步依赖、l10n 生成物和代理证书资源；适合首次拉代码、切分支、修改 ARB 后或 IDE 调试前预热
- `just l10n`：单独生成国际化代码
- `just l10n-check`：检查国际化生成物是否最新
- `just clean`：执行 `flutter clean` 并重置依赖指纹
- `just rebuild -- <flutter build args...>`：先清理，再执行 `flutter build`
- `just run -- <flutter run args...>`：执行 `flutter run`
- `just build -- <flutter build args...>`：执行 `flutter build`
- `just test -- <flutter test args...>`：执行 `flutter test`
- `just drive -- <flutter drive args...>`：执行 `flutter drive`
- `just native -- <args...>`：显式准备原生产物
- `just doctor`：检查 Flutter / Dart / Cargo、l10n 状态、证书状态和 Android 本地签名状态
- `just analyze -- <args...>`：执行 `flutter analyze`
- `just release-check`：执行发版前检查
- `just release`：稳定版发版入口
- `just prerelease`：预发布发版入口
- `just ipa`：构建无签名 iOS IPA

当透传参数以 `-` 开头时，记得用 `--` 分隔，例如：

```bash
just run -- -d windows
just release -- patch --dry-run
```

## 自动行为

- `just run` / `just build` / `just drive` 会自动执行项目预处理，并在能识别目标平台时自动执行对应的 `native:prepare`
- `just test` 会自动执行测试所需的 `pub get + l10n`
- `just release` / `just prerelease` 会在真正写入版本号和打 tag 前自动执行发版前检查
- `just sync` 不是 hook，而是手动的显式预热命令；日常直接 `just run` / `just build` 即可

## 国际化工作流

- 协作源文件只保留 `lib/l10n/modules/**` 下的模块化 ARB
- `lib/l10n/slang/` 和 `lib/l10n/generated/app_localizations_compat.g.dart` 不提交 Git
- 修改 ARB 后，执行 `just sync` 或 `just l10n`
- 日常运行/构建入口会自动处理 l10n，不需要额外手写 pre-run hook

## IDE 集成

- Android Studio / IntelliJ 的共享运行配置提交在 [`.run/`](</D:/teng/Documents/i/ldx/.run/>)，不放进被忽略的 `.idea/`
- `FluxDO` 运行配置的 before-launch 只保留一个 `Run Prepare`
- 这个 before-launch 会串行执行 `app:prepare` 和 `native:prepare auto`，避免 IDE 按多个步骤反复弹终端
- VS Code 的 [launch.json](/D:/teng/Documents/i/ldx/.vscode/launch.json:1) 和 [tasks.json](/D:/teng/Documents/i/ldx/.vscode/tasks.json:1) 也已切到同一套预处理链路

## 平台约定

- Android 只有在 `android/key.properties` 和 keystore 都完整可用时才使用本地签名
- 当本地签名材料完整时，`debug/profile/release` 都会使用本地签名
- 当本地签名材料缺失时，`debug` 使用默认 debug signing，`profile/release` 自动回退到 debug signing
- Android 构建会优先使用 Android Studio 自带 JBR；如需手动指定，可设置 `FLUXDO_ANDROID_JAVA_HOME`
- Apple 平台不再把 `DEVELOPMENT_TEAM` 写死在共享 `pbxproj`
- 如需 Xcode 真机签名或本地签名构建，复制 [apple/Local.xcconfig.example](/D:/teng/Documents/i/ldx/apple/Local.xcconfig.example:1) 为 `apple/Local.xcconfig`，按文件内注释选择签名方案
- 原生产物准备统一走 `just native -- ...` 或 `dart run tool/project_tasks.dart native:prepare ...`
- Windows / iOS 平台工程已移除内置 cargo / shell build hook，只消费仓库脚本预先落盘的 native 产物
- macOS 保留一个轻量级 bundle copy/sign 阶段，只负责拷贝和签名已准备好的 native 产物

## Linux 桌面开发（Arch / Omarchy）

使用 `.fvmrc` 固定的 Flutter 版本，以及 Rust 1.96 或更新的稳定版。
先把 Flutter 的 `bin/` 和 `$HOME/.cargo/bin` 加入 `PATH`。

安装构建和运行依赖：

```bash
sudo pacman -S --needed base-devel clang cmake ninja pkgconf python git curl xz \
  gtk3 libx11 libxi libepoxy libsecret wayland wpewebkit alsa-lib mpv \
  gst-plugins-base gst-plugins-good gst-libav just
flutter doctor -v
just run -- -d linux
```

`flutter doctor` 的 Linux toolchain 应通过；只开发 Linux 桌面时不需要配置
Android SDK 或 Chrome。项目启动入口会自动准备依赖、国际化代码、证书和
`linux/runner/native/libfluxdo_net.so`，不要跳过原生库准备而直接运行 `flutter run`。

新版 Arch 的 `wpewebkit` 提供 WPEPlatform 和 headless 后端，已不再提供旧的
`libwpe` / `wpebackend-fdo` 包。项目会优先使用 WPEPlatform；旧发行版使用
FDO 后端时仍需要这两个旧库。音频依赖 GStreamer，视频依赖系统 `libmpv`，
仅安装 Flutter 工具链不足以运行完整应用。

在 Try Omarchy 中开发时，建议把 Windows 共享目录中的源码同步到 Linux
主目录再构建，并排除 `.dart_tool/`、`build/`、`.fvm/`、`.pub-cache/`、
`core/net_core/target/` 和各平台的原生产物。Windows 生成的路径、插件链接和
二进制不能直接用于 Linux；也不要让两个系统同时写同一套构建缓存。
通过 SSH 启动图形应用时，需要使用当前桌面会话的 `DISPLAY`、
`WAYLAND_DISPLAY`、`XDG_RUNTIME_DIR` 和 D-Bus 环境。

内存较小的虚拟机可减少首次 Rust 调试构建的资源消耗：

```bash
CARGO_BUILD_JOBS=3 CARGO_PROFILE_DEV_DEBUG=0 CARGO_INCREMENTAL=0 just run -- -d linux
```

验证 Linux WebView 的 SSL 回调与本地 HTTPS 加载（需要 `openssl` 和图形会话）：

```bash
flutter test packages/flutter_inappwebview_linux/test/server_trust_callback_test.dart
FLUXDO_LIVE=1 flutter test test/services/network/core/net_core_webview_trust_test.dart
dart tool/flutterw.dart run -d linux -t tool/linux_webview_smoke.dart
```

冒烟入口会创建临时自签名证书和仅监听回环地址的 HTTPS 服务，验证拒绝证书、
异步允许证书后的首次加载重试、DER 证书传递、JavaScript 和 Cookie 互通，
以及可见 `InAppWebView` 的 HTTPS origin、keepAlive 卸载恢复、iframe 重定向与
消息交互、主页面离站拦截。
WPE 的导航动作只提供目标窗口名称，无法可靠区分主页面和无名 iframe；Linux
小程序使用 `onNavigationResponse` 的主框架标记处理离站，避免把 `frame-host`
当作外部链接。此检查在收到响应后、提交文档前执行。
它不会安装系统证书或使用论坛账号，结束时清理临时文件并退出；结果输出为
`FLUXDO_WEBVIEW_SMOKE` JSON，可用环境变量 `FLUXDO_SMOKE_REPORT` 指定报告路径。
完成后使用 `just run -- -d linux` 恢复正常应用入口。

## macOS 代码签名

macOS 默认走 adhoc 签名（`AppInfo.xcconfig` 中 `FLUXDO_APPLE_CODE_SIGN_IDENTITY_MACOSX = -`），无需证书即可构建。但 adhoc 签名的 CDHash 每次构建都变，钥匙串（`flutter_secure_storage`）会把新构建当成新 app，每次启动反复弹「想要使用钥匙串中的 flutter_secure_storage_service」授权窗。

消除弹窗需要一个稳定的签名身份。无 Apple ID 时可用自签证书：

```bash
# 1. 生成 100 年期自签代码签名证书 + p12（目录自选，不要放进仓库）
openssl req -x509 -newkey rsa:2048 -keyout fluxdo-key.pem -out fluxdo-cert.pem \
  -days 36500 -nodes -subj "/CN=FluxDO Code Signing" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -legacy -out fluxdo-codesign.p12 \
  -inkey fluxdo-key.pem -in fluxdo-cert.pem -passout pass:<密码>

# 2. 导入 login 钥匙串并授信（codeSign 策略）
security import fluxdo-codesign.p12 -k ~/Library/Keychains/login.keychain-db \
  -P <密码> -T /usr/bin/codesign
security add-trusted-cert -p codeSign -r trustRoot \
  -k ~/Library/Keychains/login.keychain-db fluxdo-cert.pem

# 3. 确认 identity 有效
security find-identity -v -p codesigning   # 应列出 "FluxDO Code Signing"
```

然后在 `apple/Local.xcconfig` 中启用（见 example 文件的「用法 1」）。切换后首次启动钥匙串还会弹最后一次（旧 ACL 只认 adhoc 旧构建），点「始终允许」后 rebuild 不再弹。

CI 发版使用同一张证书：把 p12 的 base64 与密码配置为仓库 secrets `MACOS_CODESIGN_P12_BASE64` / `MACOS_CODESIGN_P12_PASSWORD`（见 `.github/workflows/build.yaml` 的 "Setup macOS code signing" 步骤）。secrets 缺失时（如 fork）自动回退 adhoc 签名，构建不会失败。自签证书不等于公证，用户下载 DMG 后仍需右键打开或 `xattr -cr` 解除隔离，与 adhoc 时代一致。


## 网络回归 CI

`network-regression.yaml` 在 PR、dev/main 推送时按改动路径选择检查；文档改动只经过选择和结果汇总。
同一 PR 的旧任务会被新提交取消，不启动 BrowserStack、不连接私有 Tailnet、不探测公网指纹服务。

本地复用同一入口（先完成 `just sync` 或 `dart tool/project_prep.dart test`）：

```sh
python3 tool/ci/network_checks.py dart
python3 tool/ci/network_checks.py rust
python3 tool/ci/network_checks.py python
```

- Dart：网络专项测试、全部架构守卫、定向 analyze。范围在 `tool/ci/network_checks.json`，没有接入应用的存量全量失败。
- Rust：Linux 上运行全部 Core 库测试，使用本地套接字；0 项测试不能算成功。
- Python：严格证据比对、负对照、采样驱动清理和设备预算测试，不创建真实设备会话。
- 原生代码变化：追加对应 Core 编译检查；共享 Core 变化检查 Android arm64、Windows、macOS 和 iOS device/simulator。
  Apple Swift 身份代码以 iOS 15 部署目标检查。这些是 Core/SDK 编译检查，不是五平台完整应用构建或真机运行证据。
- 缓存依赖和 Rust 编译结果；冷缓存可能明显慢于本地或后续运行。`Network regression result` 是统一汇总状态，仓库规则可将其设为必需检查。

`network-diagnostics.yaml` 是唯一手动诊断入口，每次选择一个平台；默认 TCP，H3 必须显式选择。
Windows Flutter 选项固定运行生产 H3 探针及错误 SPKI 负对照。H3 未校准时严格诊断会失败，不表示 TLS/H2 不可用。
诊断使用一次性 GitHub runner/模拟器，不访问付费真机平台；产物保留 7 天。
完整应用仍沿用现有 `build.yaml` 发布构建，不在每次提交重复打包。

本轮清理了 16 个已提交的临时工作流及 2 个本地遗留文件，统一为两个入口；GitHub 上另含早期已删文件，共停用 19 个旧入口。旧分支与工作流保存在 `archive/fingerprint-diagnostics-20261116` 标签；
分支到提交的映射及恢复方式见 `docs/diagnostics/ci-cleanup-20261116.json`。历史测试报告及运行记录保留。
