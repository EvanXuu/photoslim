import Foundation

enum SessionPhase: String, Codable, Sendable {
  case processing
  case reviewPending
  case committing
  case rollingBack
  case committed
  case rolledBack
  case cancelled
  case failed

  var blocksNewTask: Bool {
    switch self {
    case .committed, .rolledBack, .cancelled: return false
    default: return true
    }
  }
}

enum TaskItemState: String, Codable, Sendable {
  case selected
  case downloading
  case transcoding
  case fileVerified
  case importing
  case imported
  case metadataVerified
  case reviewPending
  case committing
  case committed
  case rollingBack
  case rolledBack
  case cancelled
  case failed

  var title: String {
    switch self {
    case .selected: return "等待"
    case .downloading: return "下载原件"
    case .transcoding: return "正在压缩"
    case .fileVerified: return "预览就绪"
    case .importing: return "正在导入"
    case .imported: return "已导入"
    case .metadataVerified: return "元数据已验证"
    case .reviewPending: return "等待审核"
    case .committing: return "正在写入并删除原件"
    case .committed: return "已写入相册"
    case .rollingBack: return "正在撤回副本"
    case .rolledBack: return "已撤回"
    case .cancelled: return "已终止"
    case .failed: return "失败"
    }
  }

  var symbol: String {
    switch self {
    case .failed: return "exclamationmark.triangle.fill"
    case .reviewPending: return "eye.fill"
    case .committed, .rolledBack: return "checkmark.circle.fill"
    case .cancelled: return "stop.circle.fill"
    case .downloading: return "icloud.and.arrow.down"
    case .transcoding: return "gearshape.2.fill"
    case .importing, .imported, .metadataVerified, .fileVerified: return "checkmark.circle"
    default: return "circle"
    }
  }
}

struct TaskItemRecord: Identifiable, Codable, Hashable, Sendable {
  let id: UUID
  var source: MediaAsset
  var createdAssetIdentifier: String?
  var temporaryFilename: String?
  var state: TaskItemState
  var progress: Double
  var downloadProgress: Double
  var compressionProgress: Double
  var actualOutputBytes: Int64?
  var errorMessage: String?

  init(source: MediaAsset) {
    id = UUID()
    self.source = source
    state = .selected
    progress = 0
    downloadProgress = source.isCloudOnly ? 0 : 1
    compressionProgress = 0
  }
}

struct QueuedCompressionTask: Identifiable, Codable, Sendable {
  let id: UUID
  let createdAt: Date
  var assets: [MediaAsset]
  var settings: CompressionSettings

  init(assets: [MediaAsset], settings: CompressionSettings) {
    id = UUID()
    createdAt = Date()
    self.assets = assets
    self.settings = settings
  }

  /// Only bytes already reported by PhotoKit are shown before a task starts.
  /// Cloud-only originals are intentionally excluded until downloaded.
  var knownInputBytes: Int64 {
    assets.compactMap(\.originalBytes).reduce(0, +)
  }

  var cloudAssetCount: Int {
    assets.filter(\.isCloudOnly).count
  }

  var estimatedInputBytes: Int64 { knownInputBytes }

  var cloudDownloadBytes: Int64 {
    assets.filter(\.isCloudOnly).compactMap(\.originalBytes).reduce(0, +)
  }
}

struct CompressionSession: Identifiable, Codable, Sendable {
  let id: UUID
  let createdAt: Date
  var updatedAt: Date
  var phase: SessionPhase
  var settings: CompressionSettings
  var items: [TaskItemRecord]
  var currentItemIndex: Int?
  var statusMessage: String

  init(assets: [MediaAsset], settings: CompressionSettings) {
    id = UUID()
    createdAt = Date()
    updatedAt = Date()
    phase = .processing
    self.settings = settings
    items = assets.map(TaskItemRecord.init)
    currentItemIndex = nil
    statusMessage = "准备任务"
  }

  var completedItemCount: Int {
    items.filter { [.fileVerified, .reviewPending, .committed, .rolledBack].contains($0.state) }.count
  }

  var failedItemCount: Int { items.filter { $0.state == .failed }.count }

  var progress: Double {
    guard !items.isEmpty else { return 0 }
    return items.reduce(0) { $0 + $1.progress } / Double(items.count)
  }

  var originalBytes: Int64 {
    items.compactMap(\.source.originalBytes).reduce(0, +)
  }

  var outputBytes: Int64 {
    items.compactMap(\.actualOutputBytes).reduce(0, +)
  }

  var savedBytes: Int64 { max(0, originalBytes - outputBytes) }

  var verifiedItems: [TaskItemRecord] {
    items.filter {
      [.fileVerified, .reviewPending, .committing, .committed].contains($0.state)
        && $0.temporaryFilename != nil
    }
  }

  var verifiedOriginalBytes: Int64 {
    verifiedItems.compactMap(\.source.originalBytes).reduce(0, +)
  }

  var verifiedOutputBytes: Int64 {
    verifiedItems.compactMap(\.actualOutputBytes).reduce(0, +)
  }

  var verifiedSavedBytes: Int64 { max(0, verifiedOriginalBytes - verifiedOutputBytes) }
}

struct TaskHistoryRecord: Identifiable, Codable, Sendable {
  let id: UUID
  let startedAt: Date
  let finishedAt: Date
  let outcome: SessionPhase
  let itemCount: Int
  let failedCount: Int
  let originalBytes: Int64
  let outputBytes: Int64
  let processedAssetIdentifiers: [String]?

  init(session: CompressionSession) {
    let countedItems =
      session.phase == .committed
      ? session.items.filter { $0.state == .committed }
      : session.items
    id = session.id
    startedAt = session.createdAt
    finishedAt = Date()
    outcome = session.phase
    itemCount = session.items.count
    failedCount = session.failedItemCount
    originalBytes = countedItems.compactMap(\.source.originalBytes).reduce(0, +)
    outputBytes = countedItems.compactMap(\.actualOutputBytes).reduce(0, +)
    processedAssetIdentifiers =
      session.phase == .committed
      ? Array(
        Set(
          countedItems.flatMap { item in
            [item.source.id, item.createdAssetIdentifier].compactMap { $0 }
          }
        )
      ).sorted()
      : []
  }
}

struct SavingsStatistics: Equatable, Sendable {
  let savedBytes: Int64
  let committedItemCount: Int
  let completedTaskCount: Int
  let latestCompletionDate: Date?

  static func calculate(from history: [TaskHistoryRecord]) -> SavingsStatistics {
    let committed = history.filter { $0.outcome == .committed }
    return SavingsStatistics(
      savedBytes: committed.reduce(0) { total, record in
        total + max(0, record.originalBytes - record.outputBytes)
      },
      committedItemCount: committed.reduce(0) { $0 + max(0, $1.itemCount - $1.failedCount) },
      completedTaskCount: committed.count,
      latestCompletionDate: committed.map(\.finishedAt).max()
    )
  }
}
