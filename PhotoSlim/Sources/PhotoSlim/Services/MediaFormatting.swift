import Foundation

enum MediaFormatting {
  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter
  }()

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  static func bytes(_ value: Int64?) -> String {
    guard let value else { return "待检查" }
    return byteFormatter.string(fromByteCount: value)
  }

  static func date(_ value: Date?) -> String {
    guard let value else { return "日期未知" }
    return dateFormatter.string(from: value)
  }

  static func duration(_ value: Double) -> String {
    guard value > 0 else { return "" }
    let seconds = Int(value.rounded())
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainder = seconds % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
      : String(format: "%d:%02d", minutes, remainder)
  }

  static func percentage(_ value: Double?) -> String {
    guard let value else { return "下载后计算" }
    return "\(Int((value * 100).rounded()))%"
  }

  static func inputBytes(for asset: MediaAsset) -> String? {
    guard let originalBytes = asset.originalBytes, originalBytes > 0 else { return nil }
    return bytes(originalBytes)
  }
}
