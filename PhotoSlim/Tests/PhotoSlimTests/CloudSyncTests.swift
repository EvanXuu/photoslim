import CloudKit
import Foundation
@testable import PhotoSlim
import PhotoSlimMediaCore
import XCTest

final class CloudSyncTests: XCTestCase {
    func testStableRecordIdentityUsesCloudIdentifierNotLocalIdentifier() {
        let first = ProcessedAssetLedgerEntry(sourceCloudIdentifier: "source-cloud", outputCloudIdentifier: "output-cloud", committedAt: .distantPast)
        let second = ProcessedAssetLedgerEntry(sourceCloudIdentifier: nil, outputCloudIdentifier: "output-cloud", committedAt: .now)
        XCTAssertEqual(first.recordName, second.recordName)
        XCTAssertEqual(first.recordName.count, 70)
        XCTAssertFalse(first.recordName.contains("output-cloud"))
        XCTAssertNotEqual(first.recordName, ProcessedAssetLedgerEntry.recordName(for: "different-cloud"))
    }

    func testIdempotentMergeAndConflictingSourcesAreConservative() {
        let date = Date(timeIntervalSince1970: 100)
        let first = ProcessedAssetLedgerEntry(sourceCloudIdentifier: "source", outputCloudIdentifier: "output", committedAt: date)
        let retry = ProcessedAssetLedgerEntry(sourceCloudIdentifier: nil, outputCloudIdentifier: "output", committedAt: date.addingTimeInterval(50))
        XCTAssertEqual(first.merged(with: retry), retry.merged(with: first))
        XCTAssertEqual(first.merged(with: retry).committedAt, date)
        XCTAssertEqual(first.merged(with: first), first)
        let conflict = ProcessedAssetLedgerEntry(sourceCloudIdentifier: "unrelated", outputCloudIdentifier: "output", committedAt: date)
        XCTAssertNil(first.merged(with: conflict).sourceCloudIdentifier)
        XCTAssertNil(first.merged(with: conflict).merged(with: first).sourceCloudIdentifier)
        XCTAssertEqual(first.merged(with: conflict).merged(with: first).hasConflictingSource, true)
    }

    func testLocalOnlyBuildStartsWithoutConstructingACloudContainer() async {
        let service = ProcessedAssetCloudSyncService(
            photoLibrary: PhotoLibraryService(),
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            cloudKitConfigured: false
        )
        await service.start()
        var updates = await service.updates().makeAsyncIterator()
        let value = await updates.next()
        XCTAssertEqual(value?.phase, .unavailable)
        XCTAssertEqual(value?.processedLocalIdentifiers, [])
    }

    func testAccountIsolationNeverCarriesOutboxOrMappingsToAnotherAccount() throws {
        var state = ProcessedAssetCloudDiskState()
        state.accountKey = "account-A"
        state.isEnabled = false
        let entry = ProcessedAssetLedgerEntry(sourceCloudIdentifier: nil, outputCloudIdentifier: "cloud-A", committedAt: .now)
        state.entries[entry.recordName] = entry
        state.pendingCommits["local-A"] = PendingProcessedAssetCommit(outputLocalIdentifier: "local-A", sourceCloudIdentifier: nil, outputCloudIdentifier: nil, committedAt: .now)
        state.didBackfillLegacyHistory = true
        let encoded = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(ProcessedAssetCloudDiskState.self, from: encoded)
        XCTAssertEqual(restored.isolated(for: "account-A").entries, state.entries)
        let other = restored.isolated(for: "account-B")
        XCTAssertFalse(other.isEnabled)
        XCTAssertTrue(other.entries.isEmpty)
        XCTAssertTrue(other.pendingCommits.isEmpty)
        XCTAssertNil(other.engineState)
        XCTAssertFalse(other.didBackfillLegacyHistory)
        var legacy = state
        legacy.accountKey = nil
        XCTAssertTrue(legacy.isolated(for: "account-A").entries.isEmpty)
    }

    func testCloudRecordsRequireSupportedVersionAndVerifiedIdentity() {
        let key = "stable-cloud-identifier"
        let record = CKRecord(recordType: "ProcessedAsset", recordID: .init(recordName: ProcessedAssetLedgerEntry.recordName(for: key)))
        record["outputAssetKey"] = key as CKRecordValue
        record["completedAt"] = Date() as CKRecordValue
        record["status"] = "committed" as CKRecordValue
        record["recordVersion"] = NSNumber(value: 1)
        XCTAssertNotNil(ProcessedAssetCloudSyncService.entry(from: record))
        record["recordVersion"] = NSNumber(value: 2)
        XCTAssertNil(ProcessedAssetCloudSyncService.entry(from: record))
        record["recordVersion"] = NSNumber(value: 1)
        record["status"] = "preview" as CKRecordValue
        XCTAssertNil(ProcessedAssetCloudSyncService.entry(from: record))
        record["status"] = "committed" as CKRecordValue
        record["outputAssetKey"] = "another-asset" as CKRecordValue
        XCTAssertNil(ProcessedAssetCloudSyncService.entry(from: record))
    }

    func testAdaptiveGridHandlesOuterInnerAndAccessibilityWidths() {
        let samples: [(Double, Int)] = [(320, 1), (375, 2), (430, 2), (640, 3), (768, 4), (1024, 6)]
        for (width, count) in samples {
            XCTAssertEqual(AdaptiveMediaLayout.columnCount(width: width), count)
        }
        XCTAssertEqual(AdaptiveMediaLayout.columnCount(width: 375, accessibilitySize: true), 1)
        XCTAssertEqual(AdaptiveMediaLayout.columnCount(width: .nan), 1)
        XCTAssertEqual(AdaptiveMediaLayout.columnCount(width: 0), 1)
    }
}
