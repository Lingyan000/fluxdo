#include "texture_bridge_gpu.h"

#include <iostream>

#include "util/direct3d11.interop.h"

namespace flutter_inappwebview_plugin
{
  TextureBridgeGpu::TextureBridgeGpu(
    GraphicsContext* graphics_context,
    ABI::Windows::UI::Composition::IVisual* visual)
    : TextureBridge(graphics_context, visual)
  {
    surface_descriptor_.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    surface_descriptor_.format =
      kFlutterDesktopPixelFormatNone;  // no format required for DXGI surfaces
  }

  TextureBridgeGpu::~TextureBridgeGpu()
  {
    // 派生类 D3D 成员销毁前先停 capture，避免 FrameArrived 回调访问半析构对象。
    Stop();
  }

  void TextureBridgeGpu::ProcessFrame(
    winrt::com_ptr<ID3D11Texture2D> src_texture)
  {
    D3D11_TEXTURE2D_DESC desc;
    src_texture->GetDesc(&desc);

    const auto width = desc.Width;
    const auto height = desc.Height;

    EnsureSurface(width, height);

    auto device_context = graphics_context_->d3d_device_context();

    device_context->CopyResource(surface_.get(), src_texture.get());
    device_context->Flush();
  }

  void TextureBridgeGpu::EnsureSurface(uint32_t width, uint32_t height)
  {
    if (!surface_ || surface_size_.width != width ||
      surface_size_.height != height) {
      D3D11_TEXTURE2D_DESC dstDesc = {};
      dstDesc.ArraySize = 1;
      dstDesc.MipLevels = 1;
      dstDesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
      dstDesc.CPUAccessFlags = 0;
      dstDesc.Format = static_cast<DXGI_FORMAT>(kPixelFormat);
      dstDesc.Width = width;
      dstDesc.Height = height;
      dstDesc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
      dstDesc.SampleDesc.Count = 1;
      dstDesc.SampleDesc.Quality = 0;
      dstDesc.Usage = D3D11_USAGE_DEFAULT;

      surface_ = nullptr;
      if (!SUCCEEDED(graphics_context_->d3d_device()->CreateTexture2D(
        &dstDesc, nullptr, surface_.put()))) {
        std::cerr << "Creating intermediate texture failed" << std::endl;
        return;
      }

      HANDLE shared_handle;
      surface_.try_as(dxgi_surface_);
      assert(dxgi_surface_);
      dxgi_surface_->GetSharedHandle(&shared_handle);

      surface_descriptor_.handle = shared_handle;
      surface_descriptor_.width = surface_descriptor_.visible_width = width;
      surface_descriptor_.height = surface_descriptor_.visible_height = height;
      surface_descriptor_.release_context = surface_.get();
      surface_descriptor_.release_callback = [](void* release_context)
        {
          auto texture = reinterpret_cast<ID3D11Texture2D*>(release_context);
          texture->Release();
        };

      surface_size_ = { width, height };
    }
  }

  const FlutterDesktopGpuSurfaceDescriptor*
    TextureBridgeGpu::GetSurfaceDescriptor(size_t width, size_t height)
  {
    winrt::com_ptr<ID3D11Texture2D> frame;
    {
      const std::lock_guard<std::mutex> lock(mutex_);
      if (!is_running_) return nullptr;
      frame = last_frame_;
    }

    // CopyResource/Flush 在 Intel 驱动 fence 上可能阻塞几十秒。它只能发生
    // 在 Flutter raster 线程，不能持有平台线程生命周期也需要的 mutex_。
    if (reset_surface_requested_.exchange(false)) {
      surface_ = nullptr;
    }
    if (frame) {
      ProcessFrame(frame);
    }

    {
      const std::lock_guard<std::mutex> lock(mutex_);
      if (!is_running_) return nullptr;
    }
    // Stop -> Start 后、首个新帧到达前 surface_ 为空。此时 descriptor 仍
    // 保存上一代共享句柄，绝不能把悬垂 handle/release_context 交给 Flutter。
    if (!surface_) return nullptr;

    // Gets released in the SurfaceDescriptor's release callback.
    surface_->AddRef();

    return &surface_descriptor_;
  }

  void TextureBridgeGpu::StopInternal()
  {
    TextureBridge::StopInternal();
    // surface_ 只由 raster 线程访问。平台线程仅投递重建请求，避免与锁外的
    // CopyResource/Flush 发生数据竞争。
    reset_surface_requested_ = true;
  }
}
