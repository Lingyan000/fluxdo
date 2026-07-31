import Flutter
import UIKit

/// 窗口级渲染帧标识印记层(原生后端,机制与 macOS 版一致)。
///
/// Dart 侧是编码单一真相:两张 RGBA 图块经 `com.fluxdo/render_signet`
/// 通道下发,这里只做「平铺 + 混合」——multiply ≙ modulate 笔、
/// linearDodge ≙ plus 笔,先乘后加的顺序契约与 Dart painter 一致。
/// 下沉动机:Flutter 全屏绘制会把平台视图(WKWebView/iframe)头顶
/// 区域计入引擎命中测试统计;原生兄弟视图不参与,且能把印记盖到
/// WebView 自身的像素上。
class RenderSignetHandler {
  static let shared = RenderSignetHandler()
  private init() {}

  private weak var window: UIWindow?
  private var overlayView: SignetOverlayView?

  func register(messenger: FlutterBinaryMessenger, window: UIWindow) {
    self.window = window
    let channel = FlutterMethodChannel(
      name: "com.fluxdo/render_signet",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "install":
        guard let args = call.arguments as? [String: Any],
              let modData = args["modTile"] as? FlutterStandardTypedData,
              let plusData = args["plusTile"] as? FlutterStandardTypedData,
              let tilePx = args["tilePx"] as? Int,
              let period = args["period"] as? Double,
              let modImage = Self.makeTileImage(modData.data, tilePx: tilePx),
              let plusImage = Self.makeTileImage(plusData.data, tilePx: tilePx)
        else {
          result(FlutterError(code: "INVALID_ARGS", message: "install 参数不合法", details: nil))
          return
        }
        result(self.install(mod: modImage, plus: plusImage, period: period))
      case "remove":
        self.overlayView?.removeFromSuperview()
        self.overlayView = nil
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func install(mod: CGImage, plus: CGImage, period: Double) -> Bool {
    guard let window = window else { return false }
    let overlay: SignetOverlayView
    if let existing = overlayView, existing.superview === window {
      overlay = existing
    } else {
      overlayView?.removeFromSuperview()
      overlay = SignetOverlayView(frame: window.bounds)
      overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      overlayView = overlay
      window.addSubview(overlay)
    }
    // 全屏媒体查看器等后加的视图会盖过 overlay,置顶保证印记恒在最上
    window.bringSubviewToFront(overlay)
    overlay.setTiles(mod: mod, plus: plus, period: CGFloat(period))
    return true
  }

  /// Dart `ImageByteFormat.rawRgba`(预乘 RGBA8888)→ sRGB CGImage。
  private static func makeTileImage(_ data: Data, tilePx: Int) -> CGImage? {
    guard tilePx > 0, data.count == tilePx * tilePx * 4,
          let provider = CGDataProvider(data: data as CFData),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    return CGImage(
      width: tilePx,
      height: tilePx,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: tilePx * 4,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }
}

/// 印记覆盖视图:对触摸完全透明。
private final class SignetOverlayView: UIView {
  private let multiplyLayer = CALayer()
  private let plusLayer = CALayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    layer.zPosition = 1_000_000
    let noActions: [String: CAAction] = [
      "bounds": NSNull(), "position": NSNull(), "contents": NSNull(),
      "backgroundColor": NSNull(), "hidden": NSNull(),
    ]
    for (sub, filter) in [
      (multiplyLayer, "multiplyBlendMode"),
      (plusLayer, "linearDodgeBlendMode"),
    ] {
      sub.compositingFilter = filter
      sub.actions = noActions
      layer.addSublayer(sub)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

  func setTiles(mod: CGImage, plus: CGImage, period: CGFloat) {
    // UIImage scale 取 tilePx/period(= 生成时的 dpr):pattern 单元
    // 回到 period pt,物理像素 1:1 铺贴
    let scale = CGFloat(mod.width) / period
    multiplyLayer.backgroundColor =
      UIColor(patternImage: UIImage(cgImage: mod, scale: scale, orientation: .up)).cgColor
    plusLayer.backgroundColor =
      UIColor(patternImage: UIImage(cgImage: plus, scale: scale, orientation: .up)).cgColor
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for sub in [multiplyLayer, plusLayer] {
      sub.frame = bounds
    }
    CATransaction.commit()
  }
}
