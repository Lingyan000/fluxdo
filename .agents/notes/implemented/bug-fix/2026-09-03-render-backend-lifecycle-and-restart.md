# Agent Note: GLES 渲染后端的引擎生命周期与重启交互

Status: implemented

## Problem

Android 的 Mali 驱动在 Flutter Impeller/Vulkan 的纹理或表面销毁路径中可能触发 `mali-event-hand` 线程崩溃，设备日志表现为 `FORTIFY: pthread_mutex_lock called on a destroyed mutex`。应用需要一个可以在冷启动时生效的用户级兼容开关，同时不能泄漏由 Activity 创建的 FlutterEngine，也不能用不可靠的方式强制重启进程。

原先使用 `--impeller-backend=opengles` 试图在 Release 包中固定 Impeller 的 OpenGLES 后端，但 Flutter 3.44.0 和 3.44.8 engine 的 `flutter_main.cc` 都将该后端选择分支包在 `#ifndef FLUTTER_RELEASE` 中。Release 构建虽然会接收并解析该参数，却会忽略它，随后动态选择 Vulkan。CI 包在开关开启时仍记录 `Using the Impeller rendering backend (Vulkan)`，证明了这一点。

## Decision

`MainActivity` 在冷启动前读取 `FlutterSharedPreferences` 中的 `flutter.renderer_gles`。兼容模式开启时，它创建宿主拥有的 `FlutterEngine`，传入 `--enable-impeller=false`，让 Flutter Release engine 选择 Skia/OpenGL ES；关闭时返回 `null`，继续使用 Flutter embedding 的默认后端选择。

兼容模式仍沿用 `renderer_gles` 偏好键，以保留已经安装过测试版本的用户设置。代码和设置文案明确称其为 Skia/OpenGL ES 兼容模式，而不再声称使用 Impeller OpenGLES。

`MainActivity` 记录是否创建了自定义引擎。当该标记为 true 时，`shouldDestroyEngineWithHost()` 返回 true；其他路径继续委托 Flutter embedding 的默认实现。自定义引擎因此与创建它的 Activity 具有相同生命周期，默认引擎和潜在缓存引擎的既有语义不变。

设置页在偏好落盘后只展示手动重启提示。对话框明确说明用户需要关闭并重新打开 FluxDO，不再提供会强制终止进程的“一键重启”操作。

## Preference contract

Dart 使用 `SharedPreferences` 键 `renderer_gles`。Android 原生插件将该键保存到 `FlutterSharedPreferences` 文件，并加上 `flutter.` 前缀，因此 `MainActivity` 必须读取 `flutter.renderer_gles`。这三个值是跨 Dart/native 的持久化契约，修改任意一侧时必须同步另一侧。

## Release backend detail

Flutter 3.44.x 的 `--impeller-backend=opengles` 只在 Debug/Profile 的 `SelectedRenderingAPI` 分支中固定 `kImpellerOpenGLES`。Release 模式会跳过该分支；当 Impeller 仍启用时，设备会进入动态后端选择。`--enable-impeller=false` 不依赖被 Release 排除的 requested-backend 分支，最终选择 `kSkiaOpenGLES`。

HCPP 只在 Impeller Vulkan 渲染 API 下建立，因此 Skia/OpenGL ES 兼容模式也会避开当前设备上的 HCPP Vulkan 合成路径。代价是兼容模式不再使用 Impeller 和依赖 Vulkan 的 HCPP。

## Alternatives considered

- **继续使用 `--impeller-backend=opengles`** — Flutter 3.44.x Release engine 会忽略具体后端选择，真实日志仍显示 Vulkan，因此不能作为生产兼容方案。
- **仅增加 `ImpellerBackend` manifest metadata** — metadata 最终仍转换为同一个 requested backend 参数，不能绕过 Release engine 的条件编译；同时 manifest 也无法按用户偏好动态切换。
- **只关闭 HCPP** — 需要改变应用级 manifest 配置，无法提供当前的用户级开关，而且不能保证绕开所有 Impeller/Vulkan 资源销毁路径。
- **全平台永久切换到 Skia** — 可以降低兼容风险，但会让没有问题的设备也失去 Impeller 性能和 HCPP；保留用户级开关可以把性能代价限制在受影响设备上。
- **始终让 `shouldDestroyEngineWithHost()` 返回 true** — 实现更短，但会覆盖 Flutter 对缓存引擎的默认所有权语义；当前实现只接管本 Activity 创建的自定义引擎。
- **覆写 `getFlutterShellArgs()` 并让 embedding 创建引擎** — 可以天然保留生命周期，但 Flutter 3.44.8 的 `FlutterShellArgs` 已弃用，上游正在移除通过该通道设置引擎参数的能力。
- **通过 AlarmManager 或 PendingIntent 一键重启进程** — 需要主动结束进程，并引入后台启动、系统调度和厂商兼容差异；渲染兼容开关不是必须即时生效的操作，手动重启提示更简单可靠。
- **继续使用 `exit(0)`** — 它不会重新拉起应用，且可能中断其他正在进行的持久化或后台任务，因此不可接受。

## Consequences

兼容模式现在确实能在 Release 构建中选择 Skia/OpenGL ES，绕过默认的 Impeller/Vulkan 与 HCPP 路径；关闭兼容模式时，应用仍保持 Flutter 默认渲染行为。代价是开启后可能损失 Impeller 的部分性能和特性，并且需要用户手动重启应用。

原生启动日志会记录偏好读取结果和兼容模式选择，便于通过 logcat 验证实际后端。该开关只能缓解 Vulkan/Impeller 相关的 Mali 崩溃，不能保证修复所有厂商 GLES 驱动或其他原生插件问题。

## Testing

已通过 Flutter 3.44.0 与 3.44.8 engine 源码对比确认 Release 后端选择条件，并通过实体设备上的 CI Flutter 3.44.0 包确认旧实现开启后仍落入 Vulkan。

实机回归验证在搭载天玑 9000 (Mali-G710 MC10) 的 Redmi K50 Pro（设备 `KBS4TGCMRSCY6TYX`，Android 14）上进行，使用与生产完全一致的 Flutter 3.44.0 arm64 Release CI 构建包（Run 33767910363，包名 `com.github.lingyan000.fluxdo.ci3440`）：

1. **兼容模式开启验证（PID 14761，23:52:02）**：
   - 原生日志确认：`RenderBackend: 渲染兼容模式读取结果: useGles=true`、`RenderBackend: 启用 Skia/OpenGL ES 兼容模式`。
   - 引擎日志中 `android_context_vk_impeller` 与 `Using the Impeller rendering backend (Vulkan)` 完全消失。
   - 打开帖子中的图片，频繁反复进入/退出图片预览，全程运行稳定，无任何闪退。
2. **对照关闭验证（PID 15783，23:54:35）**：
   - 原生日志确认：`RenderBackend: 渲染兼容模式读取结果: useGles=false`。
   - 引擎恢复 Vulkan：`Using the Impeller rendering backend (Vulkan)`。
   - 进行相同图片预览操作，14 秒内立即复现 `Fatal signal 6 (SIGABRT) in tid 15919 (mali-event-hand)`，崩溃栈指向 `libGLES_mali.so` 内的 destroyed mutex。

对比严格证明：`--enable-impeller=false` 在 Release 构建下确实成功切入 Skia/OpenGL ES 并彻底阻断了该设备的 Mali Vulkan 竞态崩溃。