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
