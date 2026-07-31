#include "texture_bridge.h"

#include <windows.foundation.h>

#include <algorithm>
#include <atomic>
#include <cassert>
#include <iostream>

#include "util/direct3d11.interop.h"

namespace flutter_inappwebview_plugin
{
  const int kNumBuffers = 1;

  TextureBridge::TextureBridge(GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : graphics_context_(graphics_context)
  {
    capture_item_ =
      graphics_context_->CreateGraphicsCaptureItemFromVisual(visual);
    assert(capture_item_);

    capture_item_->add_Closed(
      Microsoft::WRL::Callback<ABI::Windows::Foundation::ITypedEventHandler<
      ABI::Windows::Graphics::Capture::GraphicsCaptureItem*,
      IInspectable*>>(
        [](ABI::Windows::Graphics::Capture::IGraphicsCaptureItem* item,
          IInspectable* args) -> HRESULT
        {
          std::cerr << "Capture item was closed." << std::endl;
          return S_OK;
        })
      .Get(),
          &on_closed_token_);
  }

  TextureBridge::~TextureBridge()
  {
    Stop();
    auto capture_item = capture_item_;
    if (capture_item) {
      capture_item->remove_Closed(on_closed_token_);
    }
  }

  void TextureBridge::SetOnFrameAvailable(FrameAvailableCallback callback)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    frame_available_ = std::move(callback);
  }

  bool TextureBridge::Start()
  {
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
      capture_item;
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      if (is_running_ || is_starting_ || !capture_item_) {
        return false;
      }
      is_starting_ = true;
      capture_item = capture_item_;
    }

    ABI::Windows::Graphics::SizeInt32 size;
    if (FAILED(capture_item->get_Size(&size))) {
      const std::lock_guard<std::mutex> lock(mutex_);
      is_starting_ = false;
      return false;
    }

    auto frame_pool = graphics_context_->CreateCaptureFramePool(
      graphics_context_->device(),
      static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
        kPixelFormat),
      kNumBuffers, size);
    if (!frame_pool) {
      const std::lock_guard<std::mutex> lock(mutex_);
      is_starting_ = false;
      return false;
    }

    EventRegistrationToken frame_arrived_token = {};
    frame_pool->add_FrameArrived(
      Microsoft::WRL::Callback<ABI::Windows::Foundation::ITypedEventHandler<
      ABI::Windows::Graphics::Capture::Direct3D11CaptureFramePool*,
      IInspectable*>>(
        [this](ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool*
          pool,
          IInspectable* args) -> HRESULT
        {
          OnFrameArrived();
          return S_OK;
        })
      .Get(),
          &frame_arrived_token);

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession>
      capture_session;
    if (FAILED(frame_pool->CreateCaptureSession(capture_item.get(),
      capture_session.put()))) {
      std::cerr << "Creating capture session failed." << std::endl;
      frame_pool->remove_FrameArrived(frame_arrived_token);
      const std::lock_guard<std::mutex> lock(mutex_);
      is_starting_ = false;
      return false;
    }

    const bool started = SUCCEEDED(capture_session->StartCapture());
    bool keep_session = false;
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      if (is_starting_ && started) {
        frame_pool_ = frame_pool;
        capture_session_ = capture_session;
        on_frame_arrived_token_ = frame_arrived_token;
        is_running_ = true;
        keep_session = true;
      }
      is_starting_ = false;
    }
    if (keep_session) return true;

    frame_pool->remove_FrameArrived(frame_arrived_token);
    if (auto closable = capture_session.try_as<
      ABI::Windows::Foundation::IClosable>()) {
      closable->Close();
    }
    return false;
  }

  void TextureBridge::Stop()
  {
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureSession>
      capture_session;
    EventRegistrationToken frame_arrived_token = {};
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      is_starting_ = false;
      is_running_ = false;
      frame_pool = std::move(frame_pool_);
      capture_session = std::move(capture_session_);
      frame_arrived_token = on_frame_arrived_token_;
      on_frame_arrived_token_ = {};
      last_frame_ = nullptr;
      StopInternal();
    }

    // WebView2/WinRT Close 可能等待正在执行的 FrameArrived 回调。绝不能
    // 在持有 mutex_ 时关闭，否则回调反向等待同一把锁会冻住 Win32 消息泵。
    if (frame_pool) {
      frame_pool->remove_FrameArrived(frame_arrived_token);
    }
    if (capture_session) {
      if (auto closable = capture_session.try_as<
        ABI::Windows::Foundation::IClosable>()) {
        closable->Close();
      }
    }
  }

  void TextureBridge::StopInternal()
  {
    // 基类没有额外轻量状态。COM 资源由 Stop() 移出锁后关闭。
  }

  void TextureBridge::OnFrameArrived()
  {
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFramePool>
      frame_pool;
    winrt::com_ptr<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>
      capture_item;
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      if (!is_running_ || !frame_pool_) return;
      frame_pool = frame_pool_;
      capture_item = capture_item_;
    }

    winrt::com_ptr<ABI::Windows::Graphics::Capture::IDirect3D11CaptureFrame>
      frame;
    winrt::com_ptr<ID3D11Texture2D> frame_texture;
    auto hr = frame_pool->TryGetNextFrame(frame.put());
    if (SUCCEEDED(hr) && frame) {
      winrt::com_ptr<
        ABI::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface>
        frame_surface;

      if (SUCCEEDED(frame->get_Surface(frame_surface.put()))) {
        frame_texture =
          TryGetDXGIInterfaceFromObject<ID3D11Texture2D>(frame_surface);
      }
    }

    if (needs_update_.exchange(false) && capture_item) {
      ABI::Windows::Graphics::SizeInt32 size;
      if (SUCCEEDED(capture_item->get_Size(&size))) {
        frame_pool->Recreate(
          graphics_context_->device(),
          static_cast<ABI::Windows::Graphics::DirectX::DirectXPixelFormat>(
            kPixelFormat),
          kNumBuffers, size);
      }
    }

    FrameAvailableCallback frame_available;
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      if (!is_running_) return;
      if (frame_texture) {
        last_frame_ = frame_texture;
        if (!ShouldDropFrame()) frame_available = frame_available_;
      }
    }
    // MarkTextureFrameAvailable 会进入 Flutter texture registrar，必须离锁。
    if (frame_available) frame_available();
  }

  bool TextureBridge::ShouldDropFrame()
  {
    if (!frame_duration_.has_value()) {
      return false;
    }
    auto now = std::chrono::high_resolution_clock::now();

    bool should_drop_frame = false;
    if (last_frame_timestamp_.has_value()) {
      auto diff = std::chrono::duration_cast<std::chrono::milliseconds>(
        now - last_frame_timestamp_.value());
      should_drop_frame = diff < frame_duration_.value();
    }

    if (!should_drop_frame) {
      last_frame_timestamp_ = now;
    }
    return should_drop_frame;
  }

  void TextureBridge::NotifySurfaceSizeChanged()
  {
    needs_update_ = true;
  }

  void TextureBridge::SetFpsLimit(std::optional<int> max_fps)
  {
    const std::lock_guard<std::mutex> lock(mutex_);
    auto value = max_fps.value_or(0);
    if (value != 0) {
      frame_duration_ = FrameDuration(1000.0 / value);
    }
    else {
      frame_duration_.reset();
      last_frame_timestamp_.reset();
    }
  }
}
