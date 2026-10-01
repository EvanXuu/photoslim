#if SWIFT_PACKAGE
import PhotoSlimMediaCore
#endif
import CloudKit
import CryptoKit
import Foundation

enum ProcessedAssetSyncPhase: String, Codable, Sendable {
  case disabled
  case preparing
  case syncing
  case synced
  case waitingForAccount
  case waitingForNetwork
  case unavailable
}

struct ProcessedAssetSyncSnapshot: Equatable, Sendable {
  var isEnabled: Bool
  var phase: ProcessedAssetSyncPhase
  var syncedRecordCount: Int
  var pendingRecordCount: Int
  var lastSyncDate: Date?
  var processedLocalIdentifiers: Set<String>
  var isConfigured = false

  static let initial = ProcessedAssetSyncSnapshot(
    isEnabled: true,
    phase: .preparing,
    syncedRecordCount: 0,
    pendingRecordCount: 0,
    lastSyncDate: nil,
    processedLocalIdentifiers: []
  )

  var statusTitle: String {
    switch phase {
    case .disabled: return L10n("已关闭")
    case .preparing: return L10n("正在准备")
    case .syncing: return L10n("正在同步")
    case .synced: return L10n("已同步")
    case .waitingForAccount: return L10n("等待 iCloud")
    case .waitingForNetwork: return L10n("等待联网")
    case .unavailable: return L10n("暂时不可用")
    }
  }

  var statusDetail: String {
    if isEnabled, !isConfigured {
      return L10n("此版本未启用跨设备同步，本机记录不受影响。")
    }
    switch phase {
    case .disabled:
      return L10n("本机仍会记录已处理项目。")
    case .preparing, .syncing:
      return pendingRecordCount > 0 ? L10n("还有 \(pendingRecordCount) 项等待同步。") : L10n("正在更新跨设备记录。")
    case .synced:
      return syncedRecordCount > 0 ? L10n("已在设备间记录 \(syncedRecordCount) 个项目。") : L10n("跨设备记录已就绪。")
    case .waitingForAccount:
      return L10n("登录 iCloud 后可在设备间识别已处理项目。")
    case .waitingForNetwork:
      return L10n("记录已保存在本机，联网后会自动继续。")
    case .unavailable:
      return L10n("本机记录不受影响，可以稍后重试。")
    }
  }
}

struct ProcessedAssetCommit: Hashable, Sendable {
  let outputLocalIdentifier: String
  let sourceCloudIdentifier: String?
  let outputCloudIdentifier: String?
  let committedAt: Date
}

struct ProcessedAssetBackfillCandidate: Hashable, Sendable {
  let localIdentifier: String
  let committedAt: Date
}

struct ProcessedAssetLedgerEntry: Codable, Hashable, Sendable {
  static let currentRecordVersion = 1

  let recordName: String
  var sourceCloudIdentifier: String?
  let outputCloudIdentifier: String
  var committedAt: Date
  var recordVersion: Int
  // Optional for backward-compatible decoding of the first local ledger.
  var hasConflictingSource: Bool?

  init(
    sourceCloudIdentifier: String?,
    outputCloudIdentifier: String,
    committedAt: Date,
    recordVersion: Int = currentRecordVersion,
    hasConflictingSource: Bool = false
  ) {
    recordName = Self.recordName(for: outputCloudIdentifier)
    self.sourceCloudIdentifier = sourceCloudIdentifier
    self.outputCloudIdentifier = outputCloudIdentifier
    self.committedAt = committedAt
    self.recordVersion = recordVersion
    self.hasConflictingSource = hasConflictingSource
  }

  static func recordName(for outputCloudIdentifier: String) -> String {
    let digest = SHA256.hash(data: Data(outputCloudIdentifier.utf8))
    return "asset-" + digest.map { String(format: "%02x", $0) }.joined()
  }

  func merged(with other: ProcessedAssetLedgerEntry) -> ProcessedAssetLedgerEntry {
    guard outputCloudIdentifier == other.outputCloudIdentifier else { return self }
    let conflict = hasConflictingSource == true || other.hasConflictingSource == true
      || (sourceCloudIdentifier != nil && other.sourceCloudIdentifier != nil
          && sourceCloudIdentifier != other.sourceCloudIdentifier)
    // Once ambiguous, a source relationship must stay ambiguous across retries.
    let source = conflict ? nil : sourceCloudIdentifier ?? other.sourceCloudIdentifier
    return ProcessedAssetLedgerEntry(
      sourceCloudIdentifier: source,
      outputCloudIdentifier: outputCloudIdentifier,
      committedAt: min(committedAt, other.committedAt),
      recordVersion: max(recordVersion, other.recordVersion),
      hasConflictingSource: conflict
    )
  }
}

struct PendingProcessedAssetCommit: Codable, Hashable, Sendable {
  let outputLocalIdentifier: String
  var sourceCloudIdentifier: String?
  var outputCloudIdentifier: String?
  var committedAt: Date
}

struct ProcessedAssetCloudDiskState: Codable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion = currentSchemaVersion
  var isEnabled = true
  var entries: [String: ProcessedAssetLedgerEntry] = [:]
  var pendingCommits: [String: PendingProcessedAssetCommit] = [:]
  var engineState: CKSyncEngine.State.Serialization?
  var lastSyncDate: Date?
  var didBackfillLegacyHistory = false
  var accountKey: String?

  func isolated(for accountKey: String) -> Self {
    guard self.accountKey != accountKey else { return self }
    var state = Self()
    state.isEnabled = isEnabled
    state.accountKey = accountKey
    return state
  }
}

/// Synchronizes only stable Photos cloud identifiers and commit state. Media,
/// filenames, thumbnails and user metadata never enter this service.
actor ProcessedAssetCloudSyncService: CKSyncEngineDelegate {
  static let containerIdentifier = "iCloud.local.codex.PhotoSlim"

  private static let recordType = "ProcessedAsset"
  private static let zoneName = "PhotoSlimProcessedAssets"
  private static let outputKey = "outputAssetKey"
  private static let sourceKey = "sourceAssetKey"
  private static let completedAtKey = "completedAt"
  private static let statusKey = "status"
  private static let versionKey = "recordVersion"
  private static let sourceConflictKey = "sourceAmbiguous"

  private let photoLibrary: PhotoLibraryService
  private var container: CKContainer?
  private let cloudKitConfigured: Bool
  private let stateURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let zoneID = CKRecordZone.ID(
    zoneName: ProcessedAssetCloudSyncService.zoneName,
    ownerName: CKCurrentUserDefaultName
  )

  private var diskState = ProcessedAssetCloudDiskState()
  private var didLoadState = false
  private var syncEngine: CKSyncEngine?
  private var synchronizationTask: Task<Void, Never>?
  private var generation = 0
  private var isStarting = false
  private var needsStartAfterCurrentAttempt = false
  private var phase: ProcessedAssetSyncPhase = .preparing
  private var mappedLocalIdentifiers: Set<String> = []
  private var continuations: [UUID: AsyncStream<ProcessedAssetSyncSnapshot>.Continuation] = [:]

  init(
    photoLibrary: PhotoLibraryService,
    rootURL: URL? = nil,
    container: CKContainer? = nil,
    cloudKitConfigured: Bool? = nil
  ) {
    self.photoLibrary = photoLibrary
    self.container = container
    #if os(iOS)
    let team = Bundle.main.object(forInfoDictionaryKey: "PhotoSlimDevelopmentTeam") as? String ?? ""
    let bundleIsProvisioned = !team.isEmpty && !team.contains("$(")
    #else
    let bundleIsProvisioned = true // The macOS packager validates/embeds the profile before opting in.
    #endif
    self.cloudKitConfigured = cloudKitConfigured
      ?? (container != nil || (bundleIsProvisioned
          && Bundle.main.object(forInfoDictionaryKey: "PhotoSlimCloudSyncConfigured") as? Bool == true))
    let support = rootURL
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = support.appendingPathComponent("PhotoSlim", isDirectory: true)
    stateURL = directory.appendingPathComponent("processed-asset-cloud-ledger.json")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func updates() -> AsyncStream<ProcessedAssetSyncSnapshot> {
    let id = UUID()
    let pair = AsyncStream<ProcessedAssetSyncSnapshot>.makeStream()
    continuations[id] = pair.continuation
    pair.continuation.yield(snapshot())
    pair.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
    }
    return pair.stream
  }

  func start() async {
    loadStateIfNeeded()
    guard !isStarting else {
      needsStartAfterCurrentAttempt = true
      return
    }
    isStarting = true
    defer {
      isStarting = false
      if needsStartAfterCurrentAttempt {
        needsStartAfterCurrentAttempt = false
        Task { await self.start() }
      }
    }
    let startingGeneration = generation
    guard diskState.isEnabled else {
      phase = .disabled
      mappedLocalIdentifiers = []
      publish()
      return
    }

    // Ad-hoc packages cannot carry CloudKit's restricted entitlements. Do not
    // construct a CKContainer in local-only builds: it may raise an Obj-C
    // exception, which Swift's error handling cannot recover from.
    guard cloudKitConfigured else {
      phase = .unavailable
      mappedLocalIdentifiers = []
      publish()
      return
    }
    let container = self.container ?? CKContainer(identifier: Self.containerIdentifier)
    self.container = container

    phase = .preparing
    publish()
    do {
      let accountStatus = try await container.accountStatus()
      guard startingGeneration == generation, diskState.isEnabled else { return }
      guard accountStatus == .available else {
        if accountStatus == .noAccount {
          checkpointAccount()
          let enabled = diskState.isEnabled
          diskState = ProcessedAssetCloudDiskState()
          diskState.isEnabled = enabled
          persistState()
        }
        syncEngine = nil
        mappedLocalIdentifiers = []
        phase = accountStatus == .noAccount ? .waitingForAccount : .unavailable
        publish()
        return
      }

      let userID = try await container.userRecordID()
      guard startingGeneration == generation, diskState.isEnabled else { return }
      activateAccount(ProcessedAssetLedgerEntry.recordName(for: userID.recordName))
      configureEngineIfNeeded()
      await resolvePendingCommits()
      refreshMappedLocalIdentifiers()
      publish()
      scheduleSynchronization()
    } catch {
      if startingGeneration == generation, diskState.isEnabled { handleSyncError(error) }
    }
  }

  func setEnabled(_ isEnabled: Bool) async {
    loadStateIfNeeded()
    guard diskState.isEnabled != isEnabled else {
      if isEnabled { scheduleSynchronization() }
      return
    }

    diskState.isEnabled = isEnabled
    persistState()
    if isEnabled {
      phase = .preparing
      publish()
      await start()
    } else {
      generation += 1
      synchronizationTask?.cancel()
      synchronizationTask = nil
      await syncEngine?.cancelOperations()
      syncEngine = nil
      mappedLocalIdentifiers = []
      phase = .disabled
      publish()
    }
  }

  func retry() async {
    loadStateIfNeeded()
    guard diskState.isEnabled else { return }
    if syncEngine == nil {
      await start()
    } else {
      await resolvePendingCommits()
      scheduleSynchronization()
    }
  }

  func recordCommittedAssets(_ commits: [ProcessedAssetCommit]) async {
    loadStateIfNeeded()
    // Without a verified account scope, keep the ordinary local task history.
    // It will be backfilled through current Photos mappings after sign-in.
    guard diskState.isEnabled, diskState.accountKey != nil, !commits.isEmpty else { return }

    for commit in commits where !commit.outputLocalIdentifier.isEmpty {
      if let outputCloudIdentifier = commit.outputCloudIdentifier {
        upsertLocalEntry(
          ProcessedAssetLedgerEntry(
            sourceCloudIdentifier: commit.sourceCloudIdentifier,
            outputCloudIdentifier: outputCloudIdentifier,
            committedAt: commit.committedAt
          )
        )
      } else {
        let existing = diskState.pendingCommits[commit.outputLocalIdentifier]
        diskState.pendingCommits[commit.outputLocalIdentifier] = PendingProcessedAssetCommit(
          outputLocalIdentifier: commit.outputLocalIdentifier,
          sourceCloudIdentifier: existing?.sourceCloudIdentifier ?? commit.sourceCloudIdentifier,
          outputCloudIdentifier: existing?.outputCloudIdentifier,
          committedAt: min(existing?.committedAt ?? commit.committedAt, commit.committedAt)
        )
      }
    }
    persistState()
    await resolvePendingCommits()
    scheduleSynchronization()
  }

  func backfillLegacyHistory(_ candidates: [ProcessedAssetBackfillCandidate]) async {
    loadStateIfNeeded()
    guard diskState.isEnabled, diskState.accountKey != nil else { return }
    guard photoLibrary.authorizationState.canRead else { return }

    let existingIDs = photoLibrary.existingLocalIdentifiers(candidates.map(\.localIdentifier))
    let unique = Dictionary(candidates.filter { existingIDs.contains($0.localIdentifier) }
      .map { ($0.localIdentifier, $0) }, uniquingKeysWith: {
      $0.committedAt <= $1.committedAt ? $0 : $1
    })
    let mappings = photoLibrary.cloudIdentifiers(
      forLocalIdentifiers: Array(unique.keys)
    )
    for (localIdentifier, cloudIdentifier) in mappings {
      guard let candidate = unique[localIdentifier] else { continue }
      upsertLocalEntry(
        ProcessedAssetLedgerEntry(
          sourceCloudIdentifier: nil,
          outputCloudIdentifier: cloudIdentifier,
          committedAt: candidate.committedAt
        )
      )
    }
    // A just-imported output may not have an iCloud identifier yet. Keep it in
    // the durable outbox instead of considering an incomplete backfill finished.
    for candidate in unique.values where mappings[candidate.localIdentifier] == nil {
      guard diskState.pendingCommits[candidate.localIdentifier] == nil else { continue }
      diskState.pendingCommits[candidate.localIdentifier] = PendingProcessedAssetCommit(
        outputLocalIdentifier: candidate.localIdentifier,
        sourceCloudIdentifier: nil,
        outputCloudIdentifier: nil,
        committedAt: candidate.committedAt
      )
    }
    diskState.didBackfillLegacyHistory = true
    persistState()
    scheduleSynchronization()
  }

  func refreshPhotoMappings() async {
    loadStateIfNeeded()
    guard diskState.isEnabled else { return }
    await resolvePendingCommits()
    refreshMappedLocalIdentifiers()
    publish()
  }

  func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    guard self.syncEngine === syncEngine, diskState.isEnabled else { return }
    switch event {
    case .stateUpdate(let update):
      diskState.engineState = update.stateSerialization
      persistState()

    case .accountChange(let change):
      generation += 1
      synchronizationTask?.cancel()
      synchronizationTask = nil
      checkpointAccount()
      let enabled = diskState.isEnabled
      diskState = ProcessedAssetCloudDiskState()
      diskState.isEnabled = enabled
      self.syncEngine = nil
      switch change.changeType {
      case .signOut:
        diskState.entries.removeAll()
        diskState.engineState = nil
        mappedLocalIdentifiers = []
        phase = .waitingForAccount
      case .signIn, .switchAccounts:
        diskState.entries.removeAll()
        diskState.engineState = nil
        mappedLocalIdentifiers = []
        phase = .syncing
        Task { await self.start() }
      @unknown default:
        mappedLocalIdentifiers = []
        phase = .unavailable
      }
      persistState()
      publish()

    case .fetchedDatabaseChanges(let changes):
      if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
        diskState.entries.removeAll()
        refreshMappedLocalIdentifiers()
        persistState()
        publish()
        syncEngine.state.add(
          pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]
        )
      }

    case .fetchedRecordZoneChanges(let changes):
      var changed = false
      for modification in changes.modifications where modification.record.recordID.zoneID == zoneID {
        guard let entry = Self.entry(from: modification.record) else { continue }
        let existing = diskState.entries[entry.recordName]
        diskState.entries[entry.recordName] = existing?.merged(with: entry) ?? entry
        changed = true
      }
      for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
        changed = diskState.entries.removeValue(forKey: deletion.recordID.recordName) != nil || changed
      }
      if changed {
        diskState.lastSyncDate = Date()
        refreshMappedLocalIdentifiers()
        persistState()
        publish()
      }

    case .sentRecordZoneChanges(let changes):
      for failed in changes.failedRecordSaves {
        switch failed.error.code {
        case .serverRecordChanged:
          if let serverRecord = failed.error.serverRecord,
            let serverEntry = Self.entry(from: serverRecord)
          {
            let existing = diskState.entries[serverEntry.recordName]
            diskState.entries[serverEntry.recordName] = existing?.merged(with: serverEntry) ?? serverEntry
            syncEngine.state.remove(
              pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)]
            )
          }
        case .zoneNotFound, .userDeletedZone:
          syncEngine.state.add(
            pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]
          )
          syncEngine.state.add(
            pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)]
          )
        default:
          break
        }
      }
      if !changes.savedRecords.isEmpty {
        diskState.lastSyncDate = Date()
        phase = pendingUploadCount > 0 ? .waitingForNetwork : .synced
        persistState()
        publish()
      }

    case .didFetchChanges, .didSendChanges:
      diskState.lastSyncDate = Date()
      phase = pendingUploadCount > 0 ? .waitingForNetwork : .synced
      persistState()
      publish()

    case .willFetchChanges, .willFetchRecordZoneChanges, .willSendChanges:
      phase = .syncing
      publish()

    case .sentDatabaseChanges, .didFetchRecordZoneChanges:
      break

    @unknown default:
      break
    }
  }

  func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    guard self.syncEngine === syncEngine, diskState.isEnabled else { return nil }
    let pending = syncEngine.state.pendingRecordZoneChanges.filter {
      context.options.scope.contains($0)
    }
    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) {
      [weak self] recordID in
      await self?.record(for: recordID)
    }
  }

  private func configureEngineIfNeeded() {
    guard syncEngine == nil, let container else { return }
    var configuration = CKSyncEngine.Configuration(
      database: container.privateCloudDatabase,
      stateSerialization: diskState.engineState,
      delegate: self
    )
    configuration.automaticallySync = true
    let engine = CKSyncEngine(configuration)
    syncEngine = engine

    if diskState.engineState == nil {
      engine.state.add(
        pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]
      )
      let changes = diskState.entries.values.map {
        CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(for: $0.recordName))
      }
      engine.state.add(pendingRecordZoneChanges: changes)
    }
  }

  private func synchronizeNow() async {
    guard diskState.isEnabled else { return }
    guard let syncEngine else {
      await start()
      return
    }
    let syncGeneration = generation
    phase = .syncing
    publish()
    do {
      try await syncEngine.sendChanges()
      guard syncGeneration == generation, diskState.isEnabled, !Task.isCancelled else { return }
      try await syncEngine.fetchChanges()
      guard syncGeneration == generation, diskState.isEnabled, !Task.isCancelled else { return }
      try await syncEngine.sendChanges()
      guard syncGeneration == generation, diskState.isEnabled, !Task.isCancelled else { return }
      diskState.lastSyncDate = Date()
      phase = pendingUploadCount > 0 ? .waitingForNetwork : .synced
      persistState()
      publish()
    } catch {
      if syncGeneration == generation, diskState.isEnabled, !Task.isCancelled {
        handleSyncError(error)
      }
    }
  }

  private func scheduleSynchronization() {
    guard diskState.isEnabled, synchronizationTask == nil else { return }
    synchronizationTask = Task { [weak self] in
      guard let self else { return }
      await self.runScheduledSynchronization()
    }
  }

  private func runScheduledSynchronization() async {
    let syncGeneration = generation
    await synchronizeNow()
    if generation == syncGeneration { synchronizationTask = nil }
  }

  private var pendingUploadCount: Int {
    diskState.pendingCommits.count + (syncEngine?.state.pendingRecordZoneChanges.count ?? 0)
  }

  private func resolvePendingCommits() async {
    guard !diskState.pendingCommits.isEmpty, photoLibrary.authorizationState.canRead else { return }
    let localIdentifiers = Array(diskState.pendingCommits.keys)
    let existingIDs = photoLibrary.existingLocalIdentifiers(localIdentifiers)
    for identifier in localIdentifiers where !existingIDs.contains(identifier) {
      diskState.pendingCommits.removeValue(forKey: identifier)
    }
    let mappings = photoLibrary.cloudIdentifiers(forLocalIdentifiers: localIdentifiers)
    for (localIdentifier, outputCloudIdentifier) in mappings {
      guard let pending = diskState.pendingCommits.removeValue(forKey: localIdentifier) else { continue }
      upsertLocalEntry(
        ProcessedAssetLedgerEntry(
          sourceCloudIdentifier: pending.sourceCloudIdentifier,
          outputCloudIdentifier: outputCloudIdentifier,
          committedAt: pending.committedAt
        )
      )
    }
    refreshMappedLocalIdentifiers()
    persistState()
    publish()
  }

  private func upsertLocalEntry(_ entry: ProcessedAssetLedgerEntry) {
    let existing = diskState.entries[entry.recordName]
    let merged = existing?.merged(with: entry) ?? entry
    guard merged != existing else { return }
    diskState.entries[entry.recordName] = merged
    syncEngine?.state.add(
      pendingRecordZoneChanges: [.saveRecord(recordID(for: entry.recordName))]
    )
  }

  private func refreshMappedLocalIdentifiers() {
    guard photoLibrary.authorizationState.canRead else {
      mappedLocalIdentifiers = []
      return
    }
    let cloudIdentifiers = Set(
      diskState.entries.values.flatMap { entry in
        [entry.outputCloudIdentifier, entry.sourceCloudIdentifier].compactMap { $0 }
      }
    )
    mappedLocalIdentifiers = photoLibrary.localIdentifiers(
      forCloudIdentifiers: Array(cloudIdentifiers)
    )
  }

  private func record(for recordID: CKRecord.ID) -> CKRecord? {
    guard recordID.zoneID == zoneID,
      let entry = diskState.entries[recordID.recordName]
    else { return nil }
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    record[Self.outputKey] = entry.outputCloudIdentifier as CKRecordValue
    if let sourceCloudIdentifier = entry.sourceCloudIdentifier {
      record[Self.sourceKey] = sourceCloudIdentifier as CKRecordValue
    }
    record[Self.completedAtKey] = entry.committedAt as CKRecordValue
    record[Self.statusKey] = "committed" as CKRecordValue
    record[Self.versionKey] = NSNumber(value: entry.recordVersion)
    record[Self.sourceConflictKey] = NSNumber(value: entry.hasConflictingSource == true)
    return record
  }

  static func entry(from record: CKRecord) -> ProcessedAssetLedgerEntry? {
    guard record.recordType == recordType,
      let outputCloudIdentifier = record[outputKey] as? String,
      !outputCloudIdentifier.isEmpty,
      record.recordID.recordName == ProcessedAssetLedgerEntry.recordName(for: outputCloudIdentifier),
      let committedAt = record[completedAtKey] as? Date,
      (record[versionKey] as? NSNumber)?.intValue == ProcessedAssetLedgerEntry.currentRecordVersion,
      (record[statusKey] as? String) == "committed"
    else { return nil }
    return ProcessedAssetLedgerEntry(
      sourceCloudIdentifier: (record[sourceConflictKey] as? NSNumber)?.boolValue == true
        ? nil : record[sourceKey] as? String,
      outputCloudIdentifier: outputCloudIdentifier,
      committedAt: committedAt,
      recordVersion: (record[versionKey] as? NSNumber)?.intValue ?? 1,
      hasConflictingSource: (record[sourceConflictKey] as? NSNumber)?.boolValue == true
    )
  }

  private func recordID(for recordName: String) -> CKRecord.ID {
    CKRecord.ID(recordName: recordName, zoneID: zoneID)
  }

  private func handleSyncError(_ error: Error) {
    if let cloudError = error as? CKError {
      switch cloudError.code {
      case .notAuthenticated:
        phase = .waitingForAccount
      case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
        .zoneBusy:
        phase = .waitingForNetwork
      case .zoneNotFound, .userDeletedZone:
        syncEngine?.state.add(
          pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]
        )
        phase = .waitingForNetwork
      default:
        phase = .unavailable
      }
    } else {
      phase = .unavailable
    }
    persistState()
    publish()
  }

  private func snapshot() -> ProcessedAssetSyncSnapshot {
    ProcessedAssetSyncSnapshot(
      isEnabled: diskState.isEnabled,
      phase: diskState.isEnabled ? phase : .disabled,
      syncedRecordCount: diskState.entries.count,
      pendingRecordCount: pendingUploadCount,
      lastSyncDate: diskState.lastSyncDate,
      processedLocalIdentifiers: mappedLocalIdentifiers,
      isConfigured: cloudKitConfigured
    )
  }

  private func publish() {
    let value = snapshot()
    for continuation in continuations.values { continuation.yield(value) }
  }

  private func removeContinuation(_ id: UUID) {
    continuations.removeValue(forKey: id)
  }

  private func loadStateIfNeeded() {
    guard !didLoadState else { return }
    didLoadState = true
    guard FileManager.default.fileExists(atPath: stateURL.path),
      let data = try? Data(contentsOf: stateURL),
      let loaded = try? decoder.decode(ProcessedAssetCloudDiskState.self, from: data),
      loaded.schemaVersion == ProcessedAssetCloudDiskState.currentSchemaVersion
    else { return }
    diskState = loaded
  }

  private func persistState() {
    persistState(to: stateURL)
  }

  private func accountURL(_ key: String) -> URL {
    stateURL.deletingLastPathComponent()
      .appendingPathComponent("cloud-accounts", isDirectory: true)
      .appendingPathComponent(key + ".json")
  }

  private func checkpointAccount() {
    if let key = diskState.accountKey { persistState(to: accountURL(key)) }
  }

  private func activateAccount(_ key: String) {
    guard diskState.accountKey != key else { return }
    checkpointAccount()
    let enabled = diskState.isEnabled
    if let data = try? Data(contentsOf: accountURL(key)),
       let saved = try? decoder.decode(ProcessedAssetCloudDiskState.self, from: data),
       saved.accountKey == key {
      diskState = saved
      diskState.isEnabled = enabled
    } else {
      diskState = diskState.isolated(for: key)
    }
    syncEngine = nil
    mappedLocalIdentifiers = []
    persistState()
  }

  private func persistState(to url: URL) {
    do {
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try encoder.encode(diskState)
      try data.write(to: url, options: .atomic)
    } catch {
      phase = .unavailable
    }
  }
}
