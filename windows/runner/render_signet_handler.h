#ifndef RUNNER_RENDER_SIGNET_HANDLER_H_
#define RUNNER_RENDER_SIGNET_HANDLER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// 窗口级渲染帧标识印记层(Windows Composition 后端)。
//
// Dart 侧(lib/widgets/render_signet/)是编码单一真相:两张 RGBA 图块经
// `com.fluxdo/render_signet` 通道下发,这里只做「平铺 + 混合」——
// DesktopWindowTarget(topmost) 上两个 SpriteVisual,各挂一个
// D2D1 Blend 效果刷(Multiply ≙ modulate 笔、LinearDodge ≙ plus 笔,
// 先乘后加顺序契约与 Dart painter 一致),背景输入为 BackdropBrush。
//
// 下沉动机与 macOS 不同:Windows 的 Flutter 是 Skia+ANGLE 无
// partial repaint,内联印记的两笔全屏 dst-read 混合每帧全额支付,
// 4K+核显实测卡顿;交给 DWM 合成端做,增量成本接近零。
class RenderSignetHandler {
 public:
  RenderSignetHandler();
  ~RenderSignetHandler();

  RenderSignetHandler(const RenderSignetHandler&) = delete;
  RenderSignetHandler& operator=(const RenderSignetHandler&) = delete;

  // 在平台线程调用(FlutterWindow::OnCreate)。
  void Register(flutter::BinaryMessenger* messenger, HWND hwnd);

  // WM_SIZE 时重铺印记面(drawing surface 尺寸随客户区走)。
  void OnWindowResized();

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_RENDER_SIGNET_HANDLER_H_
