import Foundation
import CoreMedia
import XCTest

@testable import PhotoSlim

final class PhotoSlimCoreTests: XCTestCase {
  func testDefaultFilterHidesExcludedAssetsAndSortsBySavings() {
    let small = fixture(
      id: "small",
      date: Date(timeIntervalSince1970: 1_600_000_000),
      bytes: 100_000_000,
      output: 60_000_000
    )
    let large = fixture(
      id: "large",
      date: Date(timeIntervalSince1970: 1_500_000_000),
      bytes: 500_000_000,
      output: 200_000_000
    )
    var efficient = fixture(
      id: "efficient",
      date: Date(timeIntervalSince1970: 1_700_000_000),
      bytes: 900_000_000,
      output: 400_000_000
    )
    efficient.format = .heic
    efficient.exclusionReasons = [.efficientCodec]

    let result = MediaQueryEngine.apply(BrowserFilter(), to: [small, efficient, large])
    XCTAssertEqual(result.map(\.id), ["large", "small"])
  }

  func testPinnedAssetsAlwaysAppearBeforeTheSelectedSortOrder() {
    var pinnedSmall = fixture(id: "pinned-small", bytes: 100_000_000, output: 90_000_000)
    pinnedSmall.isPinned = true
    let large = fixture(id: "large-unpinned", bytes: 500_000_000, output: 200_000_000)

    let result = MediaQueryEngine.apply(BrowserFilter(), to: [large, pinnedSmall])
    XCTAssertEqual(result.map(\.id), ["pinned-small", "large-unpinned"])
  }

  func testProcessedLedgerHardBlocksAndDefaultFilterHidesAsset() {
    var processed = fixture(id: "processed")
    processed.refreshPlanning(
      settings: .recommended,
      processedIdentifiers: ["processed"]
    )

    XCTAssertTrue(processed.exclusionReasons.contains(.alreadyProcessed))
    XCTAssertFalse(processed.canProcess)
    XCTAssertTrue(MediaQueryEngine.apply(BrowserFilter(), to: [processed]).isEmpty)

    var visibleFilter = BrowserFilter()
    visibleFilter.excludedReasons.remove(.alreadyProcessed)
    XCTAssertEqual(MediaQueryEngine.apply(visibleFilter, to: [processed]).map(\.id), ["processed"])
    XCTAssertFalse(processed.canProcess)
  }

  func testLibraryIndexDiffOnlyReturnsNewChangedAndDeletedIdentifiers() {
    var unchanged = fixture(id: "unchanged")
    unchanged.modificationTimestamp = 10
    var changed = fixture(id: "changed")
    changed.modificationTimestamp = 20
    var deleted = fixture(id: "deleted")
    deleted.modificationTimestamp = nil

    let diff = LibraryIndexDiff.compare(
      cached: [unchanged, changed, deleted],
      current: [
        LibraryAssetSnapshot(identifier: "unchanged", modificationTimestamp: 10),
        LibraryAssetSnapshot(identifier: "changed", modificationTimestamp: 21),
        LibraryAssetSnapshot(identifier: "inserted", modificationTimestamp: nil),
      ]
    )

    XCTAssertEqual(diff.changedIdentifiers, ["changed", "inserted"])
    XCTAssertEqual(diff.deletedIdentifiers, ["deleted"])
  }

  func testTimeSizeAndCloudFiltersCompose() {
    let now = Date(timeIntervalSince1970: 1_786_000_000)
    var localOld = fixture(
      id: "local-old",
      date: Calendar(identifier: .gregorian).date(byAdding: .year, value: -7, to: now)!,
      bytes: 300_000_000,
      output: 120_000_000
    )
    localOld.isCloudOnly = false
    var cloudOld = localOld
    cloudOld = fixture(
      id: "cloud-old",
      date: localOld.creationDate!,
      bytes: 450_000_000,
      output: 180_000_000
    )
    cloudOld.isCloudOnly = true
    let recent = fixture(
      id: "recent",
      date: now,
      bytes: 450_000_000,
      output: 180_000_000
    )

    var filter = BrowserFilter()
    filter.timeFilter = .olderThanFiveYears
    filter.sizeFilter = .tenToHundredMB
    filter.cloudFilter = .local
    let result = MediaQueryEngine.apply(filter, to: [recent, cloudOld, localOld], now: now)
    XCTAssertEqual(result.map(\.id), ["local-old"])
  }

  func testAgeAndSizePresetsUseMinimumThresholds() {
    let now = Date(timeIntervalSince1970: 1_786_000_000)
    let oldLarge = fixture(
      id: "old-large",
      date: Calendar(identifier: .gregorian).date(byAdding: .year, value: -4, to: now)!,
      bytes: 150_000_000
    )
    let recentLarge = fixture(
      id: "recent-large",
      date: Calendar(identifier: .gregorian).date(byAdding: .year, value: -2, to: now)!,
      bytes: 150_000_000
    )
    let oldSmall = fixture(
      id: "old-small",
      date: Calendar(identifier: .gregorian).date(byAdding: .year, value: -4, to: now)!,
      bytes: 80_000_000
    )

    var filter = BrowserFilter()
    filter.timeFilter = .recentThreeYears
    filter.sizeFilter = .tenToHundredMB

    let result = MediaQueryEngine.apply(
      filter,
      to: [recentLarge, oldSmall, oldLarge],
      now: now
    )
    XCTAssertEqual(result.map(\.id), ["old-large"])
  }

  func testCustomMinimumsAndManualRangesRemainDistinct() {
    let now = Date(timeIntervalSince1970: 1_786_000_000)
    let calendar = Calendar(identifier: .gregorian)
    let eightYearsOld = calendar.date(byAdding: .year, value: -8, to: now)!
    let nineYearsOld = calendar.date(byAdding: .year, value: -9, to: now)!
    let customMatch = fixture(id: "custom-match", date: nineYearsOld, bytes: 350_000_000)
    let tooRecent = fixture(id: "too-recent", date: eightYearsOld, bytes: 350_000_000)
    let tooSmall = fixture(id: "too-small", date: nineYearsOld, bytes: 250_000_000)

    var filter = BrowserFilter()
    filter.timeFilter = .customOlderThan
    filter.customMinimumAgeYears = 9
    filter.sizeFilter = .customMinimum
    filter.customMinimumBytes = 300_000_000
    XCTAssertEqual(
      MediaQueryEngine.apply(filter, to: [tooRecent, tooSmall, customMatch], now: now).map(\.id),
      ["custom-match"]
    )

    filter.timeFilter = .custom
    filter.customStartDate = calendar.date(byAdding: .month, value: -1, to: nineYearsOld)
    filter.customEndDate = calendar.date(byAdding: .month, value: 1, to: nineYearsOld)
    filter.sizeFilter = .custom
    filter.customMinimumBytes = 300_000_000
    filter.customMaximumBytes = 400_000_000
    XCTAssertEqual(
      MediaQueryEngine.apply(filter, to: [tooRecent, tooSmall, customMatch], now: now).map(\.id),
      ["custom-match"]
    )
  }

  func testCloudDiskPreflightDoesNotInventRemoteSize() {
    var cloud = fixture(
      id: "cloud",
      kind: .video,
      format: .h264,
      bytes: nil,
      output: nil
    )
    cloud.isCloudOnly = true
    cloud.pixelWidth = 3_840
    cloud.pixelHeight = 2_160
    cloud.duration = 60

    let report = DiskCapacityService.report(for: [cloud], availableBytes: 50_000_000_000)
    XCTAssertEqual(report.knownCloudDownloadBytes, 0)
    XCTAssertEqual(report.knownOutputBytes, 0)
    XCTAssertEqual(report.safetyMarginBytes, 0)
    XCTAssertTrue(report.hasEnoughSpace)
    XCTAssertTrue(report.hasUnknownCloudSizes)
  }

  func testCloudVideoWithUnknownCodecCanBeQueuedWithoutEstimatedSavings() {
    var cloud = fixture(
      id: "remote-video",
      kind: .video,
      format: .unknown,
      bytes: nil,
      output: nil
    )
    cloud.isCloudOnly = true
    cloud.pixelWidth = 3_840
    cloud.pixelHeight = 2_160
    cloud.duration = 90
    cloud.exclusionReasons.insert(.codecUnverified)

    XCTAssertTrue(cloud.canProcess)
    XCTAssertNil(cloud.estimatedSavingsBytes)

    var filter = BrowserFilter()
    filter.sizeFilter = .tenToHundredMB
    let result = MediaQueryEngine.apply(filter, to: [cloud])
    XCTAssertTrue(result.isEmpty)
  }

  func testDefaultFilterShowsCloudVideosAwaitingCodecVerification() {
    var cloud = fixture(id: "cloud-video", kind: .video)
    cloud.format = .unknown
    cloud.isCloudOnly = true
    cloud.exclusionReasons = [.codecUnverified]

    XCTAssertFalse(BrowserFilter().excludedReasons.contains(.codecUnverified))
    XCTAssertEqual(MediaQueryEngine.apply(BrowserFilter(), to: [cloud]).map(\.id), ["cloud-video"])
  }

  func testVideoCodecClassifierRecognizesHEVCVariantsAndMixedDescriptions() {
    XCTAssertEqual(
      VideoCodecClassifier.displayName(for: [kCMVideoCodecType_HEVC]),
      "HEVC (hvc1)"
    )
    XCTAssertEqual(
      VideoCodecClassifier.displayName(for: [VideoCodecClassifier.fourCC("hev1")]),
      "HEVC"
    )
    XCTAssertEqual(
      VideoCodecClassifier.displayName(for: [
        kCMVideoCodecType_H264,
        VideoCodecClassifier.fourCC("dvh1"),
      ]),
      "HEVC"
    )
    XCTAssertEqual(
      VideoCodecClassifier.displayName(for: [VideoCodecClassifier.fourCC("avc3")]),
      "H.264"
    )
  }

  func testVideoDimensionMatcherAllowsOnePixelCodecAlignment() {
    XCTAssertTrue(
      MediaDimensionMatcher.matches(
        outputWidth: 852,
        outputHeight: 480,
        sourceWidth: 853,
        sourceHeight: 480
      )
    )
    XCTAssertTrue(
      MediaDimensionMatcher.matches(
        outputWidth: 480,
        outputHeight: 852,
        sourceWidth: 853,
        sourceHeight: 480
      )
    )
    XCTAssertFalse(
      MediaDimensionMatcher.matches(
        outputWidth: 851,
        outputHeight: 480,
        sourceWidth: 853,
        sourceHeight: 480
      )
    )
  }

  func testCloudPlanningLeavesInputAndOutputUnknownUntilDownload() {
    var cloud = fixture(id: "unknown-size", kind: .video, bytes: nil, output: nil)
    cloud.isCloudOnly = true
    XCTAssertEqual(cloud.inputBytesForPlanning, 0)
    XCTAssertEqual(cloud.outputBytesForPlanning, 0)
    XCTAssertNil(cloud.estimatedSavingsBytes)
    XCTAssertNil(cloud.estimatedSavingsRatio)
  }

  func testCloudReportUsesActualBytesAfterDownloadWithoutCallingThemAnEstimate() {
    var cloud = fixture(
      id: "downloaded-cloud",
      kind: .video,
      format: .h264,
      bytes: 400_000_000,
      output: 200_000_000
    )
    cloud.isCloudOnly = true

    let report = DiskCapacityService.report(for: [cloud], availableBytes: 10_000_000_000)
    XCTAssertEqual(report.knownCloudDownloadBytes, 400_000_000)
    XCTAssertEqual(report.unknownCloudAssetCount, 0)
    XCTAssertEqual(report.knownOutputBytes, 200_000_000)
    XCTAssertEqual(report.requiredBytes, 2_600_000_000)
  }

  func testManualVideoSettingsEstimateUsesConfiguredBitrate() {
    var settings = CompressionSettings.recommended
    settings.videoBitrateMode = .manual
    settings.videoTargetBitrateKbps = 1_000
    settings.audioPolicy = .aac
    settings.aacBitrate = 128_000

    let estimate = MediaPlanning.estimatedOutputBytes(
      inputBytes: 100_000_000,
      kind: .video,
      settings: settings,
      duration: 60
    )

    XCTAssertEqual(estimate, 8_883_000)
  }

  func testOldCompressionSettingsDecodeWithManualDefaults() throws {
    let legacy = """
    {
      "photoQuality": 0.82,
      "videoQuality": 0.80,
      "videoBitrateRatio": 0.60,
      "preserveDimensions": true,
      "preserveFrameRate": true,
      "audioPolicy": "passthroughWhenPossible",
      "aacBitrate": 192000,
      "minimumSavingsRatio": 0.10
    }
    """.data(using: .utf8)!

    let settings = try JSONDecoder().decode(CompressionSettings.self, from: legacy)
    XCTAssertEqual(settings.videoBitrateMode, .sourceRatio)
    XCTAssertEqual(settings.videoTargetBitrateKbps, 2_000)
    XCTAssertEqual(settings.videoMaxBitrateKbps, 0)
    XCTAssertEqual(settings.videoKeyframeIntervalSeconds, 2.0)
    XCTAssertTrue(settings.videoAllowFrameReordering)
  }

  func testDiskReportCountsEachPhotoAssetOnlyOnce() {
    let asset = fixture(
      id: "one-asset",
      bytes: 1_000_000_000,
      output: 600_000_000
    )
    let report = DiskCapacityService.report(
      for: [asset, asset],
      availableBytes: 10_000_000_000
    )

    XCTAssertEqual(report.knownLocalInputBytes, 1_000_000_000)
    XCTAssertEqual(report.knownOutputBytes, 600_000_000)
    XCTAssertEqual(report.requiredBytes, 2_600_000_000)
  }

  func testSelectionPlanRejectsOverflowButStillAcceptsLaterSmallerAsset() {
    let first = fixture(id: "first", bytes: 1_000_000_000, output: 600_000_000)
    let tooLarge = fixture(id: "too-large", bytes: 1_000_000_000, output: 600_000_000)
    let small = fixture(id: "small-after", bytes: 200_000_000, output: 100_000_000)

    let plan = DiskCapacityService.selectionPlan(
      for: [first, tooLarge, small],
      availableBytes: 2_750_000_000
    )

    XCTAssertEqual(plan.accepted.map(\.id), ["first", "small-after"])
    XCTAssertEqual(plan.rejected.map(\.id), ["too-large"])
    XCTAssertTrue(plan.report.hasEnoughSpace)
    XCTAssertEqual(plan.report.requiredBytes, 2_700_000_000)
  }

  func testLocalStorageReportSeparatesImmediateAndPurgeableCapacity() {
    let report = LocalStorageReport(
      totalBytes: 1_000,
      immediatelyAvailableBytes: 200,
      availableBytes: 350
    )
    XCTAssertEqual(report.usedBytes, 800)
    XCTAssertEqual(report.reclaimableBytes, 150)
    XCTAssertEqual(report.usedRatio, 0.8, accuracy: 0.0001)
  }

  func testSavingsStatisticsOnlyCountsCommittedHistory() {
    let asset = fixture(id: "asset", bytes: 1_000_000_000, output: 400_000_000)

    var committed = CompressionSession(assets: [asset], settings: .recommended)
    committed.items[0].state = .committed
    committed.items[0].createdAssetIdentifier = "compressed-copy"
    committed.items[0].actualOutputBytes = 400_000_000
    committed.phase = .committed

    var rolledBack = CompressionSession(assets: [asset], settings: .recommended)
    rolledBack.items[0].state = .rolledBack
    rolledBack.items[0].actualOutputBytes = 300_000_000
    rolledBack.phase = .rolledBack

    let stats = SavingsStatistics.calculate(from: [
      TaskHistoryRecord(session: committed),
      TaskHistoryRecord(session: rolledBack),
    ])
    XCTAssertEqual(stats.savedBytes, 600_000_000)
    XCTAssertEqual(stats.committedItemCount, 1)
    XCTAssertEqual(stats.completedTaskCount, 1)
    XCTAssertEqual(
      Set(TaskHistoryRecord(session: committed).processedAssetIdentifiers ?? []),
      ["asset", "compressed-copy"]
    )
    XCTAssertEqual(TaskHistoryRecord(session: rolledBack).processedAssetIdentifiers, [])
  }

  func testSessionStoreRoundTripsCurrentSessionAndQueueAcrossMultipleWrites() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PhotoSlimTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let asset = fixture(id: "persisted", bytes: 100_000_000, output: 55_000_000)
    let session = CompressionSession(assets: [asset], settings: .recommended)
    let queued = QueuedCompressionTask(assets: [asset], settings: .recommended)
    let store = SessionStore(rootURL: root)
    var state = PersistedApplicationState(
      currentSession: session,
      queue: [queued],
      history: [],
      settings: .recommended,
      browserFilter: BrowserFilter(),
      processedAssetIdentifiers: ["persisted", "compressed"]
    )
    let index = LibraryScanIndex(
      assets: [asset],
      changeTokenData: Data([1, 2, 3])
    )

    try await store.save(state)
    try await store.saveLibraryIndex(index)
    state.browserFilter.sortOption = .dateOldest
    try await store.save(state)
    let loaded = try await store.load()
    let loadedIndex = try await store.loadLibraryIndex()

    XCTAssertEqual(loaded.currentSession?.id, session.id)
    XCTAssertEqual(loaded.queue.first?.id, queued.id)
    XCTAssertEqual(loaded.browserFilter.sortOption, .dateOldest)
    XCTAssertEqual(loaded.schemaVersion, 5)
    XCTAssertEqual(loaded.processedAssetIdentifiers, ["persisted", "compressed"])
    XCTAssertEqual(loadedIndex?.assets.map(\.id), ["persisted"])
    XCTAssertEqual(loadedIndex?.changeTokenData, Data([1, 2, 3]))
  }

  private func fixture(
    id: String,
    kind: MediaKind = .photo,
    format: MediaFormatGroup = .jpeg,
    date: Date = Date(timeIntervalSince1970: 1_600_000_000),
    bytes: Int64? = 100_000_000,
    output: Int64? = 50_000_000
  ) -> MediaAsset {
    MediaAsset(
      id: id,
      kind: kind,
      format: format,
      filename: "\(id).JPG",
      uniformTypeIdentifier: "public.jpeg",
      creationDate: date,
      pixelWidth: 4_032,
      pixelHeight: 3_024,
      duration: kind == .video ? 30 : 0,
      isFavorite: false,
      isHidden: false,
      isCloudOnly: false,
      locationLatitude: nil,
      locationLongitude: nil,
      locationAltitude: nil,
      originalBytes: bytes,
      estimatedOutputBytes: output,
      codec: kind == .video ? "H.264" : nil,
      albumIdentifiers: [],
      exclusionReasons: []
    )
  }
}
