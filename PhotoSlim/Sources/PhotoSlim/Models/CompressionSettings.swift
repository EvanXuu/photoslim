import Foundation

enum AudioPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
  case passthroughWhenPossible
  case aac

  var id: String { rawValue }
  var title: String { self == .passthroughWhenPossible ? "优先保持原音频" : "转换为 AAC" }
}

enum VideoBitrateMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case sourceRatio
  case manual

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sourceRatio: return "按原件比例"
    case .manual: return "固定平均码率"
    }
  }
}

struct CompressionSettings: Codable, Equatable, Sendable {
  var photoQuality = 0.82
  /// Source-relative mode keeps the existing recommended workflow. Manual mode
  /// uses `videoTargetBitrateKbps` as the video-only average bitrate.
  var videoBitrateMode: VideoBitrateMode = .sourceRatio
  var videoBitrateRatio = 0.60
  var videoTargetBitrateKbps = 2_000
  /// Zero means that no additional VideoToolbox hard cap is requested.
  var videoMaxBitrateKbps = 0
  var videoKeyframeIntervalSeconds = 2.0
  var videoAllowFrameReordering = true
  var preserveDimensions = true
  var preserveFrameRate = true
  var audioPolicy: AudioPolicy = .passthroughWhenPossible
  var aacBitrate = 192_000
  var minimumSavingsRatio = 0.10

  init() {}

  static let recommended = CompressionSettings()

  var summary: String {
    let videoSummary: String
    switch videoBitrateMode {
    case .sourceRatio:
      videoSummary = "源码率 \(Int(videoBitrateRatio * 100))%"
    case .manual:
      videoSummary = "\(videoTargetBitrateKbps) kbps"
    }
    return "照片质量 \(Int(photoQuality * 100)) · 视频 \(videoSummary) · HEVC 手动参数"
  }

  private enum CodingKeys: String, CodingKey {
    case photoQuality
    case videoBitrateMode
    case videoBitrateRatio
    case videoTargetBitrateKbps
    case videoMaxBitrateKbps
    case videoKeyframeIntervalSeconds
    case videoAllowFrameReordering
    case preserveDimensions
    case preserveFrameRate
    case audioPolicy
    case aacBitrate
    case minimumSavingsRatio
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    photoQuality = try container.decodeIfPresent(Double.self, forKey: .photoQuality) ?? 0.82
    videoBitrateMode =
      try container.decodeIfPresent(VideoBitrateMode.self, forKey: .videoBitrateMode)
      ?? .sourceRatio
    videoBitrateRatio =
      try container.decodeIfPresent(Double.self, forKey: .videoBitrateRatio) ?? 0.60
    videoTargetBitrateKbps =
      try container.decodeIfPresent(Int.self, forKey: .videoTargetBitrateKbps) ?? 2_000
    videoMaxBitrateKbps =
      try container.decodeIfPresent(Int.self, forKey: .videoMaxBitrateKbps) ?? 0
    videoKeyframeIntervalSeconds =
      try container.decodeIfPresent(Double.self, forKey: .videoKeyframeIntervalSeconds) ?? 2.0
    videoAllowFrameReordering =
      try container.decodeIfPresent(Bool.self, forKey: .videoAllowFrameReordering) ?? true
    preserveDimensions =
      try container.decodeIfPresent(Bool.self, forKey: .preserveDimensions) ?? true
    preserveFrameRate =
      try container.decodeIfPresent(Bool.self, forKey: .preserveFrameRate) ?? true
    audioPolicy =
      try container.decodeIfPresent(AudioPolicy.self, forKey: .audioPolicy)
      ?? .passthroughWhenPossible
    aacBitrate = try container.decodeIfPresent(Int.self, forKey: .aacBitrate) ?? 192_000
    minimumSavingsRatio =
      try container.decodeIfPresent(Double.self, forKey: .minimumSavingsRatio) ?? 0.10
  }
}
