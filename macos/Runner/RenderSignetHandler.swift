import Cocoa
import FlutterMacOS

/// 窗口级渲染帧标识印记层(原生后端)。
///
/// Dart 侧([lib/widgets/render_signet/])仍是编码单一真相:两张
/// RGBA 图块经 `com.fluxdo/render_signet` 通道下发,这里只做
/// 「平铺 + 混合」——multiply 层对应 modulate 笔、linearDodge 层
/// 对应 plus 笔,先乘后加的顺序契约与 Dart painter 一致。
///
/// 不走 Flutter 绘制的原因:Flutter 层的全屏绘制会被引擎计入平台
/// 视图(WKWebView)上方 backing store 的 paint region,
/// FlutterMutatorView.hitTest 对该区域返 nil,WebView 整块收不到
/// 鼠标事件。原生兄弟视图不参与该统计;副产品是印记能盖到
/// WebView 自身的像素。
class RenderSignetHandler {
  static let shared = RenderSignetHandler()
  private init() {}

  private weak var window: NSWindow?
  private var overlayView: SignetOverlayView?

  func register(messenger: FlutterBinaryMessenger, window: NSWindow) {
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
    guard let contentView = window?.contentView else { return false }
    let overlay: SignetOverlayView
    if let existing = overlayView, existing.superview === contentView {
      overlay = existing
    } else {
      overlayView?.removeFromSuperview()
      overlay = SignetOverlayView(frame: contentView.bounds)
      overlay.autoresizingMask = [.width, .height]
      overlayView = overlay
      contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
    }
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

/// 印记覆盖视图:对命中测试完全透明,永远浮在 contentView 子视图
/// (FlutterView 的 overlay surface、平台视图 mutator view)之上。
private final class SignetOverlayView: NSView {
  private let multiplyLayer = CALayer()
  private let plusLayer = CALayer()
  private var period: CGFloat = 84

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    // mutator view 的 zPosition 是平台视图图层序号(个位数量级),
    // 取大值保证印记恒在最顶
    layer?.zPosition = 1_000_000
    // 混合层不该有任何隐式动画(resize 时 pattern 闪变)
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
      layer?.addSublayer(sub)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var isFlipped: Bool { true }

  func setTiles(mod: CGImage, plus: CGImage, period: CGFloat) {
    self.period = period
    // NSImage 尺寸取逻辑 pt:pattern 单元 = period pt,配合 rep 的
    // 物理像素(tilePx = period·dpr)在当前 backing scale 下 1:1 铺贴
    let size = NSSize(width: period, height: period)
    multiplyLayer.backgroundColor =
      NSColor(patternImage: NSImage(cgImage: mod, size: size)).cgColor
    plusLayer.backgroundColor =
      NSColor(patternImage: NSImage(cgImage: plus, size: size)).cgColor
    needsLayout = true
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let scale = window?.backingScaleFactor ?? 2
    for sub in [multiplyLayer, plusLayer] {
      sub.frame = bounds
      sub.contentsScale = scale
    }
    layer?.contentsScale = scale
    CATransaction.commit()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }
}
