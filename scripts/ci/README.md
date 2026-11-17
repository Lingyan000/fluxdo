# CI 脚本目录

`scripts/ci/` 只保留 CI / 打包链路内部脚本，不作为日常开发入口。

当前按领域分层：

- `scripts/ci/linux/`
  - Linux bundle 构建与 Linux 插件补丁
- `scripts/ci/flatpak/`
  - Flatpak source tree、WPE layer、容器内打包及离线修补

约定：

- 本地开发、运行、构建、发版统一走 `just`；需要脱离 `just` 时直接调用 `tool/*.dart`
- `melos` 只保留 workspace bootstrap，不再扩张为本地开发命令面
- CI shell/python 脚本只保留工作流级环境胶水，不承载项目业务逻辑

## Android 插件兼容验证

`android/gradle/kotlin_compat.gradle` 在应用显式关闭 AGP 内置 Kotlin 时，
为含 Kotlin 源码的 Android library 提前应用 KGP。某些插件只检查 AGP
版本，Flutter 的静态检测又会把条件分支中的 `apply` 当成已应用，导致
插件类未编译、最终在 `GeneratedPluginRegistrant` 中报找不到类。
排查时除检查 Gradle 配置，还应执行对应插件的 `compileReleaseKotlin`
并确认 class 产物，再验证应用的 Release APK 构建。

`android/gradle/cargokit_compat.gradle` 为仍调用 `Project.exec` 的 Cargokit
插件转接到 Gradle 9 的 `ExecOperations`，仅作用于 Android 的 Cargokit 子项目。
安装 Flutter 依赖及 Gradle 9 后，可离线运行：

```sh
python3 scripts/ci/android/check_cargokit_compat.py --gradle "$PWD/android/gradlew"
```

检查直接加载当前依赖的真实 Cargokit 任务，覆盖原始错误、命令和环境变量、
带空格路径、非零退出以及其他插件隔离。上游全部迁移后应一并移除兼容层和此检查。

## Windows 自更新发布约定

- 发布资源保持 `fluxdo-windows-x86_64-setup.exe` 和同名 `.sha256`。现有 release job 已为所有产物生成校验文件；更新端优先校验 GitHub API 返回的 SHA-256 digest，没有 digest 时必须成功获取并校验 `.sha256`，不会在校验失败后执行安装包。
- Windows 构建 job 先运行 `test/services/windows_update_service_test.dart`，再构建应用和 `windows/setup.iss`。原生桥变更需要完整重编译 Windows，热重载无法更新原生代码。
- 新安装包识别 `/UPDATE=1 /UPDATEPID=... /UPDATEHWND=...`。在 `PrepareToInstall` 请求指定窗口正常关闭并等待进程退出，成功后以原用户身份重启；不通过进程名称强杀应用，不自动重启系统。目录和当前用户／所有用户范围从本机安装记录确定。
- 先手动安装包含更新器的版本，之后的新版本才能应用内更新。便携 ZIP 版和缺少校验资源的发布回退到发布页。
- 下载包位于系统临时目录的独立 `fluxdo-update-*` 子目录；取消或校验失败会清理。安装交接后保留安装包，安装器通过 `/LOG` 将日志写入用户临时目录，便于失败排查。

发布前用两个不同版本的安装包验证：当前用户安装、自定义含空格／中文的目录、所有用户安装与 UAC 取消、下载取消与重试、更新后版本号及登录状态、便携版回退。测试真实覆盖安装必须使用独立测试安装，不能用本地开发目录充当安装目录。
