import Foundation

enum TimeFilter: String, Codable, CaseIterable, Identifiable, Sendable {
  case all
  case recentYear
  case recentThreeYears
  case olderThanFiveYears
  case customOlderThan
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "全部时间"
    case .recentYear: return "1 年以上"
    case .recentThreeYears: return "3 年以上"
    case .olderThanFiveYears: return "5 年以上"
    case .customOlderThan: return "自定义年数以上"
    case .custom: return "手动日期范围"
    }
  }
}

enum SizeFilter: String, Codable, CaseIterable, Identifiable, Sendable {
  case all
  case under10MB
  case tenToHundredMB
  case hundredMBToOneGB
  case overOneGB
  case customMinimum
  case custom

  static let pickerCases: [SizeFilter] = [
    .all,
    .under10MB,
    .tenToHundredMB,
    .overOneGB,
    .customMinimum,
    .custom,
  ]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: return "全部大小"
    case .under10MB: return "10 MB 以上"
    case .tenToHundredMB: return "100 MB 以上"
    case .hundredMBToOneGB: return "100 MB–1 GB"
    case .overOneGB: return "1 GB 以上"
    case .customMinimum: return "自定义大小以上"
    case .custom: return "手动大小范围"
    }
  }
}

enum CloudFilter: String, Codable, CaseIterable, Identifiable, Sendable {
  case all
  case local
  case cloud

  var id: String { rawValue }
  var title: String {
    switch self {
    case .all: return "本地与 iCloud"
    case .local: return "本地可用"
    case .cloud: return "需要 iCloud"
    }
  }
}

enum SortOption: String, Codable, CaseIterable, Identifiable, Sendable {
  case savingsLargest
  case savingsPercent
  case sizeLargest
  case dateNewest
  case dateOldest
  case durationLongest
  case filename

  var id: String { rawValue }

  var title: String {
    switch self {
    case .savingsLargest: return "预计节省空间"
    case .savingsPercent: return "预计节省比例"
    case .sizeLargest: return "原文件大小"
    case .dateNewest: return "拍摄日期（新到旧）"
    case .dateOldest: return "拍摄日期（旧到新）"
    case .durationLongest: return "时长"
    case .filename: return "文件名"
    }
  }
}

enum BrowserLayoutMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case grid
  case list
  var id: String { rawValue }
}

struct BrowserFilter: Codable, Equatable, Sendable {
  var searchText = ""
  var mediaKind: MediaKind?
  var favoritesOnly = false
  var timeFilter: TimeFilter = .all
  var customMinimumAgeYears: Int?
  var customStartDate: Date?
  var customEndDate: Date?
  var sizeFilter: SizeFilter = .all
  var customMinimumBytes: Int64?
  var customMaximumBytes: Int64?
  var cloudFilter: CloudFilter = .all
  var excludedReasons = ExclusionReason.defaultExcluded
  var sortOption: SortOption = .savingsLargest
  var layoutMode: BrowserLayoutMode = .grid
}

enum MediaQueryEngine {
  static func apply(_ filter: BrowserFilter, to assets: [MediaAsset], now: Date = Date())
    -> [MediaAsset]
  {
    let calendar = Calendar(identifier: .gregorian)
    let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now
    let threeYearsAgo = calendar.date(byAdding: .year, value: -3, to: now) ?? now
    let fiveYearsAgo = calendar.date(byAdding: .year, value: -5, to: now) ?? now

    let filtered = assets.filter { asset in
      if let kind = filter.mediaKind, asset.kind != kind { return false }
      if filter.favoritesOnly && !asset.isFavorite { return false }
      if !filter.searchText.isEmpty
        && !asset.filename.localizedCaseInsensitiveContains(filter.searchText)
      {
        return false
      }
      if !asset.exclusionReasons.isDisjoint(with: filter.excludedReasons) { return false }

      switch filter.cloudFilter {
      case .all: break
      case .local where asset.isCloudOnly: return false
      case .cloud where !asset.isCloudOnly: return false
      default: break
      }

      if let date = asset.creationDate {
        switch filter.timeFilter {
        case .all: break
        case .recentYear where date > oneYearAgo: return false
        case .recentThreeYears where date > threeYearsAgo: return false
        case .olderThanFiveYears where date > fiveYearsAgo: return false
        case .customOlderThan:
          let years = max(1, filter.customMinimumAgeYears ?? 10)
          let threshold = calendar.date(byAdding: .year, value: -years, to: now) ?? now
          if date > threshold { return false }
        case .custom:
          if let start = filter.customStartDate, date < start { return false }
          if let end = filter.customEndDate, date > end { return false }
        default: break
        }
      } else if filter.timeFilter != .all {
        return false
      }

      if filter.sizeFilter != .all {
        // A size predicate is only meaningful when PhotoKit has exposed the
        // actual resource size. Cloud-only items stay out of explicit size
        // filters until the task downloads them and measures them.
        guard let bytes = asset.originalBytes else { return false }
        let mb: Int64 = 1_000_000
        let gb: Int64 = 1_000_000_000
        switch filter.sizeFilter {
        case .under10MB where bytes < 10 * mb: return false
        case .tenToHundredMB where bytes < 100 * mb: return false
        case .hundredMBToOneGB where bytes < 100 * mb || bytes >= gb: return false
        case .overOneGB where bytes < gb: return false
        case .customMinimum:
          let minimum = max(0, filter.customMinimumBytes ?? 0)
          if bytes < minimum { return false }
        case .custom:
          if let minimum = filter.customMinimumBytes, bytes < minimum { return false }
          if let maximum = filter.customMaximumBytes, bytes > maximum { return false }
        default: break
        }
      }

      return true
    }

    return filtered.sorted { lhs, rhs in
      // Pinning is a stable first-level ordering, while the selected sort
      // option controls the remainder of the list.
      if lhs.isPinned != rhs.isPinned { return lhs.isPinned }

      switch filter.sortOption {
      case .savingsLargest:
        let left = lhs.estimatedSavingsBytes ?? -1
        let right = rhs.estimatedSavingsBytes ?? -1
        if left != right { return left > right }
      case .savingsPercent:
        let left = lhs.estimatedSavingsRatio ?? -1
        let right = rhs.estimatedSavingsRatio ?? -1
        if left != right { return left > right }
      case .sizeLargest:
        let left = lhs.originalBytes ?? -1
        let right = rhs.originalBytes ?? -1
        if left != right { return left > right }
      case .dateNewest:
        let left = lhs.creationDate ?? .distantPast
        let right = rhs.creationDate ?? .distantPast
        if left != right { return left > right }
      case .dateOldest:
        let left = lhs.creationDate ?? .distantFuture
        let right = rhs.creationDate ?? .distantFuture
        if left != right { return left < right }
      case .durationLongest:
        if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
      case .filename:
        let order = lhs.filename.localizedStandardCompare(rhs.filename)
        if order != .orderedSame { return order == .orderedAscending }
      }
      return lhs.id < rhs.id
    }
  }
}
