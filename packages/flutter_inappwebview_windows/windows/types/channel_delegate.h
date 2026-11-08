#ifndef FLUTTER_INAPPWEBVIEW_PLUGIN_CHANNEL_DELEGATE_H_
#define FLUTTER_INAPPWEBVIEW_PLUGIN_CHANNEL_DELEGATE_H_

#include <flutter/method_channel.h>

namespace flutter_inappwebview_plugin
{
  class ChannelDelegate
  {
    using FlutterMethodChannel = std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>>;

  public:
    // 引擎析构回调到达时 Flutter messenger 已不再关联运行中的 engine。
    // 按 messenger 隔离清理范围，关闭独立窗口不影响其他窗口的通道。
    class ShutdownScope {
    public:
      explicit ShutdownScope(flutter::BinaryMessenger* messenger);
      ~ShutdownScope();
      ShutdownScope(const ShutdownScope&) = delete;
      ShutdownScope& operator=(const ShutdownScope&) = delete;
    private:
      flutter::BinaryMessenger* messenger_;
    };

    FlutterMethodChannel channel;
    flutter::BinaryMessenger* messenger;

    ChannelDelegate(flutter::BinaryMessenger* messenger, const std::string& name);
    virtual ~ChannelDelegate();

    virtual void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    void UnregisterMethodCallHandler() const;
  };
}

#endif //FLUTTER_INAPPWEBVIEW_PLUGIN_CHANNEL_DELEGATE_H_
