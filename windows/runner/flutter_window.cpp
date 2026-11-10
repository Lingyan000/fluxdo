#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "mini_app_window.h"
#include "windows_update.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // 主消息循环结束时也必须先清空成员，再析构可能产生窗口消息的插件。
  OnDestroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterWindowsUpdate(flutter_controller_->engine()->messenger(), GetHandle());
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* child = reinterpret_cast<flutter::FlutterViewController*>(controller);
    RegisterMiniAppWindowPlugins(child->engine());
    RegisterMiniAppWindow(child);
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  return true;
}

void FlutterWindow::OnDestroy() {
  // 销毁插件/WebView 子窗口会同步重入父窗口消息。先移出成员，避免
  // MessageHandler 向正在析构、内部 view 已为空的 controller 转发消息。
  auto controller = std::move(flutter_controller_);
  controller.reset();

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_ && flutter_controller_->view()) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
