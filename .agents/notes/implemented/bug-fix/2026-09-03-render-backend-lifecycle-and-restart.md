# Agent Note: GLES 渲染后端的引擎生命周期与重启交互

Status: implemented

## Problem

Android 的 GLES 渲染兼容模式需要在 Flutter VM 首次启动前传入 `--impeller-backend=opengles`。应用因此通过 `MainActivity.provideFlutterEngine()` 创建引擎，但 Flutter embedding 会把该返回值视为宿主提供、可脱离 Activity 存活的外部引擎，默认不会在 Activity 销毁时释放。与此同时，设置页使用 `exit(0)` 表示“立即重启”，实际只会强制终止进程，并绕过正常生命周期清理。

## Decision

`MainActivity` 记录当前 Activity 是否创建了 GLES 自定义 `FlutterEngine`。当该标记为 true 时，`shouldDestroyEngineWithHost()` 返回 true；其他路径继续委托 Flutter embedding 的默认实现。自定义引擎因此与创建它的 Activity 具有相同生命周期，默认引擎和潜在缓存引擎的既有语义不变。

设置页在偏好落盘后只展示手动重启提示。对话框明确说明用户需要关闭并重新打开 FluxDO，不再提供会强制终止进程的“一键重启”操作。

## Preference contract

Dart 使用 `SharedPreferences` 键 `renderer_gles`。Android 原生插件将该键保存到 `FlutterSharedPreferences` 文件，并加上 `flutter.` 前缀，因此 `MainActivity` 必须读取 `flutter.renderer_gles`。这三个值是跨 Dart/native 的持久化契约，修改任意一侧时必须同步另一侧。

## Alternatives considered

- **始终让 `shouldDestroyEngineWithHost()` 返回 true** — 实现更短，但会覆盖 Flutter 对缓存引擎的默认所有权语义；当前实现只接管本 Activity 创建的 GLES 引擎。
- **覆写 `getFlutterShellArgs()` 并让 embedding 创建引擎** — 可以天然保留生命周期，但 Flutter 3.44.8 的 `FlutterShellArgs` 已弃用，上游正在移除通过该通道设置引擎参数的能力。
- **通过 AlarmManager 或 PendingIntent 一键重启进程** — 需要主动结束进程，并引入后台启动、系统调度和厂商兼容差异；渲染兼容开关不是必须即时生效的操作，手动重启提示更简单可靠。
- **继续使用 `exit(0)`** — 它不会重新拉起应用，且可能中断其他正在进行的持久化或后台任务，因此不可接受。

## Consequences

GLES 模式不再因 Activity 重建遗留 FlutterEngine、插件或 GPU 资源，设置页也不再强制终止应用。代价是渲染后端切换需要用户手动关闭并重新打开 FluxDO；这是为了避免不可靠的进程自拉起机制而接受的显式交互成本。

四个受支持 locale 都提供渲染设置文案，英语和繁体中文不再回退显示简体中文。

## Testing

Dart 格式、本地化生成、静态分析、相关单元测试和 Android debug 构建用于验证源码与生成链路。Android 真机验证还应覆盖 GLES 开关启停、冷启动后端切换以及 Activity 重建后的引擎释放行为。
