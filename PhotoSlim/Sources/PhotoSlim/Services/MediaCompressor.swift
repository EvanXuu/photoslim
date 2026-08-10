import AVFoundation
import Foundation
import ImageIO
import PhotoSlimMediaCore
import UniformTypeIdentifiers
import VideoToolbox

enum CompressionError: LocalizedError {
  case invalidImage
  case cannotCreateDestination
  case imageEncodingFailed
  case missingVideoTrack
  case reader(String)
  case writer(String)
  case writerAppend(track: String, detail: String)
  case outputVerification(String)
  case insufficientSavings(actual: Double, required: Double)
  case insufficientDiskSpace(required: Int64, available: Int64)
  case originalSizeUnavailable
  case unsupportedVideoCodec(String)
  case hdrVideoUnsupported
  case hardwareHEVCUnavailable
  case exportSession(String)

  var isAudioAppendFailure: Bool {
    guard case .writerAppend(let track, _) = self else { return false }
    return track == "音频"
  }

  var errorDescription: String? {
    switch self {
    case .invalidImage: return "原始图片无法解码。"
    case .cannotCreateDestination: return "无法创建压缩输出文件。"
    case .imageEncodingFailed: return "HEIC 编码失败。"
    case .missingVideoTrack: return "原文件没有可用的视频轨道。"
    case .reader(let message): return "读取视频失败：\(message)"
    case .writer(let message): return "写入 HEVC 视频失败：\(message)"
    case .writerAppend(let track, let detail):
      return "写入 HEVC 视频失败：\(track)轨道无法追加媒体样本（\(detail)）"
    case .outputVerification(let message): return "本地输出验证失败：\(message)"
    case .insufficientSavings(let actual, let required):
      if actual < 0 {
        return "输出比原件大 \(Int(abs(actual) * 100))%，无法达到设置的 \(Int(required * 100))% 节省。"
      }
      return "实际只节省 \(Int(actual * 100))%，低于设置的 \(Int(required * 100))%。"
    case .insufficientDiskSpace(let required, let available):
      let shortfall = max(0, required - available)
      return "下载后的实际文件需要再保留 \(MediaFormatting.bytes(shortfall)) 临时空间，当前可用空间不足。原件未修改。"
    case .originalSizeUnavailable:
      return "下载完成，但无法读取原视频的实际文件大小。为避免错误计算压缩率，已安全跳过。"
    case .unsupportedVideoCodec(let codec):
      return "下载后的原视频是 \(codec)，不是本版本支持的 H.264 或普通 hvc1 HEVC，已安全跳过。"
    case .hdrVideoUnsupported:
      return "下载后的原视频包含 HDR/HLG/PQ 色彩信息，已安全跳过。"
    case .hardwareHEVCUnavailable:
      return "当前设备没有可用的 HEVC 硬件编码器。原件未修改。"
    case .exportSession(let message):
      return "Apple 视频导出接口失败：\(message)"
    }
  }
}

private extension CompressionError {
  var canRetryWithExportSession: Bool {
    switch self {
    case .reader(_), .writer(_), .writerAppend(_, _):
      return true
    default:
      return false
    }
  }
}

struct CompressionOutput: Sendable {
  let fileURL: URL
  let byteCount: Int64
  let originalFilename: String
}

enum ImageCompressor {
  static func compress(
    original: ImageOriginal,
    to outputURL: URL,
    quality: Double,
    sessionMarker: String
  ) throws {
    guard let source = CGImageSourceCreateWithData(original.data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else {
      throw CompressionError.invalidImage
    }
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    guard
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.heic.identifier as CFString,
        1,
        nil
      )
    else {
      throw CompressionError.cannotCreateDestination
    }

    var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality))
    var exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
    exif[kCGImagePropertyExifUserComment] = "PhotoSlim session \(sessionMarker)"
    properties[kCGImagePropertyExifDictionary] = exif
    properties[kCGImagePropertyOrientation] = original.orientation.rawValue
    CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw CompressionError.imageEncodingFailed
    }
  }
}

final class VideoCompressor: @unchecked Sendable {
  private struct TrackPipe: @unchecked Sendable {
    let label: String
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let reportsProgress: Bool
  }

  private final class CopyState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
      lock.lock()
      if cancelled {
        lock.unlock()
        continuation.resume(throwing: CancellationError())
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }

    func finish(_ result: Result<Void, Error>) {
      lock.lock()
      guard let continuation else {
        lock.unlock()
        return
      }
      self.continuation = nil
      lock.unlock()
      switch result {
      case .success:
        continuation.resume()
      case .failure(let error):
        continuation.resume(throwing: error)
      }
    }

    func cancel() {
      lock.lock()
      cancelled = true
      let continuation = self.continuation
      self.continuation = nil
      lock.unlock()
      continuation?.resume(throwing: CancellationError())
    }
  }

  func compress(
    asset: AVAsset,
    to outputURL: URL,
    settings: CompressionSettings,
    fallbackSourceBytes: Int64,
    sessionMarker: String,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    do {
      try await compressOnce(
        asset: asset,
        to: outputURL,
        settings: settings,
        fallbackSourceBytes: fallbackSourceBytes,
        sessionMarker: sessionMarker,
        audioPolicy: settings.audioPolicy,
        progress: progress
      )
    } catch let firstError as CompressionError
      where firstError.isAudioAppendFailure
        && settings.audioPolicy == .passthroughWhenPossible
    {
      // Some iCloud/社交媒体视频 advertise a passthrough audio format that
      // AVAssetWriter accepts during setup but rejects on a later sample. The
      // video itself is still valid, so retry with a normalized AAC track.
      do {
        try await compressOnce(
          asset: asset,
          to: outputURL,
          settings: settings,
          fallbackSourceBytes: fallbackSourceBytes,
          sessionMarker: sessionMarker,
          audioPolicy: .aac,
          progress: progress
        )
      } catch {
        throw CompressionError.writer(
          "原音频直通失败（\(firstError.localizedDescription)）；改用 AAC 后仍失败：\(error.localizedDescription)"
        )
      }
    }
  }

  private func compressOnce(
    asset: AVAsset,
    to outputURL: URL,
    settings: CompressionSettings,
    fallbackSourceBytes: Int64,
    sessionMarker: String,
    audioPolicy: AudioPolicy,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    try Task.checkCancellation()
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw CompressionError.missingVideoTrack
    }
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }

    let reader: AVAssetReader
    do {
      reader = try AVAssetReader(asset: asset)
    } catch {
      throw CompressionError.reader(error.localizedDescription)
    }
    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    } catch {
      throw CompressionError.writer(error.localizedDescription)
    }
    writer.shouldOptimizeForNetworkUse = false
    writer.metadata = try await Self.metadata(from: asset, sessionMarker: sessionMarker)

    let naturalSize = try await videoTrack.load(.naturalSize)
    let preferredTransform = try await videoTrack.load(.preferredTransform)
    let estimatedDataRate = try await videoTrack.load(.estimatedDataRate)
    let videoTimeRange = try await videoTrack.load(.timeRange)
    let duration = try await asset.load(.duration)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    var audioStartTimes: [CMTime] = []
    var audioDataRate = 0.0
    audioStartTimes.reserveCapacity(audioTracks.count)
    for audioTrack in audioTracks {
      let timeRange = try await audioTrack.load(.timeRange)
      audioStartTimes.append(timeRange.start)
      let rate = Double(try await audioTrack.load(.estimatedDataRate))
      if rate.isFinite, rate > 0 { audioDataRate += rate }
    }
    let sessionStart = ([videoTimeRange.start] + audioStartTimes).min {
      CMTimeCompare($0, $1) < 0
    } ?? videoTimeRange.start
    let width = max(2, Int(abs(naturalSize.width).rounded()))
    let height = max(2, Int(abs(naturalSize.height).rounded()))
    let durationSeconds = max(CMTimeGetSeconds(duration), 1)
    let measuredTotalRate = fallbackSourceBytes > 0
      ? Double(fallbackSourceBytes) * 8 / durationSeconds
      : 0
    let advertisedTotalRate = Double(estimatedDataRate) + audioDataRate
    let sourceTotalRate = measuredTotalRate > 0
      ? measuredTotalRate
      : max(advertisedTotalRate, 0)
    let targetRate: Int
    switch settings.videoBitrateMode {
    case .sourceRatio:
      let sourceVideoRate = max(32_000, sourceTotalRate - max(audioDataRate, 0))
      targetRate = Int(max(32_000, sourceVideoRate * settings.videoBitrateRatio))
    case .manual:
      // Manual mode is a video-only bitrate. Audio is added separately and is
      // never allowed to consume the manually requested video budget.
      targetRate = max(32, settings.videoTargetBitrateKbps) * 1_000
    }
    let boundedTargetRate = settings.videoMaxBitrateKbps > 0
      ? min(targetRate, max(32_000, settings.videoMaxBitrateKbps * 1_000))
      : targetRate

    // Configure the HEVC encoder through VideoToolbox properties directly.
    // AVVideoQualityKey is intentionally absent: it is not a generic HEVC
    // quality control and previously made output size unpredictable.
    var compression: [String: Any] = [
      kVTCompressionPropertyKey_AverageBitRate as String: boundedTargetRate,
      kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_HEVC_Main_AutoLevel,
      kVTCompressionPropertyKey_AllowFrameReordering as String:
        settings.videoAllowFrameReordering,
      kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String:
        max(0.25, settings.videoKeyframeIntervalSeconds),
    ]
    if settings.videoMaxBitrateKbps > 0 {
      let maximumRate = max(32_000, settings.videoMaxBitrateKbps * 1_000)
      compression[kVTCompressionPropertyKey_DataRateLimits as String] = [
        NSNumber(value: max(1, maximumRate / 8)),
        NSNumber(value: 1),
      ]
    }
    let outputSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
    ]
    let pixelSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ]
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: pixelSettings)
    videoOutput.alwaysCopiesSampleData = false
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    videoInput.expectsMediaDataInRealTime = false
    videoInput.transform = preferredTransform
    guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
      throw CompressionError.writer("当前视频轨道不支持 HEVC 转换。")
    }
    reader.add(videoOutput)
    writer.add(videoInput)

    var pipes = [
      TrackPipe(label: "视频", output: videoOutput, input: videoInput, reportsProgress: true)
    ]
    for audioTrack in audioTracks {
      let formatHint = try await audioTrack.load(.formatDescriptions).first
      var addedAudioPipe = false

      if audioPolicy == .passthroughWhenPossible {
        let passthroughOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        passthroughOutput.alwaysCopiesSampleData = false
        let passthroughInput = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: nil,
          sourceFormatHint: formatHint
        )
        passthroughInput.expectsMediaDataInRealTime = false
        if reader.canAdd(passthroughOutput), writer.canAdd(passthroughInput) {
          reader.add(passthroughOutput)
          writer.add(passthroughInput)
          pipes.append(
            TrackPipe(
              label: "音频",
              output: passthroughOutput,
              input: passthroughInput,
              reportsProgress: false
            ))
          addedAudioPipe = true
        }
      }

      if !addedAudioPipe {
        let pcmOutput = AVAssetReaderTrackOutput(
          track: audioTrack,
          outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM
          ])
        pcmOutput.alwaysCopiesSampleData = false
        let audioInfo = formatHint.map(Self.audioDescription) ?? (channels: 2, sampleRate: 48_000)
        let aacInput = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: settings.aacBitrate,
            AVNumberOfChannelsKey: max(1, audioInfo.channels),
            AVSampleRateKey: audioInfo.sampleRate,
          ])
        aacInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(pcmOutput), writer.canAdd(aacInput) else {
          throw CompressionError.writer("无法保留或转换音频轨道。")
        }
        reader.add(pcmOutput)
        writer.add(aacInput)
        pipes.append(
          TrackPipe(label: "音频", output: pcmOutput, input: aacInput, reportsProgress: false)
        )
      }
    }

    // Timed metadata tracks from AVComposition/iCloud assets are not uniformly
    // writable in a new HEVC .mov. Global metadata is copied above and the
    // PhotoKit creation request restores date/location/favorite/album fields.
    // Skipping this optional track avoids rejecting an otherwise valid video.

    guard writer.startWriting() else {
      throw CompressionError.writer(writer.error?.localizedDescription ?? "无法开始写入")
    }
    guard reader.startReading() else {
      throw CompressionError.reader(reader.error?.localizedDescription ?? "无法开始读取")
    }
    writer.startSession(atSourceTime: sessionStart)
    progress(0)
    try Task.checkCancellation()

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for pipe in pipes {
          group.addTask {
            try await Self.copy(
              pipe: pipe,
              startTime: videoTimeRange.start,
              duration: duration,
              progress: progress
            )
          }
        }
        try await group.waitForAll()
      }
    } catch let error as CompressionError {
      reader.cancelReading()
      let detail = writer.error?.localizedDescription ?? "写入器拒绝了当前样本"
      writer.cancelWriting()
      if case .writerAppend(let track, _) = error {
        throw CompressionError.writerAppend(track: track, detail: detail)
      }
      throw error
    } catch {
      reader.cancelReading()
      writer.cancelWriting()
      throw error
    }

    try Task.checkCancellation()
    if reader.status == .failed {
      writer.cancelWriting()
      throw CompressionError.reader(reader.error?.localizedDescription ?? "未知错误")
    }
    await withCheckedContinuation { continuation in
      writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else {
      throw CompressionError.writer(writer.error?.localizedDescription ?? "输出未完成")
    }
    progress(1)
  }

  private static func copy(
    pipe: TrackPipe,
    startTime: CMTime,
    duration: CMTime,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let queue = DispatchQueue(label: "local.photoslim.track-copy.\(UUID().uuidString)")
    let state = CopyState()
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        state.install(continuation)
        guard !state.isCancelled else { return }
        pipe.input.requestMediaDataWhenReady(on: queue) {
          guard !state.isCancelled else {
            pipe.input.markAsFinished()
            return
          }
          while pipe.input.isReadyForMoreMediaData {
            if state.isCancelled {
              pipe.input.markAsFinished()
              return
            }
            guard let buffer = pipe.output.copyNextSampleBuffer() else {
              pipe.input.markAsFinished()
              state.finish(.success(()))
              return
            }
            if pipe.reportsProgress {
              let total = max(CMTimeGetSeconds(duration), 0.001)
              let current = CMTimeGetSeconds(
                CMSampleBufferGetPresentationTimeStamp(buffer) - startTime
              )
              if current.isFinite { progress(min(0.99, max(0, current / total))) }
            }
            guard pipe.input.append(buffer) else {
              state.finish(
                .failure(
                  CompressionError.writerAppend(
                    track: pipe.label,
                    detail: "写入器拒绝了当前样本"
                  )
                )
              )
              return
            }
          }
        }
      }
    }, onCancel: {
      state.cancel()
      pipe.input.markAsFinished()
    })
  }

  static func metadata(from asset: AVAsset, sessionMarker: String) async throws -> [AVMetadataItem]
  {
    var items = try await asset.load(.metadata)
    let marker = AVMutableMetadataItem()
    marker.identifier = .quickTimeMetadataComment
    marker.value = "PhotoSlim session \(sessionMarker)" as NSString
    marker.dataType = kCMMetadataBaseDataType_UTF8 as String
    items.append(marker)
    return items
  }

  private static func audioDescription(_ description: CMFormatDescription) -> (
    channels: Int, sampleRate: Double
  ) {
    guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
      return (2, 48_000)
    }
    return (
      max(1, Int(basic.pointee.mChannelsPerFrame)),
      max(8_000, basic.pointee.mSampleRate)
    )
  }
}

/// Apple’s export session is the compatibility path for media whose color,
/// timed metadata, or track layout is not safe to flatten through a plain
/// 8-bit AVAssetReader/Writer pipeline. The selected preset is the closest
/// available HEVC preset; AVAssetExportSession intentionally does not expose
/// the detailed bitrate/GOP controls used by the manual path.
@MainActor
final class ExportSessionVideoCompressor {
  private final class CancellationBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(session: AVAssetExportSession) {
      self.session = session
    }

    func cancel() {
      session.cancelExport()
    }
  }

  nonisolated init() {}

  func compress(
    asset: AVAsset,
    to outputURL: URL,
    sessionMarker: String,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }

    let candidates = [
      AVAssetExportPresetHEVCHighestQuality,
      AVAssetExportPresetHEVC3840x2160,
      AVAssetExportPresetHEVC1920x1080,
    ]
    var preset: String?
    for candidate in candidates {
      if await AVAssetExportSession.compatibility(
        ofExportPreset: candidate,
        with: asset,
        outputFileType: nil
      ) {
        preset = candidate
        break
      }
    }
    guard let preset else {
      throw CompressionError.exportSession("当前系统没有可用的 HEVC 导出预设")
    }
    guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw CompressionError.exportSession("无法创建导出会话")
    }

    session.outputURL = outputURL
    session.outputFileType = session.supportedFileTypes.contains(.mov) ? .mov : session.supportedFileTypes.first
    session.shouldOptimizeForNetworkUse = false
    session.metadata = try await VideoCompressor.metadata(
      from: asset,
      sessionMarker: sessionMarker
    )

    progress(0)
    let monitor = Task { @MainActor in
      while !Task.isCancelled {
        progress(Double(session.progress))
        if session.status == .completed || session.status == .failed
          || session.status == .cancelled
        {
          break
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
      }
    }
    let cancellation = CancellationBox(session: session)

    await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        session.exportAsynchronously {
          continuation.resume()
        }
      }
    }, onCancel: {
      cancellation.cancel()
    })
    monitor.cancel()

    if Task.isCancelled { throw CancellationError() }
    guard session.status == .completed else {
      throw CompressionError.exportSession(
        session.error?.localizedDescription ?? "导出没有完成"
      )
    }
    progress(1)
  }
}

struct MediaCompressionEngine: Sendable {
  private let videoCompressor = VideoCompressor()
  private let exportSessionCompressor = ExportSessionVideoCompressor()

  func compress(
    source: MediaAsset,
    imageOriginal: ImageOriginal?,
    videoAsset: AVAsset?,
    directory: URL,
    settings: CompressionSettings,
    sessionID: UUID,
    itemID: UUID,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> CompressionOutput {
    let marker = "\(sessionID.uuidString)/\(itemID.uuidString)"
    let base = URL(fileURLWithPath: source.filename).deletingPathExtension().lastPathComponent
    let safeBase = base.isEmpty ? "PhotoSlim" : base
    let outputFilename = source.kind == .photo ? "\(safeBase).heic" : "\(safeBase).mov"
    let workingFilename = "\(itemID.uuidString)-\(outputFilename)"
    let outputURL = directory.appendingPathComponent(workingFilename)
    var measuredInputBytes = source.originalBytes ?? source.inputBytesForPlanning

    switch source.kind {
    case .photo:
      guard let imageOriginal else { throw CompressionError.invalidImage }
      measuredInputBytes = Int64(imageOriginal.data.count)
      progress(0)
      try ImageCompressor.compress(
        original: imageOriginal,
        to: outputURL,
        quality: settings.photoQuality,
        sessionMarker: marker
      )
      progress(1)
      try verifyImage(at: outputURL, source: source)
    case .video:
      guard let videoAsset else { throw CompressionError.missingVideoTrack }
      if let urlAsset = videoAsset as? AVURLAsset,
        let fileSize = try? urlAsset.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        fileSize > 0
      {
        measuredInputBytes = Int64(fileSize)
      }
      guard measuredInputBytes > 0 else { throw CompressionError.originalSizeUnavailable }

      let route = try await videoEncodingRoute(videoAsset)
      switch route {
      case .exportSession:
        try await exportSessionCompressor.compress(
          asset: videoAsset,
          to: outputURL,
          sessionMarker: marker,
          progress: progress
        )
      case .manualVideoToolbox:
        guard PhotoSlimMediaCore.supportsHardwareHEVCEncoding else {
          throw CompressionError.hardwareHEVCUnavailable
        }
        do {
          try await videoCompressor.compress(
            asset: videoAsset,
            to: outputURL,
            settings: settings,
            fallbackSourceBytes: measuredInputBytes,
            sessionMarker: marker,
            progress: progress
          )
        } catch let error as CompressionError where error.canRetryWithExportSession {
          // Keep the manually controlled hardware path as the default. If a
          // track layout or sample is rejected, let Apple's compatibility path
          // handle it rather than claiming that the source is unsupported.
          try await exportSessionCompressor.compress(
            asset: videoAsset,
            to: outputURL,
            sessionMarker: marker,
            progress: progress
          )
        }
      }
      try await verifyVideo(at: outputURL, source: source)
    }

    let bytes = Int64((try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    guard bytes > 0 else { throw CompressionError.outputVerification("输出文件为空") }
    if measuredInputBytes > 0 {
      let savings = Double(measuredInputBytes - bytes) / Double(measuredInputBytes)
      guard savings >= settings.minimumSavingsRatio else {
        throw CompressionError.insufficientSavings(
          actual: savings, required: settings.minimumSavingsRatio)
      }
    }
    return CompressionOutput(fileURL: outputURL, byteCount: bytes, originalFilename: outputFilename)
  }

  private enum VideoEncodingRoute {
    case manualVideoToolbox
    case exportSession
  }

  private func videoEncodingRoute(_ asset: AVAsset) async throws -> VideoEncodingRoute {
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard !tracks.isEmpty else {
      throw CompressionError.missingVideoTrack
    }
    let h264Subtypes: Set<FourCharCode> = [
      kCMVideoCodecType_H264,
      VideoCodecClassifier.fourCC("avc3"),
    ]
    let hevcSubtypes: Set<FourCharCode> = [
      kCMVideoCodecType_HEVC,
      kCMVideoCodecType_HEVCWithAlpha,
      VideoCodecClassifier.fourCC("hvc1"),
      VideoCodecClassifier.fourCC("hev1"),
      VideoCodecClassifier.fourCC("dvh1"),
      VideoCodecClassifier.fourCC("dvhe"),
    ]
    var allDescriptions: [CMFormatDescription] = []
    for track in tracks {
      allDescriptions.append(contentsOf: try await track.load(.formatDescriptions))
    }
    guard !allDescriptions.isEmpty else {
      throw CompressionError.missingVideoTrack
    }
    let subtypes = allDescriptions.map(CMFormatDescriptionGetMediaSubType)
    if subtypes.contains(where: hevcSubtypes.contains) {
      // A plain hvc1 track is safe to decode and encode again through the same
      // hardware HEVC path. hev1, Dolby Vision entries, alpha HEVC and mixed
      // track layouts stay excluded because their extra decoder semantics are
      // not guaranteed to survive a flattening transcode.
      let isPlainHVC1 = VideoCodecClassifier.isHVC1(subtypes)
      guard isPlainHVC1 else {
        let subtype = subtypes.first(where: hevcSubtypes.contains) ?? 0
        throw CompressionError.unsupportedVideoCodec(fourCC(subtype))
      }
      let hasHDR = allDescriptions.contains(where: formatDescriptionIsHDR)
      let timedMetadataTracks = (try? await asset.loadTracks(withMediaType: .metadata)) ?? []
      if hasHDR || !timedMetadataTracks.isEmpty {
        return .exportSession
      }
      return .manualVideoToolbox
    }
    guard let unsupportedSubtype = subtypes.first(where: { !h264Subtypes.contains($0) }) else {
      let hasHDR = allDescriptions.contains(where: formatDescriptionIsHDR)
      let timedMetadataTracks = (try? await asset.loadTracks(withMediaType: .metadata)) ?? []
      if hasHDR || !timedMetadataTracks.isEmpty {
        return .exportSession
      }
      return .manualVideoToolbox
    }
    throw CompressionError.unsupportedVideoCodec(fourCC(unsupportedSubtype))
  }

  private func fourCC(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08X", code)
  }

  private func formatDescriptionIsHDR(_ description: CMFormatDescription) -> Bool {
    guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] else {
      return false
    }
    let text = String(describing: extensions).lowercased()
    return text.contains("2084") || text.contains("hlg") || text.contains("smpte_st_2084")
  }


  private func verifyImage(at url: URL, source: MediaAsset) throws {
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
      CGImageSourceGetCount(imageSource) == 1,
      let type = CGImageSourceGetType(imageSource),
      UTType(type as String)?.conforms(to: .heic) == true,
      let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width == source.pixelWidth,
      height == source.pixelHeight
    else {
      throw CompressionError.outputVerification("HEIC 编码或像素尺寸不正确")
    }
  }

  private func verifyVideo(at url: URL, source: MediaAsset) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first,
      let description = try await track.load(.formatDescriptions).first
    else {
      throw CompressionError.outputVerification("缺少视频轨道")
    }
    guard VideoCodecClassifier.isHEVC(CMFormatDescriptionGetMediaSubType(description)) else {
      throw CompressionError.outputVerification("输出不是 HEVC")
    }
    let naturalSize = try await track.load(.naturalSize)
    let preferredTransform = try await track.load(.preferredTransform)
    let transformed = naturalSize.applying(preferredTransform)
    let rawWidth = Int(abs(naturalSize.width).rounded())
    let rawHeight = Int(abs(naturalSize.height).rounded())
    let displayWidth = Int(abs(transformed.width).rounded())
    let displayHeight = Int(abs(transformed.height).rounded())
    let sourceDimensions = (source.pixelWidth, source.pixelHeight)
    let rawMatches = MediaDimensionMatcher.matches(
      outputWidth: rawWidth,
      outputHeight: rawHeight,
      sourceWidth: sourceDimensions.0,
      sourceHeight: sourceDimensions.1
    )
    let displayMatches = MediaDimensionMatcher.matches(
      outputWidth: displayWidth,
      outputHeight: displayHeight,
      sourceWidth: sourceDimensions.0,
      sourceHeight: sourceDimensions.1
    )
    guard rawMatches || displayMatches else {
      throw CompressionError.outputVerification(
        "视频尺寸不一致（输出轨道 \(rawWidth)×\(rawHeight)，显示尺寸 \(displayWidth)×\(displayHeight)；原件 \(source.pixelWidth)×\(source.pixelHeight)）"
      )
    }
    let duration = CMTimeGetSeconds(try await asset.load(.duration))
    guard abs(duration - source.duration) <= max(0.15, source.duration * 0.001) else {
      throw CompressionError.outputVerification("视频时长不一致")
    }
  }

}
