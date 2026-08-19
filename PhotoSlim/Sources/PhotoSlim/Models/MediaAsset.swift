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

/// Availability of the original PhotoKit resource on the current Mac.
///
/// `isCloudOnly` is kept on `MediaAsset` for compatibility with older session
/// ledgers. This value carries the extra distinction needed by the scanner:
/// an asset can be known to require an iCloud download, or PhotoKit can fail to
/// answer without telling us why.
enum OriginalResourceAvailability: String, Codable, CaseIterable, Identifiable, Sendable {
  case local
  case needsDownload
  case unknown

  var id: String { rawValue }

  var title: String {
    switch self {
    case .local: return "本地可用"
    case .needsDownload: return "需要 iCloud 下载"
    case .unknown: return "状态未知"
    }
  }

  var symbolName: String {
    switch self {
    case .local: return "externaldrive.fill"
    case .needsDownload: return "icloud.and.arrow.down"
    case .unknown: return "questionmark.icloud"
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
    case .efficientCodec: return "已经是高效格式"
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
    case .lowSavings: return "旧版节省标记"
    case .codecUnverified: return "格式待确认"
    case .unsupported: return "暂不支持"
    }
  }

  var warning: String {
    switch self {
    case .alreadyProcessed:
      return "这个项目已经出现在已确认完成的 PhotoSlim 任务中。为避免重复有损压缩，它只能查看，不能再次加入任务。"
    case .efficientCodec:
      return "这些项目已经使用较新的格式，再压缩通常收益很小，还可能降低画质。"
    case .edited:
      return "已编辑的项目可能无法完整保留调整内容，暂不处理。"
    case .raw:
      return "RAW 和 ProRAW 是数字底片。首版不会压缩或替换它们。"
    case .livePhoto:
      return "Live Photo 包含配对照片和视频。首版不会拆分或替换它们。"
    case .hdr:
      return "HDR 或 Dolby Vision 的颜色信息可能无法完整保留，暂不处理。"
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
      return "这是旧记录中的项目，当前不会用它限制处理。"
    case .codecUnverified:
      return "项目尚未下载到本机，格式需要下载后才能确认。"
    case .unsupported:
      return "暂时无法安全处理这个项目。"
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

  static let defaultExcluded = Set(Self.allCases).subtracting([.codecUnverified, .lowSavings])
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
  var originalAvailability: OriginalResourceAvailability = .local
  var locationLatitude: Double? = nil
  var locationLongitude: Double? = nil
  var locationAltitude: Double? = nil
  var originalBytes: Int64?
  var codec: String?
  var albumIdentifiers: [String]
  var exclusionReasons: Set<ExclusionReason>
  /// A browser-only preference persisted with the library index. Pinning never
  /// changes processing eligibility or the PhotoKit asset itself.
  var isPinned: Bool = false

  var inputBytesForPlanning: Int64 {
    // PhotoKit does not expose a reliable remote-original byte count before
    // the resource is downloaded. Zero is intentional: callers must render
    // the value as unknown instead of inventing a size estimate.
    originalBytes ?? 0
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
    case originalAvailability
    case locationLatitude
    case locationLongitude
    case locationAltitude
    case originalBytes
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
    originalAvailability = try container.decodeIfPresent(
      OriginalResourceAvailability.self,
      forKey: .originalAvailability
    ) ?? (isCloudOnly ? .needsDownload : .local)
    locationLatitude = try container.decodeIfPresent(Double.self, forKey: .locationLatitude)
    locationLongitude = try container.decodeIfPresent(Double.self, forKey: .locationLongitude)
    locationAltitude = try container.decodeIfPresent(Double.self, forKey: .locationAltitude)
    originalBytes = try container.decodeIfPresent(Int64.self, forKey: .originalBytes)
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
