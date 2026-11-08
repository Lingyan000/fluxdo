#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <set>

#include "../utils/util.h"
#include "channel_delegate.h"

namespace flutter_inappwebview_plugin
{
  namespace {
    // 通道和插件均在所属引擎的平台线程创建/销毁，不跨线程使用此状态。
    thread_local std::multiset<flutter::BinaryMessenger*> shuttingDownMessengers;
  }

  ChannelDelegate::ShutdownScope::ShutdownScope(flutter::BinaryMessenger* messenger)
    : messenger_(messenger) {
    shuttingDownMessengers.insert(messenger_);
  }

  ChannelDelegate::ShutdownScope::~ShutdownScope() {
    shuttingDownMessengers.erase(shuttingDownMessengers.find(messenger_));
  }

  ChannelDelegate::ChannelDelegate(flutter::BinaryMessenger* messenger, const std::string& name) : messenger(messenger)
  {
    channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      this->messenger, name,
      &flutter::StandardMethodCodec::GetInstance()
    );
    channel->SetMethodCallHandler(
      [this](const auto& call, auto result)
      {
        this->HandleMethodCall(call, std::move(result));
      });
  }

  void ChannelDelegate::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {}

  void ChannelDelegate::UnregisterMethodCallHandler() const
  {
    if (channel && shuttingDownMessengers.find(messenger) == shuttingDownMessengers.end()) {
      channel->SetMethodCallHandler(nullptr);
    }
  }

  ChannelDelegate::~ChannelDelegate()
  {
    messenger = nullptr;
    channel.reset();
  }
}
