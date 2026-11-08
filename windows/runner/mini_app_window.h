#ifndef FLUXDO_MINI_APP_WINDOW_H_
#define FLUXDO_MINI_APP_WINDOW_H_

#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <memory>
#include <string>
#include <algorithm>
#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <dynamic_color/dynamic_color_plugin_c_api.h>
#include <flutter_avif_windows/flutter_avif_windows_plugin.h>
#include <flutter_inappwebview_windows/flutter_inappwebview_windows_plugin_c_api.h>
#include <flutter_timezone/flutter_timezone_plugin_c_api.h>
#include <irondash_engine_context/irondash_engine_context_plugin_c_api.h>
#include <share_plus/share_plus_windows_plugin_c_api.h>
#include <super_native_extensions/super_native_extensions_plugin_c_api.h>
#include <url_launcher_windows/url_launcher_windows.h>

// 仅注册运行页需要的插件。旧 window_manager/acrylic 的全局窗口状态
// 不应由子引擎再次接管；子窗口的显示和全屏由下面的所属窗口通道处理。
inline void RegisterMiniAppWindowPlugins(flutter::PluginRegistry* registry) {
  DesktopMultiWindowPluginRegisterWithRegistrar(registry->GetRegistrarForPlugin("DesktopMultiWindowPlugin"));
  DynamicColorPluginCApiRegisterWithRegistrar(registry->GetRegistrarForPlugin("DynamicColorPluginCApi"));
  FlutterAvifWindowsPluginRegisterWithRegistrar(registry->GetRegistrarForPlugin("FlutterAvifWindowsPlugin"));
  FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar(registry->GetRegistrarForPlugin("FlutterInappwebviewWindowsPluginCApi"));
  FlutterTimezonePluginCApiRegisterWithRegistrar(registry->GetRegistrarForPlugin("FlutterTimezonePluginCApi"));
  IrondashEngineContextPluginCApiRegisterWithRegistrar(registry->GetRegistrarForPlugin("IrondashEngineContextPluginCApi"));
  SharePlusWindowsPluginCApiRegisterWithRegistrar(registry->GetRegistrarForPlugin("SharePlusWindowsPluginCApi"));
  SuperNativeExtensionsPluginCApiRegisterWithRegistrar(registry->GetRegistrarForPlugin("SuperNativeExtensionsPluginCApi"));
  UrlLauncherWindowsRegisterWithRegistrar(registry->GetRegistrarForPlugin("UrlLauncherWindows"));
}

// 通道绑定所属 Flutter HWND；多窗口全屏不能误操作社区主窗口。
inline void RegisterMiniAppWindow(flutter::FlutterViewController* controller) {
  struct State {
    HWND window;
    bool fullscreen = false;
    LONG_PTR style = 0;
    WINDOWPLACEMENT placement{sizeof(WINDOWPLACEMENT)};
  };
  auto state = std::make_shared<State>();
  state->window = GetAncestor(controller->view()->GetNativeWindow(), GA_ROOT);
  flutter::MethodChannel<flutter::EncodableValue> channel(
      controller->engine()->messenger(), "com.fluxdo/mini_app_window_controls",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler([state](const auto& call, auto result) {
    HWND window = state->window;
    if (!IsWindow(window)) { result->Error("WINDOW_CLOSED"); return; }
    const auto& method = call.method_name();
    if (method == "show") {
      ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
      SetForegroundWindow(window);
    } else if (method == "configure") {
      const auto* title = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (title) {
        int count = MultiByteToWideChar(CP_UTF8, 0, title->data(), static_cast<int>(title->size()), nullptr, 0);
        std::wstring wide(count, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, title->data(), static_cast<int>(title->size()), wide.data(), count);
        SetWindowText(window, wide.c_str());
      }
      MONITORINFO monitor{sizeof(MONITORINFO)};
      GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor);
      const int width = (std::min)(1000, static_cast<int>(monitor.rcWork.right - monitor.rcWork.left));
      const int height = (std::min)(760, static_cast<int>(monitor.rcWork.bottom - monitor.rcWork.top));
      SetWindowPos(window, nullptr, monitor.rcWork.left + (monitor.rcWork.right - monitor.rcWork.left - width) / 2,
          monitor.rcWork.top + (monitor.rcWork.bottom - monitor.rcWork.top - height) / 2, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
    } else if (method == "isFullscreen") {
      result->Success(flutter::EncodableValue(state->fullscreen)); return;
    } else if (method == "fullscreen") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) { result->Error("INVALID_ARGUMENT"); return; }
      if (*enabled != state->fullscreen) {
        state->fullscreen = *enabled;
        if (*enabled) {
          state->style = GetWindowLongPtr(window, GWL_STYLE);
          GetWindowPlacement(window, &state->placement);
          MONITORINFO monitor{sizeof(MONITORINFO)};
          GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor);
          SetWindowLongPtr(window, GWL_STYLE, state->style & ~WS_OVERLAPPEDWINDOW);
          SetWindowPos(window, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
              monitor.rcMonitor.right - monitor.rcMonitor.left, monitor.rcMonitor.bottom - monitor.rcMonitor.top,
              SWP_FRAMECHANGED);
        } else {
          SetWindowLongPtr(window, GWL_STYLE, state->style);
          SetWindowPlacement(window, &state->placement);
          SetWindowPos(window, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        }
      }
    } else if (method == "close") {
      // 下一次消息循环销毁引擎，先让当前 Dart 请求正常结束。
      PostMessage(window, WM_CLOSE, 0, 0);
    } else { result->NotImplemented(); return; }
    result->Success();
  });
}
#endif
