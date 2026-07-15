#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

// 深链启动(discourse:// / fluxdo://)时把 URL 转发给已运行实例并退出,
// 避免为一次授权回调开出第二个窗口(app_links 官方集成方式)。
// 仅对携带 scheme 链接的启动生效,普通启动的多开行为不变。
// 窗口标题固定为下方 Create 的 L"FluxDO",Dart 侧无 setTitle 调用。
static bool SendAppLinkToInstance(const wchar_t* command_line) {
  if (command_line == nullptr ||
      (::wcsstr(command_line, L"discourse://") == nullptr &&
       ::wcsstr(command_line, L"fluxdo://") == nullptr)) {
    return false;
  }

  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"FluxDO");
  if (hwnd == nullptr) {
    return false;
  }

  // 把本进程命令行里的链接派发给该窗口(app_links 插件接收)
  SendAppLink(hwnd);

  // 把已运行实例带回前台
  WINDOWPLACEMENT place = {sizeof(WINDOWPLACEMENT)};
  ::GetWindowPlacement(hwnd, &place);
  switch (place.showCmd) {
    case SW_SHOWMAXIMIZED:
      ::ShowWindow(hwnd, SW_SHOWMAXIMIZED);
      break;
    case SW_SHOWMINIMIZED:
      ::ShowWindow(hwnd, SW_RESTORE);
      break;
    default:
      ::ShowWindow(hwnd, SW_NORMAL);
      break;
  }
  ::SetForegroundWindow(hwnd);
  return true;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (SendAppLinkToInstance(command_line)) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"FluxDO", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
