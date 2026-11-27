import CoreGraphics
import Foundation
import ImageIO
import Vision
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Apple 原生文字识别通道（Vision 框架 + 神经网络引擎硬件加速，免模型下载）。
/// 与 Dart 侧 AppleVisionOcr（com.fluxdo/vision_ocr）协议对应。
///
/// 本文件 iOS / macOS 各放一份（内容相同，条件编译 import），改动需同步。
class VisionOcrHandler: NSObject {
  static let shared = VisionOcrHandler()

  private let workQueue = DispatchQueue(
    label: "com.fluxdo.vision-ocr",
    qos: .userInitiated
  )
  private var cachedLanguages: [String]?

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.fluxdo/vision_ocr",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "isAvailable":
        if #available(macOS 10.15, iOS 13.0, *) {
          result(true)
        } else {
          result(false)
        }
      case "recognize":
        guard let typedData = call.arguments as? FlutterStandardTypedData else {
          result(
            FlutterError(
              code: "INVALID_ARGS",
              message: "Expected image bytes as Uint8List",
              details: nil
            )
          )
          return
        }
        self.recognize(data: typedData.data, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func recognize(data: Data, result: @escaping FlutterResult) {
    guard #available(macOS 10.15, iOS 13.0, *) else {
      result(
        FlutterError(
          code: "UNAVAILABLE",
          message: "Vision text recognition requires macOS 10.15+ / iOS 13.0+",
          details: nil
        )
      )
      return
    }

    workQueue.async {
      do {
        let payload = try self.performRecognition(data: data)
        DispatchQueue.main.async {
          result(payload)
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "VISION_OCR_FAILED",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  private struct VisionOcrError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  @available(macOS 10.15, iOS 13.0, *)
  private func resolveLanguages(for request: VNRecognizeTextRequest) -> [String] {
    if let cached = cachedLanguages { return cached }
    let preferred = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
    let supported: [String]
    if #available(macOS 12.0, iOS 15.0, *),
      let list = try? request.supportedRecognitionLanguages()
    {
      supported = list
    } else if let list =
      try? VNRecognizeTextRequest.supportedRecognitionLanguages(
        for: .accurate,
        revision: request.revision
      )
    {
      supported = list
    } else {
      supported = []
    }
    let supportedSet = Set(supported)
    let filtered = preferred.filter { supportedSet.contains($0) }
    cachedLanguages = filtered
    return filtered
  }

  @available(macOS 10.15, iOS 13.0, *)
  private func performRecognition(data: Data) throws -> [String: Any] {
    let t0 = CFAbsoluteTimeGetCurrent()
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw VisionOcrError(message: "无法解析图片数据")
    }

    let properties =
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    var rawWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    var rawHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let rawOrientation =
      properties?[kCGImagePropertyOrientation] as? UInt32
      ?? CGImagePropertyOrientation.up.rawValue
    let cgOrientation =
      CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up

    var fallbackCgImage: CGImage?
    if rawWidth <= 0 || rawHeight <= 0 {
      guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw VisionOcrError(message: "无法读取图片尺寸")
      }
      rawWidth = decoded.width
      rawHeight = decoded.height
      fallbackCgImage = decoded
    }

    // 与 Flutter decodeImageFromList 保持一致：EXIF 90°/270° 旋转时交换宽高。
    let swapsAxes =
      cgOrientation == .left
      || cgOrientation == .leftMirrored
      || cgOrientation == .right
      || cgOrientation == .rightMirrored
    let imageWidth = swapsAxes ? rawHeight : rawWidth
    let imageHeight = swapsAxes ? rawWidth : rawHeight
    let tDecodeEnd = CFAbsoluteTimeGetCurrent()

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    if #available(macOS 13.0, iOS 16.0, *) {
      request.revision = VNRecognizeTextRequestRevision3
      // 显式关闭自动语种检测：中英/日中混排单行在自动检测下容易被误判为纯英文，
      // 且会额外拉高首次模型编译耗时；改用固定的多语言优先列表效果更稳更快。
      request.automaticallyDetectsLanguage = false
    }

    let languages = resolveLanguages(for: request)
    if !languages.isEmpty {
      request.recognitionLanguages = languages
    }

    let handler: VNImageRequestHandler
    if let cgImage = fallbackCgImage {
      handler = VNImageRequestHandler(
        cgImage: cgImage,
        orientation: cgOrientation,
        options: [:]
      )
    } else {
      handler = VNImageRequestHandler(
        data: data,
        orientation: cgOrientation,
        options: [:]
      )
    }
    try handler.perform([request])
    let tPerformEnd = CFAbsoluteTimeGetCurrent()

    let imgW = Double(imageWidth)
    let imgH = Double(imageHeight)
    let observations = request.results ?? []
    var lines: [[String: Any]] = []
    lines.reserveCapacity(observations.count)

    for observation in observations {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let raw = candidate.string
      guard
        let firstNonWS = raw.firstIndex(where: {
          !$0.isWhitespace && !$0.isNewline
        }),
        let lastNonWS = raw.lastIndex(where: {
          !$0.isWhitespace && !$0.isNewline
        })
      else {
        continue
      }
      let trimEnd = raw.index(after: lastNonWS)
      let trimmed = String(raw[firstNonWS..<trimEnd])
      let utf16Count = trimmed.utf16.count
      if utf16Count == 0 { continue }

      // Vision 归一化坐标原点在左下角，转换为原图左上角像素坐标。
      let ob = observation.boundingBox
      let lineLeft = max(0.0, min(imgW, Double(ob.minX) * imgW))
      let lineRight = max(lineLeft, min(imgW, Double(ob.maxX) * imgW))
      let lineTop = max(0.0, min(imgH, Double(1.0 - ob.maxY) * imgH))
      let lineBottom = max(lineTop, min(imgH, Double(1.0 - ob.minY) * imgH))
      if lineRight <= lineLeft || lineBottom <= lineTop { continue }

      // 按 Dart UTF-16 码元索引一一对齐提取逐字符包围盒，空格等缺失项按相邻字符平滑插值。
      var unitRects: [(Double, Double, Double, Double)?] = []
      unitRects.reserveCapacity(utf16Count)

      var idx = firstNonWS
      while idx < trimEnd {
        let nextIdx = raw.index(after: idx)
        let unitCount = raw[idx..<nextIdx].utf16.count
        let charBox = (try? candidate.boundingBox(for: idx..<nextIdx))?
          .boundingBox
        if let b = charBox, b.width > 0, b.height > 0 {
          let l = max(0.0, min(imgW, Double(b.minX) * imgW))
          let r = max(l, min(imgW, Double(b.maxX) * imgW))
          let t = max(0.0, min(imgH, Double(1.0 - b.maxY) * imgH))
          let bot = max(t, min(imgH, Double(1.0 - b.minY) * imgH))
          if unitCount == 1 {
            unitRects.append((l, t, r, bot))
          } else {
            let span = r - l
            for u in 0..<unitCount {
              let ul = l + span * (Double(u) / Double(unitCount))
              let ur = l + span * (Double(u + 1) / Double(unitCount))
              unitRects.append((ul, t, ur, bot))
            }
          }
        } else {
          for _ in 0..<unitCount {
            unitRects.append(nil)
          }
        }
        idx = nextIdx
      }

      var flatCharBounds = [Double](repeating: 0.0, count: utf16Count * 4)
      var i = 0
      while i < utf16Count {
        if let rect = unitRects[i] {
          flatCharBounds[i * 4] = rect.0
          flatCharBounds[i * 4 + 1] = rect.1
          flatCharBounds[i * 4 + 2] = rect.2
          flatCharBounds[i * 4 + 3] = rect.3
          i += 1
        } else {
          var gapEnd = i + 1
          while gapEnd < utf16Count && unitRects[gapEnd] == nil {
            gapEnd += 1
          }
          let gapLeft = i > 0 ? (unitRects[i - 1]?.2 ?? lineLeft) : lineLeft
          let gapRight =
            gapEnd < utf16Count
            ? (unitRects[gapEnd]?.0 ?? lineRight)
            : lineRight
          let safeRight = max(gapLeft, gapRight)
          let gapLen = gapEnd - i
          for g in 0..<gapLen {
            let gl =
              gapLeft + (safeRight - gapLeft) * (Double(g) / Double(gapLen))
            let gr =
              gapLeft
              + (safeRight - gapLeft) * (Double(g + 1) / Double(gapLen))
            let pos = (i + g) * 4
            flatCharBounds[pos] = gl
            flatCharBounds[pos + 1] = lineTop
            flatCharBounds[pos + 2] = gr
            flatCharBounds[pos + 3] = lineBottom
          }
          i = gapEnd
        }
      }

      let charBoundsData = flatCharBounds.withUnsafeBufferPointer { buf in
        Data(buffer: buf)
      }
      lines.append([
        "text": trimmed,
        "bounds": [lineLeft, lineTop, lineRight, lineBottom],
        "charBounds": FlutterStandardTypedData(float64: charBoundsData),
      ])
    }

    let tBoxesEnd = CFAbsoluteTimeGetCurrent()
    return [
      "imageWidth": imageWidth,
      "imageHeight": imageHeight,
      "lines": lines,
      "decodeMs": Int(((tDecodeEnd - t0) * 1000).rounded()),
      "performMs": Int(((tPerformEnd - tDecodeEnd) * 1000).rounded()),
      "boxesMs": Int(((tBoxesEnd - tPerformEnd) * 1000).rounded()),
    ]
  }
}
