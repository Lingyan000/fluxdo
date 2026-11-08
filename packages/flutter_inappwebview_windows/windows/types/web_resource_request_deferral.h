#ifndef FLUTTER_INAPPWEBVIEW_WEB_RESOURCE_REQUEST_DEFERRAL_H_
#define FLUTTER_INAPPWEBVIEW_WEB_RESOURCE_REQUEST_DEFERRAL_H_

#include <WebView2.h>
#include <wil/com.h>
#include <utility>

namespace flutter_inappwebview_plugin {
// Dart 异步回执到达时，原 COM 事件已经返回。必须同时保留事件参数和
// deferral，不能只保留 deferral 后在回调中解引用失效的 args 裸指针。
class WebResourceRequestDeferral {
 public:
  explicit WebResourceRequestDeferral(ICoreWebView2WebResourceRequestedEventArgs* args)
      : args_(args) {
    if (args_) args_->GetDeferral(&deferral_);
  }
  ~WebResourceRequestDeferral() { Complete(); }
  bool valid() const { return deferral_ != nullptr; }
  void Complete(ICoreWebView2WebResourceResponse* response = nullptr) {
    if (!deferral_) return;
    // Complete 可能触发后续消息，先移出状态保证重入/多次结束只执行一次。
    auto deferral = std::move(deferral_);
    auto args = std::move(args_);
    if (response) args->put_Response(response);
    deferral->Complete();
  }

 private:
  wil::com_ptr<ICoreWebView2WebResourceRequestedEventArgs> args_;
  wil::com_ptr<ICoreWebView2Deferral> deferral_;
};
}  // namespace flutter_inappwebview_plugin
#endif
