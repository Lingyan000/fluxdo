#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_BASE_CALLBACK_RESULT_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_BASE_CALLBACK_RESULT_H_

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <optional>

namespace flutter_inappwebview_plugin
{
  template <typename T>
  class BaseCallbackResult : public flutter::MethodResultFunctions<flutter::EncodableValue>
  {
  public:
    flutter::ResultHandlerError<flutter::EncodableValue> error;
    flutter::ResultHandlerNotImplemented<flutter::EncodableValue> notImplemented;
    std::function<bool(const T result)> nonNullSuccess = [](const T result) { return true; };
    std::function<bool()> nullSuccess = []() { return true; };
    std::function<void(const std::optional<T> result)> defaultBehaviour = [](const std::optional<T> result) {};
    std::function<std::optional<T>(const flutter::EncodableValue* result)> decodeResult = [](const flutter::EncodableValue* result) { return std::nullopt; };
    // 所属 WebView 的存活标记。Dart 侧回执可能在 WebView 析构后才到达,
    // 此时 nonNullSuccess/defaultBehaviour 等捕获的裸 this 已悬空,
    // 必须在入口整体拦截,否则会跳进已释放内存(0xc0000005)。
    std::shared_ptr<bool> aliveGuard;

    BaseCallbackResult<T>() :
      MethodResultFunctions(
        [this](const flutter::EncodableValue* val)
        {
          if (aliveGuard && !*aliveGuard) {
            return;
          }
          std::optional<T> result = decodeResult ? decodeResult(val) : std::nullopt;
          auto shouldRunDefaultBehaviour = false;
          if (result.has_value()) {
            shouldRunDefaultBehaviour = nonNullSuccess ? nonNullSuccess(result.value()) : shouldRunDefaultBehaviour;
          }
          else {
            shouldRunDefaultBehaviour = nullSuccess ? nullSuccess() : shouldRunDefaultBehaviour;
          }
          if (shouldRunDefaultBehaviour && defaultBehaviour) {
            defaultBehaviour(result);
          }
        },
        [this](const std::string& error_code, const std::string& error_message, const flutter::EncodableValue* error_details)
        {
          if (aliveGuard && !*aliveGuard) {
            return;
          }
          if (error) {
            error(error_code, error_message, error_details);
          }
        },
        [this]()
        {
          if (aliveGuard && !*aliveGuard) {
            return;
          }
          if (defaultBehaviour) {
            defaultBehaviour(std::nullopt);
          }
          if (notImplemented) {
            notImplemented();
          }
        })
    {};
    virtual ~BaseCallbackResult<T>() {};
  };
}

#endif //FLUTTER_INAPPWEBVIEW_PLUGIN_BASE_CALLBACK_RESULT_H_