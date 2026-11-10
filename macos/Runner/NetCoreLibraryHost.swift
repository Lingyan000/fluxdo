import Darwin
import Foundation

/// 网络库属于原生进程，不属于 Dart isolate。保留首次加载的 handle 和清理地址，
/// 避免开发期间 app 内的 dylib 被重新构建替换后，按路径查到另一份库。
final class NetCoreLibraryHost {
  static let shared = NetCoreLibraryHost(
    libraryPath: Bundle.main.privateFrameworksURL?
      .appendingPathComponent("libfluxdo_net.dylib").path
  )

  // 故意不 dlclose：Rust 的 runtime、线程和回调槽与此映像一起存活至进程结束。
  private let library: UnsafeMutableRawPointer?
  private let detach: (@convention(c) () -> Void)?

  init(libraryPath: String?) {
    guard let libraryPath,
          let library = dlopen(libraryPath, RTLD_NOW | RTLD_GLOBAL | RTLD_NODELETE) else {
      self.library = nil
      self.detach = nil
      NSLog("网络核心加载失败: %@", dlerror().map { String(cString: $0) } ?? "无动态库路径")
      return
    }
    guard let symbol = dlsym(library, "fluxdo_net_detach_host") else {
      preconditionFailure("网络核心版本过旧，请重新准备 macOS 原生库并完整重启应用")
    }
    self.library = library
    self.detach = unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)
  }

  func detachHost() {
    detach?()
  }
}
