import AppKit
import FlutterMacOS

enum ImageZoomCursor {
  private static let cursor: NSCursor = {
    if #available(macOS 15, *) { return .zoomIn }

    // 旧版 AppKit 没有 zoomIn。黑白双描边在深、浅色图片上都可见。
    let image = NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
      let lens = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
      let handle = NSBezierPath()
      handle.move(to: NSPoint(x: 14, y: 14))
      handle.line(to: NSPoint(x: 21, y: 21))
      let plus = NSBezierPath()
      plus.move(to: NSPoint(x: 6, y: 9))
      plus.line(to: NSPoint(x: 12, y: 9))
      plus.move(to: NSPoint(x: 9, y: 6))
      plus.line(to: NSPoint(x: 9, y: 12))

      for (color, width) in [(NSColor.white, CGFloat(4)), (.black, CGFloat(2))] {
        color.setStroke()
        for path in [handle, lens, plus] {
          path.lineWidth = width
          path.lineCapStyle = .round
          path.stroke()
        }
      }
      return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
  }()

  static func register(with engine: FlutterEngine) {
    let channel = FlutterMethodChannel(name: "com.fluxdo/image_cursor",
                                       binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak engine] call, result in
      guard call.method == "zoomIn" else { result(FlutterMethodNotImplemented); return }
      cursor.set()
      // FlutterView 在菜单关闭、鼠标离开原生子视图时，会重新应用引擎记录的指针。
      let update = NSSelectorFromString("didUpdateMouseCursor:")
      if let engine, engine.responds(to: update) {
        engine.perform(update, with: cursor)
      }
      result(nil)
    }
  }
}
