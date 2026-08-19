import Foundation

enum AudioPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
  case passthroughWhenPossible
  case aac

  var id: String { rawValue }
  var title: String { self == .passthroughWhenPossible ? "优先保持原音频" : "转换为 AAC" }
}

enum VideoEncodingMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case manual

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic: return "自动"
    case .manual: return "手动"
    }
  }
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

enum VideoResolutionTier: String, Codable, CaseIterable, Identifiable, Sendable {
  case p1080
  case p2160
  case p4320

  var id: String { rawValue }

  var title: String {
    switch self {
    case .p1080: return "1080p"
    case .p2160: return "2160p"
    case .p4320: return "4320p"
    }
  }

  var canonicalDimensions: (width: Int, height: Int) {
    switch self {
    case .p1080: return (1_920, 1_080)
    case .p2160: return (3_840, 2_160)
    case .p4320: return (7_680, 4_320)
    }
  }
}

enum VideoFrameRateTier: String, Codable, CaseIterable, Identifiable, Sendable {
  case fps30
  case fps60

  var id: String { rawValue }
  var title: String { self == .fps30 ? "30 fps" : "60 fps" }
  var value: Double { self == .fps30 ? 30 : 60 }
}

/// Editable bitrate recommendations for manual HEVC encoding.
///
/// Values are video-only megabits per second. The standard rows are intentionally
/// stored as user-editable data; non-standard dimensions use the same anchors
/// without inventing a second hidden preset.
struct ManualVideoBitrateTable: Codable, Equatable, Sendable {
  var p1080p30Mbps = 6.0
  var p1080p60Mbps = 12.0
  var p2160p30Mbps = 20.0
  var p2160p60Mbps = 40.0
  var p4320p30Mbps = 80.0
  var p4320p60Mbps = 160.0

  static let recommended = ManualVideoBitrateTable()

  func value(for resolution: VideoResolutionTier, frameRate: VideoFrameRateTier) -> Double {
    switch (resolution, frameRate) {
    case (.p1080, .fps30): return p1080p30Mbps
    case (.p1080, .fps60): return p1080p60Mbps
    case (.p2160, .fps30): return p2160p30Mbps
    case (.p2160, .fps60): return p2160p60Mbps
    case (.p4320, .fps30): return p4320p30Mbps
    case (.p4320, .fps60): return p4320p60Mbps
    }
  }

  mutating func setValue(
    _ value: Double,
    for resolution: VideoResolutionTier,
    frameRate: VideoFrameRateTier
  ) {
    let sanitized = Self.sanitizeMegabitsPerSecond(value)
    switch (resolution, frameRate) {
    case (.p1080, .fps30): p1080p30Mbps = sanitized
    case (.p1080, .fps60): p1080p60Mbps = sanitized
    case (.p2160, .fps30): p2160p30Mbps = sanitized
    case (.p2160, .fps60): p2160p60Mbps = sanitized
    case (.p4320, .fps30): p4320p30Mbps = sanitized
    case (.p4320, .fps60): p4320p60Mbps = sanitized
    }
  }

  /// Returns the 30 fps recommendation for the exact pixel count.
  /// Standard anchors are 1080p = 6 Mbps, 2160p = 20 Mbps, and 4320p = 80 Mbps.
  func recommendedBaseMbps(width: Int, height: Int) -> Double {
    let pixels = Double(max(1, width) * max(1, height))
    let p1080 = Double(1_920 * 1_080)
    let p2160 = Double(3_840 * 2_160)
    let p4320 = Double(7_680 * 4_320)
    let b1080 = max(0.032, p1080p30Mbps)
    let b2160 = max(0.032, p2160p30Mbps)
    let b4320 = max(0.032, p4320p30Mbps)

    if pixels <= p1080 {
      return max(0.032, b1080 * pixels / p1080)
    }
    if pixels <= p2160 {
      let t = log(pixels / p1080) / log(p2160 / p1080)
      return max(0.032, b1080 * pow(b2160 / b1080, t))
    }
    if pixels <= p4320 {
      let t = log(pixels / p2160) / log(p4320 / p2160)
      return max(0.032, b2160 * pow(b4320 / b2160, t))
    }
    return max(0.032, b4320 * pixels / p4320)
  }

  /// Returns the video target in kbps. A standard row is selected when both
  /// dimensions are within one pixel of a canonical 16:9 size, including a
  /// rotated orientation. Otherwise the exact pixel-count recommendation is
  /// scaled by frame rate relative to 30 fps.
  func bitrateKbps(width: Int, height: Int, frameRate: Double) -> Int {
    let resolution = Self.standardResolution(width: width, height: height)
    let frames = frameRate >= 45 ? VideoFrameRateTier.fps60 : .fps30
    let megabits: Double
    if let resolution {
      megabits = value(for: resolution, frameRate: frames)
    } else {
      let baseKbps = max(32, Int((recommendedBaseMbps(width: width, height: height) * 1_000).rounded()))
      return max(32, Int((Double(baseKbps) * max(1.0, frameRate) / 30.0).rounded()))
    }
    return max(32, Int((megabits * 1_000).rounded()))
  }

  private static func standardResolution(width: Int, height: Int) -> VideoResolutionTier? {
    VideoResolutionTier.allCases.first { tier in
      let dimensions = tier.canonicalDimensions
      return MediaDimensionMatcher.matches(
        outputWidth: width,
        outputHeight: height,
        sourceWidth: dimensions.width,
        sourceHeight: dimensions.height,
        tolerance: 1
      )
    }
  }

  private static func sanitizeMegabitsPerSecond(_ value: Double) -> Double {
    guard value.isFinite else { return 0.032 }
    return min(1_000, max(0.032, value))
  }
}

struct CompressionSettings: Codable, Equatable, Sendable {
  var photoQuality = 0.82
  var videoEncodingMode: VideoEncodingMode = .automatic
  var manualVideoBitrates: ManualVideoBitrateTable = .recommended
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
  var minimumSavingsRatio = 0.08

  init() {}

  static let recommended = CompressionSettings()

  func summary(for mediaKind: MediaKind? = nil) -> String {
    if mediaKind == .photo {
      return "HEIC \(Int(photoQuality * 100))%"
    }

    let videoSummary: String
    switch videoEncodingMode {
    case .automatic:
      videoSummary = "自动"
    case .manual:
      videoSummary = "手动"
    }
    if mediaKind == .video {
      return videoSummary
    }
    return "照片 \(Int(photoQuality * 100))% · 视频 \(videoSummary)"
  }

  var summary: String { summary(for: nil) }

  private enum CodingKeys: String, CodingKey {
    case photoQuality
    case videoEncodingMode
    case manualVideoBitrates
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
    videoEncodingMode =
      try container.decodeIfPresent(VideoEncodingMode.self, forKey: .videoEncodingMode)
      ?? .automatic
    manualVideoBitrates =
      try container.decodeIfPresent(ManualVideoBitrateTable.self, forKey: .manualVideoBitrates)
      ?? .recommended
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
      try container.decodeIfPresent(Double.self, forKey: .minimumSavingsRatio) ?? 0.08
  }
}
