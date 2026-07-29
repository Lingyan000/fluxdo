#include "render_signet_handler.h"

#include <DispatcherQueue.h>
#include <d2d1_1.h>
#include <d2d1effects_2.h>
#include <d3d11.h>
#include <windows.foundation.h>
#include <windows.graphics.effects.interop.h>
#include <windows.ui.composition.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.Effects.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.Composition.Desktop.h>
#include <winrt/Windows.UI.Composition.h>

#include <flutter/standard_method_codec.h>

#include <utility>
#include <vector>

namespace {

namespace wf = winrt::Windows::Foundation;
namespace wge = winrt::Windows::Graphics::Effects;
namespace wuc = winrt::Windows::UI::Composition;
namespace abi_wge = ABI::Windows::Graphics::Effects;

// 手写 IGraphicsEffect + IGraphicsEffectD2D1Interop(免 Win2D 依赖):
// CompositionEffectFactory 通过 interop 接口读取 CLSID / 属性 / 输入,
// 直接映射到 D2D1 内置效果。属性按 D2D 效果的属性索引顺序预装箱。
class SignetEffect
    : public winrt::implements<SignetEffect, wge::IGraphicsEffect,
                               wge::IGraphicsEffectSource,
                               abi_wge::IGraphicsEffectD2D1Interop> {
 public:
  SignetEffect(GUID effect_id, std::vector<wf::IInspectable> properties,
               std::vector<wge::IGraphicsEffectSource> sources)
      : effect_id_(effect_id),
        properties_(std::move(properties)),
        sources_(std::move(sources)) {}

  // IGraphicsEffect
  winrt::hstring Name() const { return name_; }
  void Name(winrt::hstring const& value) { name_ = value; }

  // IGraphicsEffectD2D1Interop
  IFACEMETHODIMP GetEffectId(GUID* id) noexcept override {
    *id = effect_id_;
    return S_OK;
  }

  IFACEMETHODIMP GetNamedPropertyMapping(
      LPCWSTR, UINT*, GRAPHICS_EFFECT_PROPERTY_MAPPING*) noexcept override {
    // 不暴露可动画命名属性
    return E_INVALIDARG;
  }

  IFACEMETHODIMP GetPropertyCount(UINT* count) noexcept override {
    *count = static_cast<UINT>(properties_.size());
    return S_OK;
  }

  IFACEMETHODIMP GetProperty(
      UINT index,
      ABI::Windows::Foundation::IPropertyValue** value) noexcept override {
    if (index >= properties_.size()) return E_INVALIDARG;
    try {
      properties_[index].as<ABI::Windows::Foundation::IPropertyValue>().copy_to(
          value);
      return S_OK;
    } catch (...) {
      return winrt::to_hresult();
    }
  }

  IFACEMETHODIMP GetSource(
      UINT index, abi_wge::IGraphicsEffectSource** source) noexcept override {
    if (index >= sources_.size()) return E_INVALIDARG;
    try {
      sources_[index].as<abi_wge::IGraphicsEffectSource>().copy_to(source);
      return S_OK;
    } catch (...) {
      return winrt::to_hresult();
    }
  }

  IFACEMETHODIMP GetSourceCount(UINT* count) noexcept override {
    *count = static_cast<UINT>(sources_.size());
    return S_OK;
  }

 private:
  GUID effect_id_;
  winrt::hstring name_;
  std::vector<wf::IInspectable> properties_;
  std::vector<wge::IGraphicsEffectSource> sources_;
};

wf::IInspectable BoxUInt32(uint32_t value) {
  return wf::PropertyValue::CreateUInt32(value);
}

// 图块源 → 无限平铺。
//
// 坐标契约:Win32 DesktopWindowTarget 的合成坐标 1:1 对应物理像素
// (无 XAML island 的自动 DPI 缩放),而 Dart 下发的 tile 本就按
// DPR 栅格成物理像素(tilePx = period·dpr),因此直接 1:1 wrap,
// 不做任何重采样——这也是解码端网格对齐的前提。多显示器 DPR 变化
// 由 Dart 侧感知并重新下发对应 DPR 的 tile。
wge::IGraphicsEffectSource MakeTiledTile(wge::IGraphicsEffectSource tile) {
  return winrt::make<SignetEffect>(
      CLSID_D2D1Border,
      std::vector<wf::IInspectable>{
          BoxUInt32(D2D1_BORDER_EDGE_MODE_WRAP),
          BoxUInt32(D2D1_BORDER_EDGE_MODE_WRAP),
      },
      std::vector<wge::IGraphicsEffectSource>{std::move(tile)});
}

}  // namespace

class RenderSignetHandler::Impl {
 public:
  explicit Impl(HWND hwnd) : hwnd_(hwnd) {}

  bool Install(const std::vector<uint8_t>& mod_rgba,
               const std::vector<uint8_t>& plus_rgba, int tile_px) {
    try {
      if (!EnsureComposition()) return false;
      auto mod_surface = CreateTileSurface(mod_rgba, tile_px);
      auto plus_surface = CreateTileSurface(plus_rgba, tile_px);
      BuildVisual(mod_surface, plus_surface);
      return true;
    } catch (...) {
      Remove();
      return false;
    }
  }

  void Remove() {
    if (root_) root_.Children().RemoveAll();
  }

 private:
  bool EnsureComposition() {
    if (compositor_) return true;

    // Composition 需要当前线程有 DispatcherQueue;每线程只能有一个
    // controller,若已有(其他组件先建)则直接复用
    if (!winrt::Windows::System::DispatcherQueue::GetForCurrentThread()) {
      DispatcherQueueOptions options{sizeof(DispatcherQueueOptions),
                                     DQTYPE_THREAD_CURRENT, DQTAT_COM_NONE};
      winrt::check_hresult(CreateDispatcherQueueController(
          options,
          reinterpret_cast<ABI::Windows::System::IDispatcherQueueController**>(
              winrt::put_abi(dispatcher_controller_))));
    }

    compositor_ = wuc::Compositor();

    // isTopmost=TRUE:合成层位于所有子窗口(Flutter 视图)之上。
    // BackdropBrush 在该层采样其下的窗口内容——子窗口内容参与采样是
    // Win32 backdrop 效果的标准配方(前提正是内容位于子窗口)。
    auto desktop_interop =
        compositor_.as<ABI::Windows::UI::Composition::Desktop::
                           ICompositorDesktopInterop>();
    winrt::check_hresult(desktop_interop->CreateDesktopWindowTarget(
        hwnd_, TRUE,
        reinterpret_cast<
            ABI::Windows::UI::Composition::Desktop::IDesktopWindowTarget**>(
            winrt::put_abi(target_))));

    root_ = compositor_.CreateContainerVisual();
    root_.RelativeSizeAdjustment({1.0f, 1.0f});
    target_.Root(root_);

    // D3D11 + D2D 设备:仅用于把图块字节画进 CompositionDrawingSurface
    winrt::com_ptr<ID3D11Device> d3d_device;
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                   flags, nullptr, 0, D3D11_SDK_VERSION,
                                   d3d_device.put(), nullptr, nullptr);
    if (FAILED(hr)) {
      winrt::check_hresult(D3D11CreateDevice(
          nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags, nullptr, 0,
          D3D11_SDK_VERSION, d3d_device.put(), nullptr, nullptr));
    }
    winrt::com_ptr<ID2D1Factory1> d2d_factory;
    D2D1_FACTORY_OPTIONS factory_options{};
    winrt::check_hresult(D2D1CreateFactory(
        D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1),
        &factory_options, d2d_factory.put_void()));
    winrt::com_ptr<ID2D1Device> d2d_device;
    winrt::check_hresult(d2d_factory->CreateDevice(
        d3d_device.as<IDXGIDevice>().get(), d2d_device.put()));

    auto compositor_interop =
        compositor_.as<ABI::Windows::UI::Composition::ICompositorInterop>();
    winrt::check_hresult(compositor_interop->CreateGraphicsDevice(
        d2d_device.get(),
        reinterpret_cast<
            ABI::Windows::UI::Composition::ICompositionGraphicsDevice**>(
            winrt::put_abi(graphics_device_))));
    return true;
  }

  wuc::CompositionDrawingSurface CreateTileSurface(
      const std::vector<uint8_t>& rgba, int tile_px) {
    // Dart rawRgba(预乘)→ BGRA 换道,预乘性不受通道交换影响
    std::vector<uint8_t> bgra(rgba.size());
    for (size_t i = 0; i + 3 < rgba.size(); i += 4) {
      bgra[i] = rgba[i + 2];
      bgra[i + 1] = rgba[i + 1];
      bgra[i + 2] = rgba[i];
      bgra[i + 3] = rgba[i + 3];
    }

    auto surface = graphics_device_.CreateDrawingSurface(
        {static_cast<float>(tile_px), static_cast<float>(tile_px)},
        winrt::Windows::Graphics::DirectX::DirectXPixelFormat::
            B8G8R8A8UIntNormalized,
        winrt::Windows::Graphics::DirectX::DirectXAlphaMode::Premultiplied);

    auto surface_interop =
        surface
            .as<ABI::Windows::UI::Composition::ICompositionDrawingSurfaceInterop>();
    POINT offset{};
    winrt::com_ptr<ID2D1DeviceContext> ctx;
    winrt::check_hresult(surface_interop->BeginDraw(
        nullptr, __uuidof(ID2D1DeviceContext), ctx.put_void(), &offset));

    winrt::com_ptr<ID2D1Bitmap1> bitmap;
    const D2D1_BITMAP_PROPERTIES1 bitmap_props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_NONE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                          D2D1_ALPHA_MODE_PREMULTIPLIED));
    winrt::check_hresult(ctx->CreateBitmap(
        D2D1::SizeU(tile_px, tile_px), bgra.data(),
        static_cast<UINT32>(tile_px * 4), bitmap_props, bitmap.put()));

    // 表面初始内容未定义,plus 笔有透明区,必须先清空
    ctx->Clear(D2D1::ColorF(0, 0, 0, 0));
    const auto dest = D2D1::RectF(
        static_cast<float>(offset.x), static_cast<float>(offset.y),
        static_cast<float>(offset.x + tile_px),
        static_cast<float>(offset.y + tile_px));
    ctx->DrawBitmap(bitmap.get(), &dest, 1.0f,
                    D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, nullptr);
    winrt::check_hresult(surface_interop->EndDraw());
    return surface;
  }

  // 单 visual 单效果图:LinearDodge(Multiply(backdrop, mod), plus)。
  // 先乘后加与 Dart painter 契约一致;单 backdrop 读避免两层各自
  // 采样的顺序不确定性。Blend 输入 0 = Destination、1 = Source。
  void BuildVisual(wuc::CompositionDrawingSurface const& mod_surface,
                   wuc::CompositionDrawingSurface const& plus_surface) {
    root_.Children().RemoveAll();

    auto backdrop_param = wuc::CompositionEffectSourceParameter(L"backdrop");
    auto mod_param = wuc::CompositionEffectSourceParameter(L"modTile");
    auto plus_param = wuc::CompositionEffectSourceParameter(L"plusTile");

    auto multiply = winrt::make<SignetEffect>(
        CLSID_D2D1Blend,
        std::vector<wf::IInspectable>{BoxUInt32(D2D1_BLEND_MODE_MULTIPLY)},
        std::vector<wge::IGraphicsEffectSource>{
            backdrop_param.as<wge::IGraphicsEffectSource>(),
            MakeTiledTile(mod_param.as<wge::IGraphicsEffectSource>())});
    auto linear_dodge = winrt::make<SignetEffect>(
        CLSID_D2D1Blend,
        std::vector<wf::IInspectable>{BoxUInt32(D2D1_BLEND_MODE_LINEAR_DODGE)},
        std::vector<wge::IGraphicsEffectSource>{
            multiply.as<wge::IGraphicsEffectSource>(),
            MakeTiledTile(plus_param.as<wge::IGraphicsEffectSource>())});

    auto factory =
        compositor_.CreateEffectFactory(linear_dodge.as<wge::IGraphicsEffect>());
    auto brush = factory.CreateBrush();
    brush.SetSourceParameter(L"backdrop", compositor_.CreateBackdropBrush());
    brush.SetSourceParameter(L"modTile",
                             compositor_.CreateSurfaceBrush(mod_surface));
    brush.SetSourceParameter(L"plusTile",
                             compositor_.CreateSurfaceBrush(plus_surface));

    auto visual = compositor_.CreateSpriteVisual();
    visual.RelativeSizeAdjustment({1.0f, 1.0f});
    visual.Brush(brush);
    root_.Children().InsertAtTop(visual);
  }

  HWND hwnd_;
  winrt::Windows::System::DispatcherQueueController dispatcher_controller_{
      nullptr};
  wuc::Compositor compositor_{nullptr};
  wuc::Desktop::DesktopWindowTarget target_{nullptr};
  wuc::CompositionGraphicsDevice graphics_device_{nullptr};
  wuc::ContainerVisual root_{nullptr};
};

RenderSignetHandler::RenderSignetHandler() = default;
RenderSignetHandler::~RenderSignetHandler() = default;

void RenderSignetHandler::Register(flutter::BinaryMessenger* messenger,
                                   HWND hwnd) {
  impl_ = std::make_unique<Impl>(hwnd);
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.fluxdo/render_signet",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "install") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!args) {
        result->Error("INVALID_ARGS", "install 参数不合法");
        return;
      }
      auto find = [args](const char* key) -> const flutter::EncodableValue* {
        auto it = args->find(flutter::EncodableValue(key));
        return it != args->end() ? &it->second : nullptr;
      };
      const auto* mod_value = find("modTile");
      const auto* plus_value = find("plusTile");
      const auto* tile_px_value = find("tilePx");
      const auto* mod_tile =
          mod_value ? std::get_if<std::vector<uint8_t>>(mod_value) : nullptr;
      const auto* plus_tile =
          plus_value ? std::get_if<std::vector<uint8_t>>(plus_value) : nullptr;
      const int64_t tile_px = tile_px_value ? tile_px_value->LongValue() : 0;
      if (!mod_tile || !plus_tile || tile_px <= 0) {
        result->Error("INVALID_ARGS", "install 参数不合法");
        return;
      }
      result->Success(flutter::EncodableValue(
          impl_->Install(*mod_tile, *plus_tile, static_cast<int>(tile_px))));
    } else if (call.method_name() == "remove") {
      impl_->Remove();
      result->Success(flutter::EncodableValue(true));
    } else {
      result->NotImplemented();
    }
  });
}

void RenderSignetHandler::OnWindowResized() {
  // RelativeSizeAdjustment 全链自适应,无需处理;保留接口以防后续
  // 需要按尺寸重建(如多显示器混合 DPI 边界问题)。
}
