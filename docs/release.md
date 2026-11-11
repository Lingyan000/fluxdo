# 发版与 iOS IPA

## 版本亮点(stable 发版前)

stable 版本的发布日志正文取自 `highlights/v<版本>.md`(用户视角亮点),GitHub Release 会把全量
commit 明细折叠在 `<details>` 里,Telegram / AltStore 只发亮点。文件缺失时 CI 自动回退全量明细,
不挡发版,但 `release.dart` 会在发版信息里警告。

发版前在 Claude Code 里运行 `/release-highlights` 起草,人工修订后提交(tag 必须打在包含该文件的
commit 上),写作约定见 `highlights/README.md`。beta / rc 不需要亮点文件。

## 标准入口

本地开发推荐直接使用 `just`：

```bash
just release
just release patch
just release minor
just prerelease
just prerelease next --preid beta
just prerelease patch --preid rc
just release 0.1.0
just prerelease 0.1.0-beta.0
just ipa
just ipa 0.2.3
```

如果参数以 `-` 开头，记得用 `--` 分隔，例如：

```bash
just release -- patch --dry-run
```

自动化、CI 或脚本化场景直接调用 Dart 入口：

```bash
dart run tool/release.dart --track release
dart run tool/release.dart --track release patch
dart run tool/release.dart --track release minor
dart run tool/release.dart --track prerelease
dart run tool/release.dart --track prerelease next --preid beta
dart run tool/release.dart --track prerelease patch --preid rc
dart run tool/release.dart --track release 0.1.0
dart run tool/release.dart --track prerelease 0.1.0-beta.0
dart run tool/build_ipa_nosign.dart
dart run tool/build_ipa_nosign.dart 0.2.3
```

## `release` 会做什么

- 稳定版通道使用 `patch/minor/major`
- 预发布通道使用 `patch/minor/major/next`
- 兼容模式下仍接受旧的 `prepatch/preminor/premajor/prerelease`
- 优先用最新 Git tag 作为版本计算基线；同核心版本时不会丢失预发布序列
- 终端支持时使用 `dart_console` 提供选择式 CLI UI；在 IDE / 无 TTY 场景下自动退回普通行输入
- 不传版本参数时进入交互式选择，可直接在终端里选发版类型、预发布标识和 `dry-run`
- 校验版本号格式
- 检查当前目录是否为 Git 仓库
- 检查工作区是否干净
- 检查 tag 是否已存在
- 执行发版前检查（`just release-check` / `dart run tool/project_tasks.dart release:prepare`）
- 更新 `pubspec.yaml` 版本号
- 创建 commit、tag，并推送到远端

## 使用约束

- 发版前请确保所有改动已提交或已暂存清理
- 默认建议在 `main` 分支执行；非 `main` 会在最终摘要中提示
- 本地人工稳定版发版使用 `just release`
- 本地人工预发布发版使用 `just prerelease`
- 自动化或 CI 场景直接使用 `dart run tool/release.dart ...`
- 预发布版本通过 `--preid` 指定 `beta` / `rc`
- iOS 无签名 IPA 只能在 macOS 上打包
- `ios:ipa-nosign` 不传版本号时，会默认读取 `pubspec.yaml` 当前版本并进入确认

## 常用示例

```bash
# 交互式选择发版类型
just release

# 日常修复发版
just release patch

# 跳过 analyze 和 test，直接进入版本提交/tag 流程
just release -- patch --skip-analyze --skip-test -y

# 新增功能发版
just release minor

# 开始一轮 beta
just prerelease patch --preid beta

# 继续 beta.1 -> beta.2
just prerelease next --preid beta

# 交互式输入 IPA 版本并确认构建
just ipa

# 跳过最终确认
just release patch -y

# 只预览，不真正写入和推送
just release -- minor --dry-run
```

如果你是在某些 IDE 终端或无 TTY 场景下执行，交互确认仍然异常，直接加 `-y` / `--yes` 即可。

## 相关命令

```bash
just release-check
dart run tool/project_tasks.dart release:prepare
dart run tool/project_tasks.dart native:prepare ios --release
dart run tool/flutterw.dart build ios --release --no-codesign
```

## macOS Sparkle 自更新

macOS Release 构建通过 Sparkle 2.10.1 完成下载、签名校验、安装和重启。应用内的更新检查设置、
发布说明和“立即更新”入口沿用现有 Flutter 流程，确认后进入 Sparkle 的原生更新界面。
Debug 构建点击更新会打开发布页。

- Sparkle 依赖通过 Swift Package Manager 锁定，原生桥位于 `macos/Runner/MacOSUpdateHandler.swift`。
- 当前进程按 arm64 或 x86_64 选择对应 appcast，Rosetta 进程继续使用 x86_64 更新包。
- 更新源与 DMG 下载接入 GitHub 反代设置。原生请求受 macOS App Transport Security 约束，反代使用 HTTPS。
- 首次安装包含 Sparkle 的版本后，后续版本才能通过应用内更新安装。

### 更新签名

公钥保存在 `macos/Runner/Info.plist` 的 `SUPublicEDKey`，私钥保存在 macOS 钥匙串的
Sparkle 条目中，账户名为 `com.github.lingyan000.fluxdo`。发布仓库的 GitHub Actions Secret
使用 `SPARKLE_PRIVATE_KEY`。私钥长期保留，常规发版复用现有密钥。

稳定版构建在 DMG 打包完成后运行 `scripts/ci/macos/generate_appcast.py`。脚本校验 tag 与应用版本，
签名 DMG，验证签名与包内公钥配对，再生成并签名两个架构各自的 appcast。Sparkle 使用
`CFBundleVersion` 比较构建版本，使用 `CFBundleShortVersionString` 展示版本号。

GitHub Release 随安装包发布以下文件，应用通过 `releases/latest/download/` 获取对应更新源。

- `appcast-macos-arm64.xml`
- `appcast-macos-x86_64.xml`

包签名和 appcast 签名均为必需。签名工具复用 Swift Package Manager 已锁定和校验的 Sparkle 依赖。Apple 应用代码签名
继续沿用现有 CI 配置，Sparkle 的 Ed25519 密钥用于更新发布签名。

### WinGet 与 Homebrew Cask

稳定版发布流程会运行 `scripts/ci/generate_distribution_manifests.py`，使用本次发布的真实安装包
计算 SHA-256，并将配置打包为 `fluxdo-package-managers.zip` 发布到 Release。

- `winget/manifests/` 包含 `Lingyan000.FluxDO` 的版本、英文元数据和 Inno Setup 安装清单，默认范围为当前用户。
  使用 WinGet 社区仓库当前推荐的 1.28.0 schema，并包含 schema 文件头。在 Windows 上验证安装、升级后，
  向 `microsoft/winget-pkgs` 提交清单。社区仓库接收后可使用 `winget install --id Lingyan000.FluxDO -e`。
- `homebrew/Casks/fluxdo.rb` 使用双架构 DMG，声明 `auto_updates true`，可放入维护者自己的 tap。
  [Lingyan000/homebrew-tap](https://github.com/Lingyan000/homebrew-tap) 已配置每六小时同步最新稳定版清单，
  并支持手动运行 `Sync FluxDO release`。工作流核验清单 ZIP 的 SHA-256，加载 Cask 后提交到 tap。
  首次包含清单的稳定版同步后，可使用 `brew install --cask Lingyan000/tap/fluxdo`。
  Homebrew 更新命令为 `brew upgrade --cask --greedy fluxdo`。官方 `homebrew/cask` 收录还要求产物通过 Gatekeeper 检查。

清单需要同步到对应包源，完成后上述安装命令生效。

### 分发配置 CI

`Distribution checks` 在 `dev`、`main` 上的清单生成脚本或工作流改动时运行，也支持 PR 和手动触发。
它使用测试文件调用正式清单生成入口，核验 SHA-256、预发布版本拒绝逻辑和微软官方 JSON schema，
再分别在 macOS 上加载 Homebrew Cask、在 Windows 上执行 `winget validate`。
测试清单只用于 CI 验证，正式发布清单由发版流程根据实际产物生成。

### WinGet 首次提交

稳定版发布后，下载并解压 `fluxdo-package-managers.zip`，在 Windows 上执行以下命令。
将 `<版本目录>` 替换为解压后的 `winget/manifests/l/Lingyan000/FluxDO/<版本号>`。

```powershell
winget validate --manifest <版本目录>
# 在管理员终端启用本地清单，再在普通用户终端执行安装验证。
winget settings --enable LocalManifestFiles
winget install --manifest <版本目录> --silent --accept-package-agreements --accept-source-agreements
```

检查当前用户安装范围、版本号、启动和卸载，并验证从上一版本升级。
确认没有同版本重复 PR 后，安装官方 WinGet Manifest Creator 并提交。

```powershell
winget install --id Microsoft.WingetCreate -e
wingetcreate submit --prtitle "New package: Lingyan000.FluxDO version <版本号>" --no-open <版本目录>
```

首次提交按工具提示完成 GitHub 登录，后续由微软社区验证流水线和维护者处理。
若要求签署贡献者协议，由账户持有人完成。每个 PR 只提交一个版本的三份清单。
普通仓库 `GITHUB_TOKEN` 的权限限定在当前仓库，当前流程通过提交工具完成跨仓库 PR。

### 正式发版后验证

- 检查两个架构的 DMG、签名 appcast 和清单 ZIP 均随 Release 发布，下载 URL 可访问。
- 安装首个包含 Sparkle 的正式版本，再用更高构建号版本验证 FluxDO 下载、签名校验、替换和重启。
  验证代理、跳过版本，以及应用升级后的登录和钥匙串访问。
- 运行 tap 同步工作流，验证真实 Cask 的全新安装与 `brew upgrade --cask --greedy fluxdo`。
- 在 Windows 上用真实 Release 清单验证静默安装和旧版本升级，提交 WinGet PR 后跟进官方验证。
