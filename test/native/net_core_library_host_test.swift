import Darwin
import Foundation

@main
enum NetCoreLibraryHostTest {
  static func main() throws {
    let path = CommandLine.arguments[1]
    let secondPath = CommandLine.arguments[2]
    let host = NetCoreLibraryHost(libraryPath: path)
    let process = dlopen(nil, RTLD_NOW)!
    let original = dlsym(process, "fluxdo_net_detach_host")!
    let originalCount = unsafeBitCast(
      dlsym(process, "fluxdo_test_detach_count")!, to: (@convention(c) () -> Int32).self
    )
    host.detachHost()
    precondition(originalCount() == 1)

    // 与开发构建一样，替换路径背后的文件；不能覆盖已映射的 inode。
    let replacement = path + ".replacement"
    try FileManager.default.copyItem(atPath: secondPath, toPath: replacement)
    precondition(rename(replacement, path) == 0)

    // 强制加载相同 UUID 的第二份映像，复现报告中的两个独立回调槽。
    let second = dlopen(secondPath, RTLD_NOW | RTLD_LOCAL)!
    let secondDetach = dlsym(second, "fluxdo_net_detach_host")!
    precondition(secondDetach != original, "Fixture must contain two distinct loaded images")
    let secondCount = unsafeBitCast(
      dlsym(second, "fluxdo_test_detach_count")!, to: (@convention(c) () -> Int32).self
    )
    precondition(secondCount() == 0)

    // Dart 用进程符号，清理用保存的地址，两边始终指向最初的同一份状态。
    for _ in 0..<50 {
      precondition(dlsym(process, "fluxdo_net_detach_host") == original)
      host.detachHost()
    }
    precondition(originalCount() == 51)
    precondition(secondCount() == 0, "Cleanup must not switch to the other image")
    dlclose(second)
    dlclose(process)
    print("PASS: file replacement + duplicate images + 50 detach cycles")
  }
}
