import Foundation

struct PersistedApplicationState: Codable, Sendable {
  var schemaVersion: Int? = 6
  var currentSession: CompressionSession?
  var queue: [QueuedCompressionTask]
  var history: [TaskHistoryRecord]
  var settings: CompressionSettings
  var browserFilter: BrowserFilter
  var processedAssetIdentifiers: Set<String>? = nil
  var pendingCleanupSessionID: UUID? = nil

  static let empty = PersistedApplicationState(
    currentSession: nil,
    queue: [],
    history: [],
    settings: .recommended,
    browserFilter: BrowserFilter()
  )
}

struct LibraryScanIndex: Codable, Sendable {
  static let currentSchemaVersion = 3

  var schemaVersion = currentSchemaVersion
  var assets: [MediaAsset]
  var changeTokenData: Data?
  var updatedAt = Date()
}

actor SessionStore {
  enum StoreError: LocalizedError {
    case cannotCreateDirectory(URL)

    var errorDescription: String? {
      switch self {
      case .cannotCreateDirectory(let url):
        return "无法创建会话目录：\(url.path)"
      }
    }
  }

  private let rootURL: URL
  private let stateURL: URL
  private let libraryIndexURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(rootURL: URL? = nil) {
    let resolvedRoot: URL
    if let rootURL {
      resolvedRoot = rootURL
    } else {
      let support =
        FileManager.default.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
      resolvedRoot = support.appendingPathComponent("PhotoSlim", isDirectory: true)
    }

    self.rootURL = resolvedRoot
    stateURL = resolvedRoot.appendingPathComponent("session-ledger.json")
    libraryIndexURL = resolvedRoot.appendingPathComponent("library-index.json")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func load() throws -> PersistedApplicationState {
    guard FileManager.default.fileExists(atPath: stateURL.path) else {
      return .empty
    }
    return try decoder.decode(PersistedApplicationState.self, from: Data(contentsOf: stateURL))
  }

  func save(_ state: PersistedApplicationState) throws {
    try ensureRootDirectory()
    let data = try encoder.encode(state)
    let stagingURL = rootURL.appendingPathComponent("session-ledger.staging.json")
    try data.write(to: stagingURL, options: .atomic)

    if FileManager.default.fileExists(atPath: stateURL.path) {
      _ = try FileManager.default.replaceItemAt(
        stateURL,
        withItemAt: stagingURL,
        backupItemName: "session-ledger.backup.json",
        options: [.usingNewMetadataOnly]
      )
    } else {
      try FileManager.default.moveItem(at: stagingURL, to: stateURL)
    }
  }

  func loadLibraryIndex() throws -> LibraryScanIndex? {
    guard FileManager.default.fileExists(atPath: libraryIndexURL.path) else { return nil }
    let index = try decoder.decode(
      LibraryScanIndex.self,
      from: Data(contentsOf: libraryIndexURL)
    )
    guard index.schemaVersion == LibraryScanIndex.currentSchemaVersion else { return nil }
    return index
  }

  func saveLibraryIndex(_ index: LibraryScanIndex) throws {
    try ensureRootDirectory()
    let data = try encoder.encode(index)
    let stagingURL = rootURL.appendingPathComponent("library-index.staging.json")
    try data.write(to: stagingURL, options: .atomic)

    if FileManager.default.fileExists(atPath: libraryIndexURL.path) {
      _ = try FileManager.default.replaceItemAt(
        libraryIndexURL,
        withItemAt: stagingURL,
        backupItemName: "library-index.backup.json",
        options: [.usingNewMetadataOnly]
      )
    } else {
      try FileManager.default.moveItem(at: stagingURL, to: libraryIndexURL)
    }
  }

  func workingDirectory(for sessionID: UUID) throws -> URL {
    try ensureRootDirectory()
    let url =
      rootURL
      .appendingPathComponent("Working", isDirectory: true)
      .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    } catch {
      throw StoreError.cannotCreateDirectory(url)
    }
  }

  func removeWorkingDirectory(for sessionID: UUID) throws {
    let url =
      rootURL
      .appendingPathComponent("Working", isDirectory: true)
      .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  private func ensureRootDirectory() throws {
    do {
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    } catch {
      throw StoreError.cannotCreateDirectory(rootURL)
    }
  }
}
