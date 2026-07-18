import AVFoundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// 媒体转码通道(音视频压缩到站点 4MB 上限的 Apple 腿):
/// AVAssetReader/Writer,H264(VideoToolbox 硬编)+ AAC,码率精确可控。
/// 与 Dart 侧 MediaTranscoder(com.fluxdo/media_transcode)协议对应。
/// 单任务模型;progress 轮询;cancel 中断。
///
/// 本文件 iOS / macOS 各放一份(内容相同,条件编译 import),改动需同步。
class MediaTranscodeHandler: NSObject {
  static let shared = MediaTranscodeHandler()

  private let workQueue = DispatchQueue(label: "com.fluxdo.media-transcode")
  private var currentReader: AVAssetReader?
  private var currentWriter: AVAssetWriter?
  private var progressValue: Double = 0
  private var cancelled = false
  private var busy = false

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.fluxdo/media_transcode",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] (call, result) in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "probe":
        guard let path = call.arguments as? String else {
          result(nil)
          return
        }
        self.probe(path: path, result: result)
      case "transcode":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "ARGS", message: "参数缺失", details: nil))
          return
        }
        self.startTranscode(args: args, result: result)
      case "progress":
        result(self.progressValue)
      case "cancel":
        self.cancelled = true
        self.currentReader?.cancelReading()
        self.currentWriter?.cancelWriting()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - probe

  private func probe(path: String, result: @escaping FlutterResult) {
    workQueue.async {
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      let seconds = CMTimeGetSeconds(asset.duration)
      guard seconds.isFinite, seconds > 0 else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      let videoTrack = asset.tracks(withMediaType: .video).first
      var out: [String: Any] = [
        "durationMs": Int(seconds * 1000),
        "hasVideo": videoTrack != nil,
      ]
      if let v = videoTrack {
        let size = v.naturalSize.applying(v.preferredTransform)
        out["width"] = Int(abs(size.width))
        out["height"] = Int(abs(size.height))
      }
      DispatchQueue.main.async { result(out) }
    }
  }

  // MARK: - transcode

  private func startTranscode(args: [String: Any], result: @escaping FlutterResult) {
    guard !busy else {
      result(FlutterError(code: "BUSY", message: "已有转码任务进行中", details: nil))
      return
    }
    busy = true
    cancelled = false
    progressValue = 0
    workQueue.async {
      do {
        let ok = try self.runTranscode(args: args)
        DispatchQueue.main.async {
          self.busy = false
          result(ok)
        }
      } catch {
        DispatchQueue.main.async {
          self.busy = false
          result(FlutterError(
            code: "TRANSCODE",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  private struct TranscodeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private func runTranscode(args: [String: Any]) throws -> Bool {
    guard let inputPath = args["input"] as? String,
          let outputPath = args["output"] as? String else {
      throw TranscodeError(message: "input/output 缺失")
    }
    let audioOnly = args["audioOnly"] as? Bool ?? false
    let audioBitrate = args["audioBitrate"] as? Int ?? 64000
    let videoBitrate = args["videoBitrate"] as? Int
    let videoCodec = args["videoCodec"] as? String ?? "h264"
    let maxHeight = args["maxHeight"] as? Int
    let fps = args["fps"] as? Int
    let sampleRate = args["audioSampleRate"] as? Int ?? 44100
    let channels = args["audioChannels"] as? Int ?? 2

    let outputURL = URL(fileURLWithPath: outputPath)
    try? FileManager.default.removeItem(at: outputURL)

    let asset = AVURLAsset(url: URL(fileURLWithPath: inputPath))
    let durationSec = CMTimeGetSeconds(asset.duration)

    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(
      outputURL: outputURL,
      fileType: audioOnly ? .m4a : .mp4
    )
    currentReader = reader
    currentWriter = writer
    defer {
      currentReader = nil
      currentWriter = nil
    }

    var pumps: [(AVAssetWriterInput, AVAssetReaderOutput, Bool)] = []

    // ---- 视频轨(缩放 + 转正 + 降帧 走 videoComposition)----
    if !audioOnly, let vTrack = asset.tracks(withMediaType: .video).first {
      let natural = vTrack.naturalSize.applying(vTrack.preferredTransform)
      let srcW = abs(natural.width)
      let srcH = abs(natural.height)
      guard srcW > 0, srcH > 0 else {
        throw TranscodeError(message: "视频尺寸无效")
      }
      var dstH = CGFloat(maxHeight ?? Int(srcH))
      if dstH > srcH { dstH = srcH } // 只缩不放
      let scale = dstH / srcH
      // 偶数对齐(H264 硬编要求)
      let dstWi = max(2, Int(srcW * scale / 2) * 2)
      let dstHi = max(2, Int(dstH / 2) * 2)

      let comp = AVMutableVideoComposition()
      comp.renderSize = CGSize(width: dstWi, height: dstHi)
      let frameRate = fps ?? Int(round(vTrack.nominalFrameRate > 0 ? vTrack.nominalFrameRate : 30))
      comp.frameDuration = CMTime(value: 1, timescale: Int32(max(1, frameRate)))

      // 竖拍视频经典坑:preferredTransform 转正后 bounding 原点偏移,
      // 必须归零再缩放,否则画面移出渲染区(黑屏)。
      let t = vTrack.preferredTransform
      let bounds = CGRect(origin: .zero, size: vTrack.naturalSize).applying(t)
      var normalized = t
      normalized.tx -= bounds.origin.x
      normalized.ty -= bounds.origin.y
      let finalTransform = normalized.concatenating(
        CGAffineTransform(scaleX: scale, y: scale)
      )

      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
      let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
      layer.setTransform(finalTransform, at: .zero)
      instruction.layerInstructions = [layer]
      comp.instructions = [instruction]

      let vOut = AVAssetReaderVideoCompositionOutput(
        videoTracks: [vTrack],
        videoSettings: [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
      )
      vOut.videoComposition = comp
      guard reader.canAdd(vOut) else {
        throw TranscodeError(message: "无法读取视频轨")
      }
      reader.add(vOut)

      // HEVC:AVAssetWriter 产物即 Safari 要求的 hvc1 tag;profile
      // 留系统默认(Main 自动)。老设备(无 HEVC 硬编)writer 会在
      // startWriting/append 阶段失败 → 上层策略回退 H264 档。
      let useHevc = videoCodec == "hevc"
      var compression: [String: Any] = [
        AVVideoAverageBitRateKey: videoBitrate ?? 500_000
      ]
      if !useHevc {
        compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264MainAutoLevel
      }
      let vSettings: [String: Any] = [
        AVVideoCodecKey: useHevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
        AVVideoWidthKey: dstWi,
        AVVideoHeightKey: dstHi,
        AVVideoCompressionPropertiesKey: compression,
      ]
      let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
      vIn.expectsMediaDataInRealTime = false
      guard writer.canAdd(vIn) else {
        throw TranscodeError(message: "无法写入视频轨")
      }
      writer.add(vIn)
      pumps.append((vIn, vOut, true))
    }

    // ---- 音频轨 ----
    let audioTracks = asset.tracks(withMediaType: .audio)
    if !audioTracks.isEmpty {
      let aOut = AVAssetReaderAudioMixOutput(
        audioTracks: audioTracks,
        audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
      )
      guard reader.canAdd(aOut) else {
        throw TranscodeError(message: "无法读取音频轨")
      }
      reader.add(aOut)

      let aSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: channels,
        AVSampleRateKey: sampleRate,
        AVEncoderBitRateKey: audioBitrate,
      ]
      let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
      aIn.expectsMediaDataInRealTime = false
      guard writer.canAdd(aIn) else {
        throw TranscodeError(message: "无法写入音频轨")
      }
      writer.add(aIn)
      // 纯音频时音频轨承担进度上报
      pumps.append((aIn, aOut, audioOnly))
    } else if audioOnly {
      throw TranscodeError(message: "文件不含音频轨")
    }

    guard !pumps.isEmpty else {
      throw TranscodeError(message: "文件不含可转码轨道")
    }

    guard writer.startWriting() else {
      throw writer.error ?? TranscodeError(message: "writer 启动失败")
    }
    guard reader.startReading() else {
      writer.cancelWriting()
      throw reader.error ?? TranscodeError(message: "reader 启动失败")
    }
    writer.startSession(atSourceTime: .zero)

    let group = DispatchGroup()
    for (input, output, drivesProgress) in pumps {
      group.enter()
      var finished = false
      let pumpQueue = DispatchQueue(label: "com.fluxdo.transcode-pump")
      input.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
        guard let self = self, !finished else { return }
        while input.isReadyForMoreMediaData {
          if self.cancelled {
            finished = true
            input.markAsFinished()
            group.leave()
            return
          }
          guard let sample = output.copyNextSampleBuffer() else {
            finished = true
            input.markAsFinished()
            group.leave()
            return
          }
          if drivesProgress, durationSec > 0 {
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if t.isFinite {
              self.progressValue = min(1, max(self.progressValue, t / durationSec))
            }
          }
          if !input.append(sample) {
            // writer 进入失败态,终止本泵;错误在收尾统一上抛
            finished = true
            input.markAsFinished()
            group.leave()
            return
          }
        }
      }
    }
    group.wait()

    if cancelled {
      reader.cancelReading()
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      return false
    }
    if reader.status == .failed {
      writer.cancelWriting()
      throw reader.error ?? TranscodeError(message: "读取失败")
    }
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else {
      throw writer.error ?? TranscodeError(message: "写出失败")
    }
    progressValue = 1
    return true
  }
}
