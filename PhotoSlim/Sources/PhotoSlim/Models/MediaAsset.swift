import Foundation

enum MediaKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case photo
  case video

  var id: String { rawValue }
  var title: String { self == .photo ? "照片" : "视频" }
  var symbolName: String { self == .photo ? "photo" : "video" }
}

enum MediaFormatGroup: String, Codable, CaseIterable, Identifiable, Sendable {
  case jpeg
  case heic
  case png
  case raw
  case h264
  case hevc
  case other
  case unknown

  var id: String { rawValue }

  var title: String {
    switch self {
    case .jpeg: return "JPEG"
    case .heic: return "HEIC"
    case .png: return "PNG"
    case .raw: return "RAW"
    case .h264: return "H.264"
    case .hevc: return "HEVC"
    case .other: return "其他"
    case .unknown: return "待识别"
    }
  }
}

enum ExclusionReason: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
  case alreadyProcessed
  case efficientCodec
  case edited
  case raw
  case livePhoto
  case hdr
  case highFrameRate
  case cinematic
  case spatial
  case hidden
  case transparencyOrAnimation
  case screenRecording
  case lowSavings
  case codecUnverified
  case unsupported

  var id: String { rawValue }

  var title: String {
    switch self {
    case .alreadyProcessed: return "已经由 PhotoSlim 处理"
    case .efficientCodec: return "已是高效编码"
    case .edited: return "已编辑资产"
    case .raw: return "RAW / ProRAW"
    case .livePhoto: return "Live Photo"
    case .hdr: return "HDR / Dolby Vision"
    case .highFrameRate: return "慢动作 / 高帧率"
    case .cinematic: return "电影效果视频"
    case .spatial: return "空间媒体"
    case .hidden: return "隐藏媒体"
    case .transparencyOrAnimation: return "透明或动画图片"
    case .screenRecording: return "屏幕录制"
    case .lowSavings: return "节省不足"
    case .codecUnverified: return "编码待下载确认"
    case .unsupported: return "暂不支持"
    }
  }

  var warning: String {
    switch self {
    case .alreadyProcessed:
      return "这个项目已经出现在已确认完成的 PhotoSlim 任务中。为避免重复有损压缩，它只能查看，不能再次加入任务。"
    case .efficientCodec:
      return "这些项目已经使用 HEIC 或 HEVC。再次有损压缩通常收益很小，且会累积画质损失。"
    case .edited:
      return "公开 PhotoKit 不能复制可逆编辑历史。首版只展示这些项目，不会处理。"
    case .raw:
      return "RAW 和 ProRAW 是数字底片。首版不会压缩或替换它们。"
    case .livePhoto:
      return "Live Photo 包含配对照片和视频。首版不会拆分或替换它们。"
    case .hdr:
      return "HDR 或 Dolby Vision 的色彩和动态元数据可能无法完整保留。首版不会处理。"
    case .highFrameRate:
      return "慢动作和高帧率视频包含特殊时间关系。首版不会处理。"
    case .cinematic:
      return "电影效果视频包含景深和对焦数据。首版不会处理。"
    case .spatial:
      return "空间媒体包含特殊轨道。首版不会处理。"
    case .hidden:
      return "显示隐藏媒体可能暴露私密内容。确认后可以把受支持项目加入任务。"
    case .transparencyOrAnimation:
      return "转换可能丢失透明通道或动画。首版不会处理。"
    case .screenRecording:
      return "屏幕录制中的细小文字和界面边缘对压缩更敏感。确认后可以处理。"
    case .lowSavings:
      return "预计节省低于当前阈值，转换可能不值得。你可以显示这些项目再单独决定。"
    case .codecUnverified:
      return "这个视频的原件目前只在 iCloud 中。公开 PhotoKit 无法在不下载原件的情况下确认它是 H.264 还是 HEVC；下载后仍会强制验证，已经是 HEVC 的视频会安全跳过。"
    case .unsupported:
      return "当前版本无法安全验证这种媒体。显示它不会解除处理限制。"
    }
  }

  var isHardBlock: Bool {
    switch self {
    case .alreadyProcessed, .edited, .raw, .livePhoto, .hdr, .highFrameRate, .cinematic,
      .spatial, .transparencyOrAnimation, .efficientCodec, .unsupported:
      return true
    case .hidden, .screenRecording, .lowSavings, .codecUnverified:
      return false
    }
  }

  static let defaultExcluded = Set(Self.allCases).subtracting([.codecUnverified])
}

struct MediaAsset: Identifiable, Codable, Hashable, Sendable {
  let id: String
  var kind: MediaKind
  var format: MediaFormatGroup
  var filename: String
  var uniformTypeIdentifier: String
  var creationDate: Date?
  var modificationTimestamp: TimeInterval? = nil
  var pixelWidth: Int
  var pixelHeight: Int
  var duration: Double
  var isFavorite: Bool
  var isHidden: Bool
  var isCloudOnly: Bool
  var locationLatitude: Double? = nil
  var locationLongitude: Double? = nil
  var locationAltitude: Double? = nil
  var originalBytes: Int64?
  var estimatedOutputBytes: Int64?
  var codec: String?
  var albumIdentifiers: [String]
  var exclusionReasons: Set<ExclusionReason>
  /// A browser-only preference persisted with the library index. Pinning never
  /// changes processing eligibility or the PhotoKit asset itself.
  var isPinned: Bool = false

  var estimatedSavingsBytes: Int64? {
    guard let originalBytes, let estimatedOutputBytes else { return nil }
    return max(0, originalBytes - estimatedOutputBytes)
  }

  var estimatedSavingsRatio: Double? {
    guard let originalBytes, originalBytes > 0, let estimatedSavingsBytes else { return nil }
    return Double(estimatedSavingsBytes) / Double(originalBytes)
  }

  var inputBytesForPlanning: Int64 {
    // PhotoKit does not expose a reliable remote-original byte count before
    // the resource is downloaded. Zero is intentional: callers must render
    // the value as unknown instead of inventing a size estimate.
    originalBytes ?? 0
  }

  var outputBytesForPlanning: Int64 {
    // A cloud-only item has no preflight output estimate either. Its source
    // and output sizes are measured after the download and encode complete.
    guard originalBytes != nil else { return 0 }
    return estimatedOutputBytes ?? 0
  }

  var canProcess: Bool {
    exclusionReasons.allSatisfy { !$0.isHardBlock }
      && (format == .jpeg || format == .h264
        || (kind == .video && format == .hevc && codec == "HEVC (hvc1)")
        || (kind == .video && isCloudOnly && format == .unknown))
  }

  var isPlainHVC1: Bool {
    kind == .video && codec == "HEVC (hvc1)"
  }

  var displayTitle: String {
    filename.isEmpty ? (kind == .photo ? "未命名照片" : "未命名视频") : filename
  }

  var dimensionsLabel: String {
    pixelWidth > 0 && pixelHeight > 0 ? "\(pixelWidth) × \(pixelHeight)" : "尺寸未知"
  }

  mutating func refreshPlanning(
    settings: CompressionSettings,
    processedIdentifiers: Set<String>
  ) {
    exclusionReasons.remove(.lowSavings)
    exclusionReasons.remove(.alreadyProcessed)

    if processedIdentifiers.contains(id) {
      exclusionReasons.insert(.alreadyProcessed)
    }

    guard let inputBytes = originalBytes, inputBytes > 0 else {
      // Do not calculate or persist a synthetic cloud size. The low-savings
      // exclusion is decided only after the real resource has been downloaded.
      estimatedOutputBytes = nil
      return
    }

    let outputBytes = MediaPlanning.estimatedOutputBytes(
      inputBytes: inputBytes,
      kind: kind,
      settings: settings,
      duration: duration
    )
    estimatedOutputBytes = outputBytes
    if Double(max(0, inputBytes - outputBytes)) / Double(inputBytes)
      < settings.minimumSavingsRatio
    {
      exclusionReasons.insert(.lowSavings)
    }
  }
}

extension MediaAsset {
  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case format
    case filename
    case uniformTypeIdentifier
    case creationDate
    case modificationTimestamp
    case pixelWidth
    case pixelHeight
    case duration
    case isFavorite
    case isHidden
    case isCloudOnly
    case locationLatitude
    case locationLongitude
    case locationAltitude
    case originalBytes
    case estimatedOutputBytes
    case codec
    case albumIdentifiers
    case exclusionReasons
    case isPinned
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(MediaKind.self, forKey: .kind)
    format = try container.decode(MediaFormatGroup.self, forKey: .format)
    filename = try container.decode(String.self, forKey: .filename)
    uniformTypeIdentifier = try container.decode(String.self, forKey: .uniformTypeIdentifier)
    creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
    modificationTimestamp = try container.decodeIfPresent(
      TimeInterval.self,
      forKey: .modificationTimestamp
    )
    pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
    pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
    duration = try container.decode(Double.self, forKey: .duration)
    isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
    isHidden = try container.decode(Bool.self, forKey: .isHidden)
    isCloudOnly = try container.decode(Bool.self, forKey: .isCloudOnly)
    locationLatitude = try container.decodeIfPresent(Double.self, forKey: .locationLatitude)
    locationLongitude = try container.decodeIfPresent(Double.self, forKey: .locationLongitude)
    locationAltitude = try container.decodeIfPresent(Double.self, forKey: .locationAltitude)
    originalBytes = try container.decodeIfPresent(Int64.self, forKey: .originalBytes)
    estimatedOutputBytes = try container.decodeIfPresent(Int64.self, forKey: .estimatedOutputBytes)
    codec = try container.decodeIfPresent(String.self, forKey: .codec)
    albumIdentifiers = try container.decode([String].self, forKey: .albumIdentifiers)
    exclusionReasons = try container.decode(Set<ExclusionReason>.self, forKey: .exclusionReasons)
    isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
  }
}

enum MediaDimensionMatcher {
  static func matches(
    outputWidth: Int,
    outputHeight: Int,
    sourceWidth: Int,
    sourceHeight: Int,
    tolerance: Int = 1
  ) -> Bool {
    guard outputWidth > 0, outputHeight > 0, sourceWidth > 0, sourceHeight > 0 else {
      return false
    }
    let allowed = max(0, tolerance)
    let directMatch =
      abs(outputWidth - sourceWidth) <= allowed
      && abs(outputHeight - sourceHeight) <= allowed
    let rotatedMatch =
      abs(outputWidth - sourceHeight) <= allowed
      && abs(outputHeight - sourceWidth) <= allowed
    return directMatch || rotatedMatch
  }
}

enum MediaPlanning {
  static func estimatedOutputBytes(
    inputBytes: Int64,
    kind: MediaKind,
    settings: CompressionSettings,
    duration: Double = 0
  ) -> Int64 {
    switch kind {
    case .photo:
      let ratio = max(0.28, min(0.92, settings.photoQuality * 0.68))
      return max(1, Int64(Double(max(1, inputBytes)) * ratio))
    case .video:
      if settings.videoBitrateMode == .manual {
        let seconds = max(1, duration)
        let videoBits = Double(max(32, settings.videoTargetBitrateKbps) * 1_000) * seconds
        let audioRate =
          settings.audioPolicy == .aac
          ? Double(max(32_000, settings.aacBitrate))
          : 128_000
        let mediaBytes = (videoBits + audioRate * seconds) / 8
        // Include a small container/keyframe allowance; this is a planning
        // estimate, not a promise about the final MOV size.
        return max(1, Int64(mediaBytes * 1.05))
      }
      let ratio = max(0.25, min(0.90, settings.videoBitrateRatio))
      return max(1, Int64(Double(max(1, inputBytes)) * ratio))
    }
  }

}
