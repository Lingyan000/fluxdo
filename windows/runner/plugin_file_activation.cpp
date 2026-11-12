#include "plugin_file_activation.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <memory>
#include <utility>

namespace {
constexpr ULONG_PTR kPluginFileMessage = 0x46504c47;
constexpr size_t kMaxPathBytes = 128 * 1024;
std::vector<std::string> pending_files;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;

bool IsPluginPath(const std::string& path) {
  constexpr char extension[] = ".fluxplugin";
  if (path.size() < sizeof(extension) - 1 || path.size() > kMaxPathBytes) {
    return false;
  }
  auto suffix = path.substr(path.size() - (sizeof(extension) - 1));
  std::transform(suffix.begin(), suffix.end(), suffix.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return suffix == extension;
}
}  // namespace

bool ForwardPluginFilesToInstance(const std::vector<std::string>& arguments) {
  if (arguments.empty() ||
      !std::all_of(arguments.begin(), arguments.end(), IsPluginPath)) {
    return false;
  }
  const HWND target = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"FluxDO");
  if (!target) return false;

  // 整批确认，避免后续文件发送失败时冷启动重复导入已转发的文件。
  std::string payload;
  for (const auto& path : arguments) {
    payload.append(path).push_back('\0');
  }
  if (payload.size() > kMaxPathBytes) return false;
  COPYDATASTRUCT data{};
  data.dwData = kPluginFileMessage;
  data.cbData = static_cast<DWORD>(payload.size());
  data.lpData = payload.data();
  DWORD_PTR accepted = 0;
  if (!::SendMessageTimeout(target, WM_COPYDATA, 0,
                            reinterpret_cast<LPARAM>(&data),
                            SMTO_ABORTIFHUNG, 3000, &accepted) || !accepted) {
    return false;
  }
  ::ShowWindow(target, ::IsIconic(target) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(target);
  return true;
}

void RegisterPluginFiles(flutter::BinaryMessenger* messenger) {
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.fluxdo/plugin_files",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "takePendingFiles") {
      result->NotImplemented();
      return;
    }
    flutter::EncodableList files;
    for (const auto& path : pending_files) files.emplace_back(path);
    pending_files.clear();
    result->Success(flutter::EncodableValue(std::move(files)));
  });
}

void DisposePluginFiles() { channel.reset(); }

bool ReceivePluginFileMessage(UINT message, LPARAM parameter) {
  if (message != WM_COPYDATA || !parameter) return false;
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(parameter);
  if (data->dwData != kPluginFileMessage || !data->lpData ||
      data->cbData < 2 || data->cbData > kMaxPathBytes) return false;
  const auto* text = static_cast<const char*>(data->lpData);
  if (text[data->cbData - 1] != '\0') return false;
  std::vector<std::string> paths;
  for (size_t offset = 0; offset < data->cbData;) {
    const std::string path(text + offset);
    if (!IsPluginPath(path)) return false;
    paths.push_back(path);
    offset += path.size() + 1;
  }
  pending_files.insert(pending_files.end(), paths.begin(), paths.end());
  if (channel) channel->InvokeMethod("filesAvailable", nullptr);
  return true;
}
