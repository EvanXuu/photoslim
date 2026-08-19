import Foundation

struct LocalStorageReport: Equatable, Sendable {
  let totalBytes: Int64
  let immediatelyAvailableBytes: Int64
  let availableBytes: Int64

  var usedBytes: Int64 { max(0, totalBytes - immediatelyAvailableBytes) }
  var reclaimableBytes: Int64 { max(0, availableBytes - immediatelyAvailableBytes) }
  var usedRatio: Double {
    guard totalBytes > 0 else { return 0 }
    return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
  }
}

struct DiskSpaceReport: Equatable, Sendable {
  let knownLocalInputBytes: Int64
  /// Exact cloud bytes are populated only after PhotoKit has downloaded and
  /// exposed the original resource. Unknown cloud assets are never estimated.
  let knownCloudDownloadBytes: Int64
  let unknownCloudAssetCount: Int
  /// Headroom for temporary downloads, encode output, and container overhead.
  /// This is a storage safety margin, not a predicted output or savings value.
  let safetyMarginBytes: Int64
  let availableBytes: Int64

  var requiredBytes: Int64 {
    let (transient, transientOverflow) = knownLocalInputBytes.addingReportingOverflow(
      max(0, knownCloudDownloadBytes)
    )
    if transientOverflow { return Int64.max }
    let (required, requiredOverflow) = transient.addingReportingOverflow(max(0, safetyMarginBytes))
    return requiredOverflow ? Int64.max : required
  }

  var hasEnoughSpace: Bool { availableBytes >= requiredBytes }
  var hasUnknownCloudSizes: Bool { unknownCloudAssetCount > 0 }
}

struct SelectionCapacityPlan: Equatable, Sendable {
  let accepted: [MediaAsset]
  let rejected: [MediaAsset]
  let report: DiskSpaceReport
}

enum DiskCapacityService {
  static func localStorage(at volumeURL: URL) throws -> LocalStorageReport {
    let values = try volumeURL.resourceValues(forKeys: [
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
      .volumeAvailableCapacityKey,
    ])
    let total = Int64(values.volumeTotalCapacity ?? 0)
    let immediate = Int64(values.volumeAvailableCapacity ?? 0)
    let important = max(
      immediate,
      values.volumeAvailableCapacityForImportantUsage ?? immediate
    )
    return LocalStorageReport(
      totalBytes: max(0, total),
      immediatelyAvailableBytes: max(0, immediate),
      availableBytes: max(0, important)
    )
  }

  static func report(for assets: [MediaAsset], at volumeURL: URL) throws -> DiskSpaceReport {
    let storage = try localStorage(at: volumeURL)
    return report(for: assets, availableBytes: storage.availableBytes)
  }

  static func report(for assets: [MediaAsset], availableBytes: Int64) -> DiskSpaceReport {
    let assets = uniqueAssets(assets)
    let knownLocal =
      assets
      .filter { !$0.isCloudOnly }
      .compactMap(\.originalBytes)
      .reduce(0, +)
    let cloud = assets
      .filter { $0.isCloudOnly }
      .compactMap(\.originalBytes)
      .reduce(0, saturatedAdd)
    let unknownCloudCount = assets.filter { $0.isCloudOnly && $0.originalBytes == nil }.count
    let transient = saturatedAdd(knownLocal, cloud)
    let safety = safetyMargin(for: transient)
    return DiskSpaceReport(
      knownLocalInputBytes: knownLocal,
      knownCloudDownloadBytes: cloud,
      unknownCloudAssetCount: unknownCloudCount,
      safetyMarginBytes: safety,
      availableBytes: availableBytes
    )
  }

  static func selectionPlan(
    for orderedAssets: [MediaAsset],
    availableBytes: Int64
  ) -> SelectionCapacityPlan {
    var seen: Set<String> = []
    var accepted: [MediaAsset] = []
    var rejected: [MediaAsset] = []
    var knownLocal: Int64 = 0
    var cloud: Int64 = 0
    var unknownCloudCount = 0
    for asset in orderedAssets where seen.insert(asset.id).inserted {
      let nextKnown =
        asset.isCloudOnly
        ? knownLocal
        : saturatedAdd(knownLocal, asset.originalBytes ?? 0)
      let nextCloud = asset.isCloudOnly
        ? saturatedAdd(cloud, asset.originalBytes ?? 0)
        : cloud
      let nextUnknownCloudCount = asset.isCloudOnly && asset.originalBytes == nil
        ? unknownCloudCount + 1
        : unknownCloudCount
      let transient = saturatedAdd(nextKnown, nextCloud)
      let required = saturatedAdd(transient, safetyMargin(for: transient))

      if required <= max(0, availableBytes) {
        accepted.append(asset)
        knownLocal = nextKnown
        cloud = nextCloud
        unknownCloudCount = nextUnknownCloudCount
      } else {
        rejected.append(asset)
      }
    }

    let transient = saturatedAdd(knownLocal, cloud)
    let report = DiskSpaceReport(
      knownLocalInputBytes: knownLocal,
      knownCloudDownloadBytes: cloud,
      unknownCloudAssetCount: unknownCloudCount,
      safetyMarginBytes: safetyMargin(for: transient),
      availableBytes: max(0, availableBytes)
    )
    return SelectionCapacityPlan(accepted: accepted, rejected: rejected, report: report)
  }

  private static func uniqueAssets(_ assets: [MediaAsset]) -> [MediaAsset] {
    var seen: Set<String> = []
    return assets.filter { seen.insert($0.id).inserted }
  }

  private static func safetyMargin(for transientBytes: Int64) -> Int64 {
    guard transientBytes > 0 else { return 0 }
    return max(2_000_000_000, Int64(Double(transientBytes) * 0.15))
  }

  private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let rhs = max(0, rhs)
    guard lhs <= Int64.max - rhs else { return Int64.max }
    return lhs + rhs
  }
}
