# Android 渲染后端兼容模式

> 状态：已实施
> 适用范围：仅 Android
> 相关代码：`MainActivity.provideFlutterEngine` / `RenderCrashDetector.kt` / `lib/services/render_backend_service.dart`

---

## 1. 问题

部分 Mali GPU 设备在 Flutter Impeller/Vulkan 的纹理、表面销毁路径上会触发原生崩溃，
典型日志特征：

```text
FORTIFY: pthread_mutex_lock called on a destroyed mutex
Fatal signal 6 (SIGABRT)
mali-event-hand
libGLES_mali.so
```

应用需要一个冷启动即生效的用户级兼容开关，同时不能泄漏由 Activity 创建的
FlutterEngine，也不能用不可靠的方式强制重启进程。

## 2. 为什么不能用 `--impeller-backend=opengles`

最初尝试用该参数在 Release 包中固定 Impeller 的 OpenGLES 后端，**不可行**。

Flutter 3.44.0 与 3.44.8 engine 的 `flutter_main.cc` 都把后端选择分支包在
`#ifndef FLUTTER_RELEASE` 中：`--impeller-backend=opengles` 只在 Debug/Profile 的
`SelectedRenderingAPI` 分支里固定 `kImpellerOpenGLES`。Release 构建会接收并解析该
参数却直接忽略，随后进入动态后端选择。

实测佐证：CI Release 包在开关开启时日志仍为
`Using the Impeller rendering backend (Vulkan)`。

改用 `--enable-impeller=false`：它不依赖被 Release 排除的 requested-backend 分支，
最终选择 `kSkiaOpenGLES`。

HCPP 只在 Impeller Vulkan 渲染 API 下建立，因此兼容模式同时避开了 HCPP 的 Vulkan
合成路径 —— 代价是失去 Impeller 与依赖 Vulkan 的 HCPP。

## 3. 引擎生命周期

兼容模式开启时，`MainActivity.provideFlutterEngine` 创建宿主拥有的 `FlutterEngine`
并传入 `--enable-impeller=false`；关闭时返回 `null`，走 embedding 的默认创建路径。

`shouldDestroyEngineWithHost()` 的实现**不能**简化为直接返回 `true`：

```kotlin
override fun shouldDestroyEngineWithHost(): Boolean =
    ownsProvidedFlutterEngine || super.shouldDestroyEngineWithHost()
```

只接管本 Activity 自己创建的引擎，其余情况（含缓存引擎）仍委托 embedding 的默认
所有权语义。否则会覆盖 Flutter 对缓存引擎的既有约定。

## 4. 偏好存储契约

跨 Dart/native 的持久化契约，**修改任意一侧必须同步另一侧**：

| 用途 | 文件 | 键 |
|---|---|---|
| Dart 读写 | shared_preferences 插件托管 | `renderer_gles` |
| 插件的原生落盘 | `FlutterSharedPreferences` | `flutter.renderer_gles` |
| 启动快路径 | `render_backend_fast` | `renderer_gles` |

Dart 侧的键刻意不带项目其余偏好统一的 `pref_` 前缀，因为它需要与原生侧对齐。

### 为什么有第三份「启动快照」

`provideFlutterEngine` 在主线程同步执行，而 `getSharedPreferences` 首次读取会同步
解析整个 XML。直接读 `FlutterSharedPreferences` 意味着为一个开关解析装着全部应用
偏好的大文件，且**每次冷启动都解析**，包括永远不会开这个开关的绝大多数用户。

因此写入时双写一份只含单个 boolean 的 `render_backend_fast` 快照，启动只读它；
快照缺失（旧版本升级上来）时才回退解析主文件，保证设置不丢。

## 5. 崩溃自动识别

用户不可能知道闪退与某个渲染开关有关，只提供设置项等于让绝大多数受影响用户永远
发现不了它。`RenderCrashDetector` 在启动后的后台线程读
`ActivityManager.getHistoricalProcessExitReasons`，本地判断上次退出是否疑似
Mali/Vulkan 渲染崩溃，命中则弹窗建议开启兼容模式。

### 5.1 按证据强度分级，而非崩溃次数

固定次数阈值两头不讨好：设成 1 次会把插件/JNI 崩溃误归因到渲染后端；设成 2 次又
往往等不到 —— 受影响用户崩一次通常就不敢再碰那个功能，或者直接卸载。

| 级别 | 判据 | 触发条件 |
|---|---|---|
| A（强证据） | tombstone 中出现 `libGLES_mali` / `mali-event-hand` / `libvulkan` 等关键字 | 崩 **1 次**即建议 |
| B（弱证据） | 拿不到 tombstone，退化为「前台 native 致命信号崩溃 + Mali GPU」 | 累计 **2 次**才建议 |

A 级的崩溃栈直接指认 Mali GL 库，几乎不可能误报。

B 级不是可选项：`getTraceInputStream` 只在 **API 31+** 才对 `REASON_CRASH_NATIVE`
返回 tombstone，且该缓冲区是**跨应用共享的环形队列**，随时可能被别的应用的崩溃挤掉
而返回 null（[官方文档明示](https://developer.android.com/reference/android/app/ApplicationExitInfo#getTraceInputStream())）。
没有 B 级兜底，API 30 设备和缓冲被挤掉的场景会完全漏报。

### 5.2 tombstone 不解析 protobuf

tombstone 是 protobuf，schema 还随 Android 版本演进。但其中的 so 路径、线程名都是
**明文 UTF-8 字符串字段**，直接在原始字节上做子串搜索即可可靠命中，引入 protobuf
依赖去解析属于过度工程。

- 用 ISO-8859-1 解码保证字节与字符一一对应，不会因非法 UTF-8 序列丢字节。
- 只读前 512 KB —— 只为找关键字，不需要全文。
- **不用 `InputStream.readNBytes`**：那是 Java 11 API，在 Android 上要求 API 33+，
  与本检测 API 31+ 的目标冲突，改为手写读取循环。

### 5.3 GPU 判定不能用 `glGetString`

`GLES20.glGetString(GL_RENDERER)` 要求调用线程已绑定 GL context，在启动扫描的后台
线程上必然返回 null —— 会让 B 级判定**静默失效**（比报错更难发现）。

改用双通道，均不需要 EGL context：

1. 系统属性 `ro.hardware.egl`（厂商专门用来标识 GPU）。`SystemProperties` 是
   hidden API，Android 11+ 可能被灰名单拦截，故用反射并在失败时回退 `Build.HARDWARE`。
2. `EGL14.eglQueryString(display, EGL_VENDOR)` —— 只需要 EGLDisplay，
   **不需要 context/surface**，可在任意线程调用。

### 5.4 与 AnrTraceReporter 的关系

两者都读 `getHistoricalProcessExitReasons`，但用途正交，各自维护独立的
SharedPreferences 文件与「已处理时间戳」，互不干扰：

| | AnrTraceReporter | RenderCrashDetector |
|---|---|---|
| 用途 | **上报**，服务开发者 | **本地判断**，服务用户 |
| 依赖 Crashlytics 开关 | 是 | 否（零网络） |
| prefs 文件 | `anr_trace_reporter` | `render_crash_detector` |

崩溃识别不能挂在采集开关下 —— 所有用户都需要被提醒，不能因为没开崩溃上报就永远
看不到建议。

### 5.5 用户拒绝后的行为

点「暂不开启」后写入 `user_dismissed`，之后不再自动弹窗。但设置项上仍常驻
「⚠ 检测到闪退，建议开启」副标题（`hasDetectedRenderCrash` 不会被消费），让用户
之后想起来时还能找到线索。

## 6. 权衡过的替代方案

| 方案 | 否决原因 |
|---|---|
| 继续用 `--impeller-backend=opengles` | Release engine 忽略具体后端选择，实测日志仍为 Vulkan |
| 只加 `ImpellerBackend` manifest metadata | 最终仍转换为同一个 requested backend 参数，绕不过 Release 的条件编译；且 manifest 无法按用户偏好动态切换 |
| 只关闭 HCPP | 需改应用级 manifest，无法做成用户级开关，也不能保证绕开所有 Impeller/Vulkan 销毁路径 |
| 全平台永久切到 Skia | 会让无问题设备也失去 Impeller 性能与 HCPP；用户级开关可把代价限制在受影响设备 |
| `shouldDestroyEngineWithHost()` 恒返回 `true` | 实现更短，但会覆盖 Flutter 对缓存引擎的默认所有权语义 |
| 覆写 `getFlutterShellArgs()` | Flutter 3.44.8 已弃用 `FlutterShellArgs`，上游正在移除该通道 |
| AlarmManager / PendingIntent 一键重启 | 需主动结束进程，引入后台启动、系统调度与厂商兼容差异；渲染开关不需要即时生效，手动重启提示更可靠 |
| `exit(0)` | 不会重新拉起应用，且可能中断正在进行的持久化或后台任务 |

## 7. 影响与限制

- 默认关闭，不改变现有用户的渲染行为；仅 Android 显示该设置。
- 开启后需完全关闭并重新打开应用。
- 开启会关闭 Impeller，可能损失部分渲染性能与 HCPP 能力。
- 该开关只能缓解 Vulkan/Impeller 相关的 Mali 崩溃，**不保证**修复所有厂商 GLES
  驱动或其他原生插件导致的崩溃。

## 8. 验证记录

已通过 Flutter 3.44.0 与 3.44.8 engine 源码对比确认 Release 后端选择条件，并通过
实机 CI 包确认旧实现（`--impeller-backend=opengles`）开启后仍落入 Vulkan。

实机对照验证环境：

- 设备：Redmi K50 Pro（天玑 9000，Mali-G710 MC10，Android 14）
- 构建：Flutter 3.44.0 arm64 Release CI 包（Run 33767910363，
  包名 `com.github.lingyan000.fluxdo.ci3440`）

**开启兼容模式**

- 原生日志确认启用 Skia/OpenGL ES 兼容模式。
- `android_context_vk_impeller` 与 `Using the Impeller rendering backend (Vulkan)`
  完全消失。
- 反复进入/退出图片预览，全程稳定无闪退。

**对照关闭**

- 引擎恢复 `Using the Impeller rendering backend (Vulkan)`。
- 相同操作 14 秒内复现
  `Fatal signal 6 (SIGABRT) in tid 15919 (mali-event-hand)`，
  崩溃栈指向 `libGLES_mali.so` 内的 destroyed mutex。

对照结果证明 `--enable-impeller=false` 在 Release 构建下确实切入 Skia/OpenGL ES，
并阻断了该设备的 Mali Vulkan 竞态崩溃。

> 待补：崩溃自动识别（第 5 节）目前只做了静态验证与编译验证，A/B 分级的真机触发
> 路径尚未在 Mali 设备上实测。
