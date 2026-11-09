# Android 标准免确认自更新补丁

基线为 pub.dev 官方 ota_update 7.1.0（2026-11-09 查询仍为最新稳定版）。保留上游 LICENSE、pubspec、Android 插件源码、lib、README 和 CHANGELOG；UPSTREAM_SHA256.json 记录复制前的摘要。README 与 CHANGELOG 仅清理行尾空白。

- 来源：https://pub.dev/packages/ota_update/versions/7.1.0
- API 依据：https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int)
- 应用启用 `usePackageInstaller`；Android 12+ 对包名一致的自身更新设置 `USER_ACTION_NOT_REQUIRED`，较旧系统仍使用有确认的安装会话。应用声明 `UPDATE_PACKAGES_WITHOUT_USER_ACTION` 并注册非导出的安装结果接收器。签名、版本、目标 API、未知来源许可及系统限制继续由 Android 校验。
- `STATUS_PENDING_USER_ACTION` 在前台展示系统确认页；后台提供通知入口，通知文案由应用现有国际化资源传入。进程仍存活时，回到 MainActivity 的 `onPostResume` 也可恢复待确认页面。未添加自动重启、Root 或 Shizuku。
- 使用可变、显式且按会话区分的安装结果 PendingIntent；提交失败释放会话，安装进度只接受当前会话。
- 修正上游 Java 与 Dart 对 `ALREADY_RUNNING_ERROR` / `INSTALLATION_ERROR` 的枚举顺序差异；错误流和订阅取消正确向下游传递。取消下载会通知原生停止；取消到提交之间检查下载归属，避免取消后继续安装。
- 安装会话只接受本应用包名；下载失败不会提交安装，重试不继承旧的 checksum 和 headers。

已完成的验证：

- `flutter test test/services/apk_download_service_test.dart --no-pub`：5 项通过，覆盖成功判定、安装失败、重复调用、取消与事件通道释放。
- 本次修改的 Dart 服务、状态控制器、测试和插件接口定向静态检查通过。
- `:ota_update:compileDebugJavaWithJavac`、`:app:processDebugMainManifest`、`:app:compileDebugKotlin`（跳过 Flutter 打包）通过。
- Android 16 / API 36 模拟器使用独立测试包直接编译本补丁的 Java 源码，未声明 `INSTALL_PACKAGES`：同签名 versionCode 1 → 2 免确认覆盖成功；撤销未知来源许可后，前台显示系统授权页，后台生成确认通知，回到应用可恢复确认；取消后收到状态码 4 的安装失败和流结束，通知清理。测试包已卸载。

真机验收应使用同签名的两个递增 versionCode 版本：Android 12+ 已允许未知来源安装时尝试免确认覆盖；系统要求确认时完成/取消确认均应结束安装状态；后台下载需要确认时点击通知或回到应用完成；未授予未知来源、目标 API 不满足、签名不一致等由系统正常处理。安装可能终止旧应用进程，成功后由用户重新打开；更新后本版能力才会用于下一次应用内更新。

升级上游时先移除覆盖，核对以上行为是否已合入，再决定是否保留补丁。
