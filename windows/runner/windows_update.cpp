#include "windows_update.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace {
constexpr wchar_t kUninstallKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"
    L"{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}_is1";

std::filesystem::path ApplicationDirectory() {
  std::vector<wchar_t> path(32768);
  const DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                         static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) return {};
  return std::filesystem::path(std::wstring(path.data(), length)).parent_path();
}

// 读取安装记录，不能仅凭 unins000.exe 判断权限或误更新另一份安装。
bool MatchesInstallation(HKEY root, const std::filesystem::path& directory) {
  for (const REGSAM view : {KEY_WOW64_64KEY, KEY_WOW64_32KEY}) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(root, kUninstallKey, 0, KEY_QUERY_VALUE | view, &key) !=
        ERROR_SUCCESS) continue;
    std::vector<wchar_t> location(32768, L'\0');
    DWORD bytes = static_cast<DWORD>(location.size() * sizeof(wchar_t));
    const auto status = RegGetValueW(key, nullptr, L"InstallLocation",
                                    RRF_RT_REG_SZ, nullptr, location.data(),
                                    &bytes);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) continue;
    std::error_code error;
    if (std::filesystem::equivalent(directory, location.data(), error) &&
        !error) return true;
  }
  return false;
}

std::optional<bool> IsMachineInstallation(const std::filesystem::path& dir) {
  if (dir.empty()) return std::nullopt;
  if (MatchesInstallation(HKEY_CURRENT_USER, dir)) return false;
  if (MatchesInstallation(HKEY_LOCAL_MACHINE, dir)) return true;
  return std::nullopt;
}

struct InstallerProcess {
  HANDLE handle = nullptr;
  ~InstallerProcess() { if (handle) CloseHandle(handle); }
};
}  // namespace

void RegisterWindowsUpdate(flutter::BinaryMessenger* messenger, HWND window) {
  flutter::MethodChannel<flutter::EncodableValue> channel(
      messenger, "com.fluxdo/windows_update",
      &flutter::StandardMethodCodec::GetInstance());
  const auto process = std::make_shared<InstallerProcess>();
  channel.SetMethodCallHandler(
      [window, process](const auto& call, auto result) {
        const auto directory = ApplicationDirectory();
        const auto machine_install = IsMachineInstallation(directory);
        if (call.method_name() == "isInstalled") {
          result->Success(flutter::EncodableValue(machine_install.has_value()));
          return;
        }
        if (call.method_name() == "getUpdateExitCode") {
          DWORD exit_code = 0;
          if (!process->handle ||
              !GetExitCodeProcess(process->handle, &exit_code)) {
            result->Error("installer_missing", "Installer process is unavailable.");
          } else if (WaitForSingleObject(process->handle, 0) == WAIT_TIMEOUT) {
            result->Success();
          } else {
            result->Success(flutter::EncodableValue(static_cast<int>(exit_code)));
          }
          return;
        }
        if (call.method_name() != "startUpdate") {
          result->NotImplemented();
          return;
        }
        if (!machine_install.has_value()) {
          result->Error("not_installed", "No matching FluxDO installation.");
          return;
        }
        if (process->handle &&
            WaitForSingleObject(process->handle, 0) == WAIT_TIMEOUT) {
          result->Error("installer_running", "An update is already running.");
          return;
        }
        const auto* path = call.arguments()
            ? std::get_if<std::string>(call.arguments()) : nullptr;
        if (!path) {
          result->Error("invalid_installer", "Missing installer path.");
          return;
        }
        const auto installer = std::filesystem::u8path(*path);
        std::error_code error;
        if (!installer.is_absolute() || installer.extension() != L".exe" ||
            !std::filesystem::is_regular_file(installer, error) || error) {
          result->Error("invalid_installer", "Installer file is unavailable.");
          return;
        }
        // open 保留原用户令牌，由 Inno Setup 自行提权，更新后不会以管理员运行应用。
        const std::wstring parameters =
            L"/SILENT /SP- /NORESTART /NORESTARTAPPLICATIONS /NOFORCECLOSEAPPLICATIONS"
            L" /UPDATE=1 /UPDATEPID=" + std::to_wstring(GetCurrentProcessId()) +
            L" /UPDATEHWND=" + std::to_wstring(reinterpret_cast<UINT_PTR>(window)) +
            L" /DIR=\"" + directory.wstring() + L"\" /LOG" +
            (*machine_install ? L" /ALLUSERS" : L" /CURRENTUSER");
        SHELLEXECUTEINFOW info{};
        info.cbSize = sizeof(info);
        info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
        info.hwnd = window;
        info.lpVerb = L"open";
        info.lpFile = installer.c_str();
        info.lpParameters = parameters.c_str();
        info.nShow = SW_SHOWNORMAL;
        if (!ShellExecuteExW(&info) || !info.hProcess) {
          result->Error("installer_launch_failed",
                        "Cannot start installer (" +
                            std::to_string(GetLastError()) + ").");
          return;
        }
        if (process->handle) CloseHandle(process->handle);
        process->handle = info.hProcess;
        result->Success();
      });
}
