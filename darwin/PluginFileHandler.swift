import Foundation
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

/// 保留系统交付的文件 URL 与访问授权，冷启动后再交给统一安装队列。
final class PluginFileHandler {
  static let shared = PluginFileHandler()
  private var channel: FlutterMethodChannel?
  private var pending: [String] = []
  private var files: [String: (url: URL, scoped: Bool)] = [:]
  private let reader = DispatchQueue(label: "com.fluxdo.plugin-files")
  private let maxBytes = 2 * 1024 * 1024

  @discardableResult
  func open(_ url: URL) -> Bool {
    guard url.isFileURL, url.pathExtension.lowercased() == "fluxplugin",
          url.query == nil, url.fragment == nil else { return false }
    let key = url.standardizedFileURL.absoluteString
    guard files[key] == nil else { return true }
    files[key] = (url, url.startAccessingSecurityScopedResource())
    pending.append(key)
    channel?.invokeMethod("filesAvailable", arguments: nil)
    return true
  }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.fluxdo/plugin_files", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [self] call, result in
      switch call.method {
      case "takePendingFiles":
        // 确认或失败后由 Dart 释放；引擎热重启仍可取回未消费文件。
        result(pending)
      case "releaseFile":
        if let key = call.arguments as? String, let file = files.removeValue(forKey: key) {
          if file.scoped { file.url.stopAccessingSecurityScopedResource() }
          pending.removeAll { $0 == key }
        }
        result(nil)
      case "readFile":
        guard let key = call.arguments as? String,
              let url = URL(string: key), url.isFileURL,
              url.pathExtension.lowercased() == "fluxplugin" else {
          result(FlutterError(code: "invalid_uri", message: "Invalid plugin file URI", details: nil))
          return
        }
        let retained = files[key]
        let file: (url: URL, scoped: Bool) = retained
          ?? (url, url.startAccessingSecurityScopedResource())
        reader.async { [self] in
          defer {
            if retained == nil && file.scoped { file.url.stopAccessingSecurityScopedResource() }
          }
          do {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            var bytes = Data()
            while let chunk = try handle.read(upToCount: min(8192, maxBytes + 1 - bytes.count)), !chunk.isEmpty {
              bytes.append(chunk)
              if bytes.count > maxBytes {
                DispatchQueue.main.async {
                  result(FlutterError(code: "plugin_file_size", message: "Plugin file exceeds 2 MiB", details: nil))
                }
                return
              }
            }
            let payload = FlutterStandardTypedData(bytes: bytes)
            DispatchQueue.main.async { result(payload) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "plugin_file_read", message: error.localizedDescription, details: nil))
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
