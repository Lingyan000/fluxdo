# 媒体压缩预算与平台参数

媒体上传读取站点 max_attachment_size_kb，分片开关不改变大小限制。缺少有效配置时不套用固定4MiB限制，交给服务端判断。未超限媒体保持原文件。

超限文件的目标为上限95%减封装余量（最多96KiB）；按时长计算总码率。视频默认H.264/AAC，普通音频AAC；语音使用低码率单声道参数，普通音频尽量保持源声道/采样率（最多双声道44.1kHz）。

最多三次转码。超限后用实测大小修正下一次预算，每轮重读原片，不能串联有损压缩。检查产物非空、可探测、时长容差、视频轨及已知音轨是否丢失。预算不足以维持最低质量时提示缩短素材。

Android使用MediaExtractor探测音频布局/采样率/帧率，旋转后的显示宽高由MetadataRetriever计算。Media3 ChannelMixingAudioProcessor与SonicAudioProcessor完成声道/采样率处理；FrameDropEffect处理目标帧率。源帧率未知时保持，不假造30fps。Apple与FFmpeg探测返回同类参数。

超限视频先选择兼容优先、录屏清晰优先、体积优先。录屏模式提高分辨率预算并限制到15fps，体积优先HEVC失败回退H.264；不按文件名猜录屏。当前仍是码率门槛选分辨率，不分析画面内容，不能宣称所有素材最佳质量，亦不能以此代替Android播放器裁切问题的验证。

取消令牌贯穿准备、探测和轮次间隙；准备异常转换为失败结果。Apple泵等待周期检查取消和失败状态，避免writer取消后不再触发ready回调而永久等待。

验证：Flutter3.47.4媒体/上传/播放器26项测试；Android :app:compileDebugKotlin通过；macOS完整Debug构建通过。iOS arm64模拟器完整Debug构建通过；真实编码质量及播放器边缘仍需真机回归。

## iOS 模拟器构建架构

`native_animated_image_ios` 当前随包的 XCFramework 只有 `ios-arm64` 和 `ios-arm64-simulator`，没有 x86_64 模拟器切片。通用模拟器目标同时构建 arm64/x86_64 时，CocoaPods 的切片选择会跳过此 framework，最后报 `framework native_animated_image_codec not found`。这不是文件缺失。

Apple Silicon 验证命令：

```sh
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

不要修改生成的 Pods 脚本或 pub 缓存。若需要 Intel 模拟器支持，应在插件上游构建真正的 x86_64 模拟器库并将其与 arm64 模拟器库合并成通用切片，再重新发布 XCFramework；只修改 Info.plist 的架构声明无法补齐二进制。
