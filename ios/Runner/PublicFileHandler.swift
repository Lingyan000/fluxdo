import Flutter
import UIKit

/// 公共文件落盘通道（iOS 腿），与 Dart 侧 PublicFileChannel 协议对应。
///
/// iOS 沙盒里没有「公共目录」这种东西，所以：
/// - saveToDownloads：返回 nil，由 Dart 侧转交 saveAs；
/// - saveAs：UIDocumentPicker 导出，让用户挑「文件」App / iCloud 里的位置。
///   走原生这一条是为了**直接交文件 URL 给系统拷贝** —— file_picker 在移动端
///   要求把整个文件读成 bytes 传过来，导出大文件（如全部楼层的 HTML）会有一次
///   全量内存尖峰。
/// - openUri / shareUri / deleteUri：iOS 没有 content uri 这套东西，一律返回
///   false，由调用方按本地路径处理。
final class PublicFileHandler: NSObject {
  static let shared = PublicFileHandler()

  private static let channelName = "com.fluxdo/public_file"

  /// 等待导出面板回调的一次性上下文（同一时刻只允许一个导出流程）。
  private var pendingResult: FlutterResult?
  private var pendingFileName: String?

  /// 导出用的临时副本：用户可能改名，先拷一份带目标名的文件再交给系统。
  private var pendingTempURL: URL?

  private weak var viewController: UIViewController?

  func register(messenger: FlutterBinaryMessenger, viewController: UIViewController) {
    self.viewController = viewController
    let channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "saveToDownloads":
        // iOS 没有对外可见的落点，交给 Dart 侧走 saveAs
        result(nil)
      case "saveAs":
        self.saveAs(args, result: result)
      case "openUri", "shareUri", "deleteUri":
        result(false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func saveAs(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let sourcePath = args["sourcePath"] as? String,
          let fileName = args["fileName"] as? String else {
      result(FlutterError(code: "INVALID_ARGS", message: "sourcePath / fileName is null", details: nil))
      return
    }
    guard let controller = viewController else {
      result(FlutterError(code: "NO_VIEW_CONTROLLER", message: "viewController is null", details: nil))
      return
    }
    if pendingResult != nil {
      result(FlutterError(code: "BUSY", message: "another save-as is in progress", details: nil))
      return
    }

    // 导出面板用文件本身的名字，所以先拷成目标名（源文件是 temp/outbox 里的
    // 中转件，名字可能已经是对的，拷贝仍然是最省心的做法）
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("outbox-export", isDirectory: true)
    let target = tempDir.appendingPathComponent(fileName)
    do {
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: target)
    } catch {
      result(FlutterError(code: "SAVE_FAILED", message: error.localizedDescription, details: nil))
      return
    }

    pendingResult = result
    pendingFileName = fileName
    pendingTempURL = target

    let picker = UIDocumentPickerViewController(forExporting: [target], asCopy: true)
    picker.delegate = self
    picker.shouldShowFileExtensions = true
    controller.present(picker, animated: true)
  }

  private func finish(_ payload: Any?) {
    let reply = pendingResult
    let temp = pendingTempURL
    pendingResult = nil
    pendingFileName = nil
    pendingTempURL = nil
    reply?(payload)
    if let temp {
      try? FileManager.default.removeItem(at: temp)
    }
  }
}

extension PublicFileHandler: UIDocumentPickerDelegate {
  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    // 导出面板返回的位置在应用沙盒外，长期不保证可读，所以只回名字不回 uri：
    // Dart 侧据此写「已保存」提示，但不把它当作可打开的引用存进导出历史。
    let name = urls.first?.lastPathComponent ?? pendingFileName ?? ""
    finish(["uri": "", "displayName": name])
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    // 与 Android SAF 取消同一表达：null = 用户放弃
    finish(nil)
  }
}
