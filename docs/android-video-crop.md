# Android 旋转视频边缘兼容修复

样本：原片 1200×2608、无旋转；Android 压缩输出 HEVC 720×330、90°旋转，显示为330×720。同机系统播放器正常，FluxDO出现侧边异常；macOS AVFoundation抽帧未见异常。

## 源码依据

核查项目 .fvmrc 指定 Flutter 3.47.4（不是机器默认3.44.0）：

- FlutterRenderer.createSurfaceProducer 在符合条件的 Android API29+ 使用 ImageReaderSurfaceProducer，其 handlesCropAndRotation 返回false。
- video_player_android 2.12.2 TextureExoPlayerEventListener 传回旋转修正；Dart VideoPlayer 使用RotatedBox。未传递有效画面crop。
- Flutter image_external_texture.cc绘制整张DlImage；Vulkan路径从AHardwareBuffer尺寸创建纹理。

这些证明裁切处理缺口，但尚未从问题真机取得实际buffer/crop数据，不能断言具体填充宽度。

## 处理

Android通过VideoViewType.platformView使用原生SurfaceView，绕开上述ImageReader纹理路径；其他平台保持textureView。不改视频、不固定裁边、不启用Vulkan下行为未定义的debugForceSurfaceProducerGlTextures。

上游已知平台视图屏外覆盖问题：https://github.com/flutter/flutter/issues/164899 （经smart-search fetch获取）。VideoPlaybackSurface用VisibilityDetector在屏外卸载表面并暂停，回到视口重挂同一控制器；现有全屏单视图逻辑继续复用。可见性通知存在延迟，真实设备仍需检查滚出视口及路由覆盖，不宣称完全消除了上游问题。

## 验证

Flutter3.47.4：test/widgets/media_player 覆盖平台选择及屏外卸载/重挂；test/services/media_compressor_test.dart覆盖站点附件上限预算。

Widget测试没有创建真实Android Surface，不能替代真机。需检查样本内联/全屏的边缘、方向、比例，滚出滚回、切页、暂停后回全屏、播放器上方控件及手势。尚未构建或执行Android真机验证。
