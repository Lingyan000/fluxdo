import Cocoa
import FlutterMacOS
import XCTest
@testable import fluxdo

class RunnerTests: XCTestCase {

  func testClosingMiniAppStopsOnlyItsEngineAfterCloseReturns() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled, .closable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    let otherWindow = NSWindow()
    otherWindow.isReleasedWhenClosed = false
    var shutdowns = 0
    weak var lifetime: MiniAppWindowLifetime?
    let stopped = expectation(description: "关闭后停止子引擎")
    // 与创建回调一致，不依赖调用方额外持有生命周期对象。
    do {
      let value = MiniAppWindowLifetime(window: window) {
        shutdowns += 1
        stopped.fulfill()
      }
      lifetime = value
    }
    XCTAssertNotNil(lifetime)
    otherWindow.close()
    XCTAssertEqual(shutdowns, 0)
    window.performClose(nil)
    XCTAssertEqual(shutdowns, 0, "平台通道返回前不能同步销毁引擎")
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
    wait(for: [stopped], timeout: 2)
    XCTAssertEqual(shutdowns, 1)
    XCTAssertNil(lifetime, "关闭后必须解除观察器的持有")
  }

}
