import AVFoundation
import AppKit
import Combine
import Foundation
import SwiftUI

enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
  case library
  case photos
  case videos
  case favorites
  case queue
  case statistics
  case history

  var id: String { rawValue }

  var title: String {
    switch self {
    case .library: return "照片图库"
    case .photos: return "照片"
    case .videos: return "视频"
    case .favorites: return "收藏"
    case .queue: return "准备队列"
    case .statistics: return "统计"
    case .history: return "任务历史"
    }
  }

  var symbol: String {
    switch self {
    case .library: return "photo.on.rectangle.angled"
    case .photos: return "photo"
    case .videos: return "video"
    case .favorites: return "heart"
    case .queue: return "list.bullet.rectangle.portrait"
    case .statistics: return "chart.bar.xaxis"
    case .history: return "clock.arrow.circlepath"
    }
  }
}

struct AppNotice: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

private struct PreparedDownload: @unchecked Sendable {
  let source: MediaAsset
  let imageOriginal: ImageOriginal?
  let videoAsset: AVAsset?
}

  @MainActor
  final class AppModel: ObservableObject {
  @Published var accessState: LibraryAccessState
  @Published var assets: [MediaAsset] = [] {
    didSet {
      assetsRevision += 1
      visibleAssetsCache = nil
    }
  }
  @Published var filter = BrowserFilter()
  @Published var settings = CompressionSettings.recommended
  @Published var selectedIdentifiers: Set<String> = []
  @Published var destination: SidebarDestination = .library
  @Published var currentSession: CompressionSession?
  @Published var queue: [QueuedCompressionTask] = []
  @Published var history: [TaskHistoryRecord] = []
  @Published var isScanning = false
  @Published var isLoadingLibraryIndex = false
  @Published var scanCompleted = 0
  @Published var scanTotal = 0
  @Published var scanFilename = ""
  @Published var isTaskPanelMinimized = false
  @Published var pendingTask: QueuedCompressionTask?
  @Published var pendingDiskReport: DiskSpaceReport?
  @Published var pendingExclusionWarning: ExclusionReason?
  @Published var notice: AppNotice?
  @Published var queueStatusMessage: String?
  @Published private(set) var localStorageReport: LocalStorageReport?
  @Published private(set) var selectionDiskReport: DiskSpaceReport?
  @Published private(set) var storageStatusError: String?
  @Published private(set) var currentWorkingDirectory: URL?
  @Published private(set) var pendingCleanupSessionID: UUID?

  private let photoLibrary: PhotoLibraryService
  private let store: SessionStore
  private let compressionEngine: MediaCompressionEngine
  private var runner: Task<Void, Never>?
  private var scanTask: Task<Void, Never>?
  private var libraryChangeTask: Task<Void, Never>?
  private var hasBootstrapped = false
  private var hasLibraryIndex = false
  private var libraryChangePending = false
  private var libraryChangeTokenData: Data?
  private var processedAssetIdentifiers: Set<String> = []
  private var selectionOrder: [String] = []
  private var assetsRevision = 0
  private var visibleAssetsCache: [MediaAsset]?
  private var visibleAssetsCacheRevision = -1
  private var visibleAssetsCacheFilter: BrowserFilter?
  private var visibleAssetsCacheDestination: SidebarDestination?

  init(
    photoLibrary: PhotoLibraryService = PhotoLibraryService(),
    store: SessionStore = SessionStore(),
    compressionEngine: MediaCompressionEngine = MediaCompressionEngine()
  ) {
    self.photoLibrary = photoLibrary
    self.store = store
    self.compressionEngine = compressionEngine
    accessState = photoLibrary.authorizationState
  }

  var visibleAssets: [MediaAsset] {
    var effective = filter
    // Media kind is owned by the sidebar. Ignore any value restored from an older
    // version so the filter popover cannot silently duplicate the sidebar state.
    effective.mediaKind = nil
    switch destination {
    case .photos: effective.mediaKind = .photo
    case .videos: effective.mediaKind = .video
    case .favorites: effective.favoritesOnly = true
    default: break
    }
    if visibleAssetsCacheRevision == assetsRevision,
      visibleAssetsCacheFilter == effective,
      visibleAssetsCacheDestination == destination,
      let visibleAssetsCache
    {
      return visibleAssetsCache
    }
    let result = MediaQueryEngine.apply(effective, to: assets)
    visibleAssetsCacheRevision = assetsRevision
    visibleAssetsCacheFilter = effective
    visibleAssetsCacheDestination = destination
    visibleAssetsCache = result
    return result
  }

  var selectedAssets: [MediaAsset] {
    var seen: Set<String> = []
    return assets.filter {
      selectedIdentifiers.contains($0.id) && seen.insert($0.id).inserted
    }
  }

  var selectedInputBytes: Int64 {
    selectedAssets.reduce(0) { $0 + $1.inputBytesForPlanning }
  }

  var selectedEstimatedInputBytes: Int64 {
    // Kept as a compatibility surface for older views. Cloud sizes are no
    // longer estimated before the task downloads the original.
    0
  }

  var selectedCloudAssetCount: Int {
    selectedAssets.filter(\.isCloudOnly).count
  }

  var selectedSavingsBytes: Int64 {
    selectedAssets.reduce(0) { $0 + ($1.estimatedSavingsBytes ?? 0) }
  }

  var reservedAssetIdentifiers: Set<String> {
    var values = Set(currentSession?.items.map(\.source.id) ?? [])
    for task in queue { values.formUnion(task.assets.map(\.id)) }
    return values
  }

  var statistics: SavingsStatistics { SavingsStatistics.calculate(from: history) }

  var requiresQuitConfirmation: Bool {
    currentSession?.phase.blocksNewTask == true
  }

  var shouldForceReview: Bool {
    guard let phase = currentSession?.phase else { return false }
    return phase == .reviewPending || phase == .committing || phase == .rollingBack
  }

  var isProcessing: Bool { currentSession?.phase == .processing }

  var allVisibleItemsSelected: Bool {
    let eligibleIDs = Set(
      visibleAssets
        .filter { $0.canProcess && !reservedAssetIdentifiers.contains($0.id) }
        .map(\.id)
    )
    return !eligibleIDs.isEmpty && eligibleIDs.isSubset(of: selectedIdentifiers)
  }

  func bootstrap() {
    guard !hasBootstrapped else { return }
    hasBootstrapped = true
    Task {
      var migratedState = false
      do {
        let persisted = try await store.load()
        currentSession = persisted.currentSession
        queue = persisted.queue
        history = persisted.history
        settings = persisted.settings
        filter = persisted.browserFilter
        processedAssetIdentifiers = persisted.processedAssetIdentifiers ?? []
        pendingCleanupSessionID = persisted.pendingCleanupSessionID
        for record in history {
          processedAssetIdentifiers.formUnion(record.processedAssetIdentifiers ?? [])
        }
        let schemaVersion = persisted.schemaVersion ?? 1
        if schemaVersion < 2 {
          filter.excludedReasons.insert(.codecUnverified)
          migratedState = true
        }
        if schemaVersion < 3 {
          if filter.timeFilter == .recentYear || filter.timeFilter == .recentThreeYears {
            filter.timeFilter = .all
          }
          if filter.sizeFilter == .under10MB
            || filter.sizeFilter == .tenToHundredMB
            || filter.sizeFilter == .hundredMBToOneGB
          {
            filter.sizeFilter = .all
          }
          migratedState = true
        }
        if schemaVersion < 4 {
          filter.excludedReasons.insert(.alreadyProcessed)
          migratedState = true
        }
        if schemaVersion < 5 {
          filter.excludedReasons.remove(.codecUnverified)
          migratedState = true
        }
        if filter.mediaKind != nil {
          filter.mediaKind = nil
          migratedState = true
        }
      } catch {
        notice = AppNotice(title: "会话恢复失败", message: error.localizedDescription)
      }

      refreshStorageStatus(enforceSelectionLimit: true, showNotice: false)
      if migratedState { await persist() }
      accessState = photoLibrary.authorizationState
      guard accessState.canRead else { return }
      await loadLibraryIndexIfAvailable()
      startObservingLibraryChanges()
      await recoverSessionIfNeeded()
      scanLibrary()
    }
  }

  func requestAccessAndScan() {
    Task {
      accessState = await photoLibrary.requestAuthorization()
      if accessState.canRead {
        await loadLibraryIndexIfAvailable()
        startObservingLibraryChanges()
        await recoverSessionIfNeeded()
        scanLibrary()
      }
    }
  }

  func scanLibrary() {
    guard accessState.canRead, !isScanning, !isLoadingLibraryIndex else { return }
    scanTask?.cancel()
    isScanning = true
    libraryChangePending = false
    scanCompleted = 0
    scanTotal = 0
    scanFilename = hasLibraryIndex ? "正在检查图库变更" : "正在建立首次索引"
    let scanSettings = settings
    let scanProcessedIdentifiers = processedAssetIdentifiers
    let previousIndex =
      hasLibraryIndex
      ? LibraryScanIndex(
        assets: assets,
        changeTokenData: libraryChangeTokenData
      )
      : nil

    scanTask = Task {
      do {
        let result = try await photoLibrary.scan(
          settings: scanSettings,
          previousIndex: previousIndex,
          processedIdentifiers: scanProcessedIdentifiers
        ) {
          [weak self] completed, total, filename in
          Task { @MainActor in
            self?.scanCompleted = completed
            self?.scanTotal = total
            self?.scanFilename = filename
          }
        }
        guard !Task.isCancelled else { return }
        let refreshedAssets = result.assets
        assets = refreshedAssets
        libraryChangeTokenData = result.changeTokenData
        hasLibraryIndex = true
        do {
          try await store.saveLibraryIndex(
            LibraryScanIndex(
              assets: refreshedAssets,
              changeTokenData: result.changeTokenData
            )
          )
        } catch {
          notice = AppNotice(
            title: "无法保存图库索引",
            message: "本次扫描结果仍可使用，但下次启动可能需要重新建立索引：\(error.localizedDescription)"
          )
        }
        refreshStorageStatus(enforceSelectionLimit: true, showNotice: false)
      } catch is CancellationError {
        // A cancelled scan leaves the last complete result visible.
      } catch {
        notice = AppNotice(title: "扫描失败", message: error.localizedDescription)
      }
      isScanning = false
      scanTask = nil
      if libraryChangePending {
        scheduleLibraryChangeScan()
      }
    }
  }

  func cancelScan() {
    scanTask?.cancel()
    scanTask = nil
    isScanning = false
  }

  private func loadLibraryIndexIfAvailable() async {
    guard !hasLibraryIndex else { return }
    isLoadingLibraryIndex = true
    defer { isLoadingLibraryIndex = false }
    do {
      guard let index = try await store.loadLibraryIndex() else { return }
      assets = index.assets
      libraryChangeTokenData = index.changeTokenData
      hasLibraryIndex = true
      refreshStorageStatus(enforceSelectionLimit: true, showNotice: false)
    } catch {
      hasLibraryIndex = false
      libraryChangeTokenData = nil
    }
  }

  private func startObservingLibraryChanges() {
    photoLibrary.startObservingChanges { [weak self] in
      Task { @MainActor [weak self] in
        self?.scheduleLibraryChangeScan()
      }
    }
  }

  private func scheduleLibraryChangeScan() {
    libraryChangePending = true
    libraryChangeTask?.cancel()
    libraryChangeTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 750_000_000)
      guard !Task.isCancelled, let self else { return }
      guard !self.isScanning, self.currentSession?.phase.blocksNewTask != true else { return }
      self.libraryChangePending = false
      self.scanLibrary()
    }
  }

  private func saveLibraryIndexIfAvailable() async {
    guard hasLibraryIndex else { return }
    do {
      try await store.saveLibraryIndex(
        LibraryScanIndex(
          assets: assets,
          changeTokenData: libraryChangeTokenData
        )
      )
    } catch {
      notice = AppNotice(title: "无法更新图库索引", message: error.localizedDescription)
    }
  }

  func toggleSelection(_ asset: MediaAsset) {
    if selectedIdentifiers.contains(asset.id) {
      selectedIdentifiers.remove(asset.id)
      selectionOrder.removeAll { $0 == asset.id }
      refreshStorageStatus(enforceSelectionLimit: false, showNotice: false)
      return
    }
    guard asset.canProcess else {
      notice = AppNotice(
        title: "这个项目不能加入任务",
        message: asset.exclusionReasons.first(where: \.isHardBlock)?.warning
          ?? "当前版本无法安全处理这个项目。"
      )
      return
    }
    guard !reservedAssetIdentifiers.contains(asset.id) else {
      notice = AppNotice(title: "项目已在任务中", message: "它已经处于当前任务或准备队列中。")
      return
    }
    do {
      let storage = try updateLocalStorageReport()
      let removed = enforceCurrentSelectionLimit(availableBytes: storage.availableBytes)
      guard removed.isEmpty else {
        notice = AppNotice(
          title: "已取消超出空间的选择",
          message: "本机可用空间发生变化，已取消 \(removed.count) 个后选项目；这个新项目没有被选中。"
        )
        return
      }

      let proposed = orderedSelectedAssets() + [asset]
      let report = DiskCapacityService.report(
        for: proposed,
        availableBytes: storage.availableBytes
      )
      guard report.hasEnoughSpace else {
        let shortfall = max(0, report.requiredBytes - report.availableBytes)
        notice = AppNotice(
          title: "这个项目没有被选中",
          message:
            "加入“\(asset.displayTitle)”后，任务临时空间将超过本机可用空间 \(MediaFormatting.bytes(shortfall))。请先减少选择或释放空间。"
        )
        return
      }

      selectedIdentifiers.insert(asset.id)
      selectionOrder.append(asset.id)
      selectionDiskReport = report
      if asset.isPlainHVC1 {
        notice = AppNotice(
          title: "已选择 HEVC→HEVC 项目",
          message: "普通 hvc1 视频会再次进行有损 HEVC 编码。只有在实际输出更小并通过解码、尺寸、时长验证后，才会进入本地预览；原件仍保持不动。"
        )
      }
    } catch {
      storageStatusError = error.localizedDescription
      notice = AppNotice(title: "无法检查本机空间", message: error.localizedDescription)
    }
  }

  func selectAllVisible() {
    if allVisibleItemsSelected {
      clearSelection()
      return
    }

    let eligible = visibleAssets.filter {
      $0.canProcess && !reservedAssetIdentifiers.contains($0.id)
    }
    do {
      let storage = try updateLocalStorageReport()
      let removed = enforceCurrentSelectionLimit(availableBytes: storage.availableBytes)
      let existing = orderedSelectedAssets()
      let existingIDs = Set(existing.map(\.id))
      let additions = eligible.filter { !existingIDs.contains($0.id) }
      let additionIDs = Set(additions.map(\.id))
      let plan = DiskCapacityService.selectionPlan(
        for: existing + additions,
        availableBytes: storage.availableBytes
      )
      applySelection(plan.accepted, report: plan.report)

      let rejectedAdditions = plan.rejected.filter { additionIDs.contains($0.id) }
      if !removed.isEmpty || !rejectedAdditions.isEmpty {
        var details: [String] = []
        if !removed.isEmpty { details.append("已取消 \(removed.count) 个原有的超限选择") }
        if !rejectedAdditions.isEmpty {
          details.append("有 \(rejectedAdditions.count) 个项目因空间不足未被选中")
        }
        notice = AppNotice(
          title: "已按本机空间限制选择",
          message: details.joined(separator: "；") + "。iCloud 项目大小会在任务下载后读取。"
        )
      }
    } catch {
      storageStatusError = error.localizedDescription
      notice = AppNotice(title: "无法检查本机空间", message: error.localizedDescription)
    }
  }

  func togglePinned(_ asset: MediaAsset) {
    guard let index = assets.firstIndex(where: { $0.id == asset.id }) else { return }
    assets[index].isPinned.toggle()
    Task {
      await saveLibraryIndexIfAvailable()
      await persist()
    }
  }

  func clearSelection() {
    selectedIdentifiers.removeAll()
    selectionOrder.removeAll()
    selectionDiskReport = nil
  }

  func requestExclusionChange(_ reason: ExclusionReason, excluded: Bool) {
    if excluded {
      filter.excludedReasons.insert(reason)
      Task { await persist() }
    } else {
      pendingExclusionWarning = reason
    }
  }

  func confirmShowingExcludedReason() {
    guard let reason = pendingExclusionWarning else { return }
    filter.excludedReasons.remove(reason)
    pendingExclusionWarning = nil
    Task { await persist() }
  }

  func cancelShowingExcludedReason() {
    pendingExclusionWarning = nil
  }

  func savePreferences() {
    Task { await persist() }
  }

  func applyCompressionSettings(_ value: CompressionSettings) {
    settings = value
    refreshStorageStatus(enforceSelectionLimit: true, showNotice: true)
    Task { [weak self] in
      guard let self else { return }
      await self.recalculatePlanningEstimates()
      await persist()
      await saveLibraryIndexIfAvailable()
    }
  }

  func refreshStorageStatus(
    enforceSelectionLimit: Bool = true,
    showNotice: Bool = true
  ) {
    do {
      let storage = try updateLocalStorageReport()
      if enforceSelectionLimit {
        let removed = enforceCurrentSelectionLimit(availableBytes: storage.availableBytes)
        if showNotice, !removed.isEmpty {
          notice = AppNotice(
            title: "已取消超出空间的选择",
            message: "本机可用于任务的空间发生变化，已取消最后选择的 \(removed.count) 个项目。"
          )
        }
      } else if selectedIdentifiers.isEmpty {
        selectionDiskReport = nil
      } else {
        selectionDiskReport = DiskCapacityService.report(
          for: orderedSelectedAssets(),
          availableBytes: storage.availableBytes
        )
      }
    } catch {
      storageStatusError = error.localizedDescription
    }
  }

  func prepareSelectedTask() {
    guard !selectedIdentifiers.isEmpty else {
      notice = AppNotice(title: "尚未选择项目", message: "请选择至少一个可处理的 JPEG、H.264 SDR 或普通 hvc1 HEVC 项目。")
      return
    }
    do {
      let storage = try updateLocalStorageReport()
      let removed = enforceCurrentSelectionLimit(availableBytes: storage.availableBytes)
      guard removed.isEmpty else {
        notice = AppNotice(
          title: "选择已按可用空间调整",
          message: "已取消 \(removed.count) 个超出空间的后选项目。请核对当前选择后再开始。"
        )
        return
      }
      let selected = orderedSelectedAssets().filter(\.canProcess)
      guard !selected.isEmpty else {
        notice = AppNotice(title: "尚未选择项目", message: "请选择至少一个可处理的 JPEG、H.264 SDR 或普通 hvc1 HEVC 项目。")
        return
      }
      let report = DiskCapacityService.report(
        for: selected,
        availableBytes: storage.availableBytes
      )
      pendingTask = QueuedCompressionTask(assets: selected, settings: settings)
      pendingDiskReport = report
    } catch {
      notice = AppNotice(title: "无法检查可用空间", message: error.localizedDescription)
    }
  }

  func cancelPreparedTask() {
    pendingTask = nil
    pendingDiskReport = nil
  }

  func confirmPreparedTask() {
    guard let task = pendingTask, let report = pendingDiskReport else { return }
    guard report.hasEnoughSpace else {
      notice = AppNotice(
        title: "可用空间不足",
        message:
          "预计还需要 \(MediaFormatting.bytes(report.requiredBytes - report.availableBytes))。请释放空间后重试。"
      )
      return
    }
    pendingTask = nil
    pendingDiskReport = nil
    removeSelectedIdentifiers(task.assets.map(\.id))

    if currentSession?.phase.blocksNewTask == true {
      queue.append(task)
      queueStatusMessage = "已加入队列；当前任务审核完成后会再次检查空间。"
      Task { await persist() }
    } else {
      start(task: task)
    }
  }

  func removeQueuedTask(_ id: UUID) {
    queue.removeAll { $0.id == id }
    Task { await persist() }
  }

  func retryStartingQueue() {
    Task { await startNextQueuedTaskIfPossible() }
  }

  func moveQueuedTasks(from offsets: IndexSet, to destination: Int) {
    queue.move(fromOffsets: offsets, toOffset: destination)
    Task { await persist() }
  }

  func minimizeTaskPanel() { isTaskPanelMinimized = true }
  func restoreTaskPanel() { isTaskPanelMinimized = false }

  func terminateCurrentTask() {
    guard let session = currentSession, session.phase == .processing else { return }
    let sessionID = session.id
    runner?.cancel()
    isTaskPanelMinimized = false
    updateSessionStatus("正在终止任务并清理临时文件")
    Task {
      await runner?.value
      do {
        try await store.removeWorkingDirectory(for: sessionID)
        pendingCleanupSessionID = nil
      } catch {
        pendingCleanupSessionID = sessionID
        notice = AppNotice(
          title: "临时文件清理未完成",
          message: "任务已终止，原件未修改。稍后可在任务历史中重试清理：\(error.localizedDescription)"
        )
      }
      guard let current = currentSession, current.id == sessionID else { return }
      var cancelled = current
      cancelled.phase = .cancelled
      cancelled.statusMessage = "任务已终止，临时压缩文件已清理；原件未修改"
      cancelled.updatedAt = Date()
      for index in cancelled.items.indices where cancelled.items[index].createdAssetIdentifier == nil {
        cancelled.items[index].state = .cancelled
        cancelled.items[index].progress = 1
      }
      currentSession = nil
      currentWorkingDirectory = nil
      if !history.contains(where: { $0.id == cancelled.id }) {
        history.append(TaskHistoryRecord(session: cancelled))
      }
      await persist()
      await startNextQueuedTaskIfPossible()
    }
  }

  func retryPendingCleanup() {
    guard let sessionID = pendingCleanupSessionID else { return }
    Task {
      do {
        try await store.removeWorkingDirectory(for: sessionID)
        pendingCleanupSessionID = nil
        notice = AppNotice(title: "临时文件已清理", message: "终止任务留下的临时文件已经删除，原件未修改。")
        await persist()
      } catch {
        notice = AppNotice(title: "临时文件仍未清理", message: error.localizedDescription)
      }
    }
  }

  func reviewOutputURL(for item: TaskItemRecord) -> URL? {
    guard let directory = currentWorkingDirectory,
      let filename = item.temporaryFilename
    else { return nil }
    return directory.appendingPathComponent(filename)
  }

  func loadOriginalReviewImage(for item: TaskItemRecord, targetSize: CGSize) async -> NSImage? {
    await photoLibrary.requestPreviewImage(
      identifier: item.source.id,
      kind: item.source.kind,
      targetSize: targetSize,
      networkAllowed: true
    )
  }

  func rollbackCompressedCopies() {
    guard currentSession?.phase == .reviewPending else { return }
    runner = Task { await performRollback() }
  }

  func commitAndDeleteOriginals() {
    guard currentSession?.phase == .reviewPending else { return }
    runner = Task { await performCommit() }
  }

  func finishFailedSession() {
    guard let session = currentSession, session.phase == .failed,
      session.items.allSatisfy({ $0.createdAssetIdentifier == nil })
    else { return }
    if !history.contains(where: { $0.id == session.id }) {
      history.append(TaskHistoryRecord(session: session))
    }
    currentSession = nil
    Task {
      try? await store.removeWorkingDirectory(for: session.id)
      await persist()
      await startNextQueuedTaskIfPossible()
    }
  }

  func retryFailedSession() {
    guard var session = currentSession, session.phase == .failed else { return }
    for index in session.items.indices where session.items[index].createdAssetIdentifier == nil {
      session.items[index].state = .selected
      session.items[index].errorMessage = nil
      session.items[index].progress = 0
      session.items[index].downloadProgress = session.items[index].source.isCloudOnly ? 0 : 1
      session.items[index].compressionProgress = 0
    }
    session.phase = .processing
    session.statusMessage = "重试失败项目"
    session.updatedAt = Date()
    currentSession = session
    runner = Task {
      await persist()
      await runCurrentSession()
    }
  }

  private func start(task: QueuedCompressionTask) {
    guard currentSession?.phase.blocksNewTask != true else { return }
    do {
      let report = try diskReport(for: task.assets)
      guard report.hasEnoughSpace else {
        queue.insert(task, at: 0)
        queueStatusMessage =
          "队首任务空间不足，需要 \(MediaFormatting.bytes(report.requiredBytes))，当前可用 \(MediaFormatting.bytes(report.availableBytes))。"
        destination = .queue
        Task { await persist() }
        return
      }
    } catch {
      queue.insert(task, at: 0)
      queueStatusMessage = "重新检查磁盘空间失败：\(error.localizedDescription)"
      destination = .queue
      Task { await persist() }
      return
    }

    currentSession = CompressionSession(assets: task.assets, settings: task.settings)
    currentWorkingDirectory = nil
    isTaskPanelMinimized = false
    runner = Task {
      await persist()
      await runCurrentSession()
    }
  }

  private func runCurrentSession() async {
    guard let session = currentSession, session.phase == .processing else { return }
    do {
      let directory = try await store.workingDirectory(for: session.id)
      currentWorkingDirectory = directory
      await reconcileProcessingSession(directory: directory)
      guard currentSession?.phase == .processing else { return }

      let itemIDs = currentSession?.items.map(\.id) ?? []
      var downloadTasks: [UUID: Task<PreparedDownload, Error>] = [:]
      var nextPrefetchIndex = 0
      let cloudIDs = itemIDs.filter { item($0)?.source.isCloudOnly == true }

      func fillDownloadPrefetch() {
        while downloadTasks.count < 5, nextPrefetchIndex < cloudIDs.count {
          let itemID = cloudIDs[nextPrefetchIndex]
          nextPrefetchIndex += 1
          guard let record = item(itemID),
            record.createdAssetIdentifier == nil,
            record.state != .reviewPending
          else { continue }
          downloadTasks[itemID] = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.download(
              itemID: itemID,
              source: record.source,
              isPrefetch: true
            )
          }
        }
      }

      fillDownloadPrefetch()
      defer {
        for task in downloadTasks.values { task.cancel() }
      }
      for itemID in itemIDs {
        if Task.isCancelled { return }
        guard let item = item(itemID),
          item.state != .reviewPending,
          item.createdAssetIdentifier == nil
        else { continue }
        do {
          let prepared: PreparedDownload?
          if let task = downloadTasks.removeValue(forKey: itemID) {
            prepared = try await task.value
            fillDownloadPrefetch()
          } else {
            prepared = nil
          }
          try await process(itemID: itemID, in: directory, prepared: prepared)
        } catch is CancellationError {
          return
        } catch {
          updateItem(itemID) {
            $0.state = .failed
            $0.errorMessage = error.localizedDescription
            $0.progress = 1
          }
          updateSessionStatus("已跳过：\(item.source.displayTitle)")
          await persist()
        }
      }

      guard var completed = currentSession else { return }
      let previewCount = completed.items.filter {
        [.fileVerified, .reviewPending].contains($0.state)
      }.count
      completed.phase = previewCount > 0 ? .reviewPending : .failed
      completed.statusMessage =
        previewCount > 0
        ? "压缩结果已准备，请在本地预览后决定是否写入相册"
        : "没有项目成功创建压缩结果"
      completed.updatedAt = Date()
      currentSession = completed
      isTaskPanelMinimized = false
      await persist()
    } catch {
      guard var failed = currentSession else { return }
      let hasCreatedCopies = failed.items.contains {
        $0.createdAssetIdentifier != nil
      }
      failed.phase = hasCreatedCopies ? .reviewPending : .failed
      failed.statusMessage =
        hasCreatedCopies
        ? "已有压缩副本需要审核；后续处理已停止：\(error.localizedDescription)"
        : error.localizedDescription
      failed.updatedAt = Date()
      currentSession = failed
      isTaskPanelMinimized = false
      await persist()
    }
  }

  private func download(
    itemID: UUID,
    source originalSource: MediaAsset,
    isPrefetch: Bool = false
  ) async throws
    -> PreparedDownload
  {
    guard let session = currentSession else { throw CancellationError() }
    var source = originalSource
    let isCloud = source.isCloudOnly
    updateItem(itemID, makeCurrent: !isPrefetch) {
      $0.state = .downloading
      $0.downloadProgress = isCloud ? 0 : 1
      $0.compressionProgress = 0
      $0.progress = isCloud ? 0 : 0.2
      $0.errorMessage = nil
    }
    if !isPrefetch, isCloud {
      updateSessionStatus("正在从 iCloud 下载 \(source.displayTitle)")
    } else if !isPrefetch {
      updateSessionStatus("正在读取 \(source.displayTitle)")
    }
    await persist()

    var imageOriginal: ImageOriginal?
    var videoAsset: AVAsset?
    let downloadUpdate: @Sendable (Double) -> Void = { [weak self] value in
      Task { @MainActor in
        self?.updateItem(itemID, makeCurrent: !isPrefetch) {
          $0.downloadProgress = value
          $0.progress = min(0.38, value * 0.38)
        }
      }
    }
    if source.kind == .photo {
      imageOriginal = try await photoLibrary.requestImageOriginal(
        identifier: source.id,
        networkAllowed: true,
        progress: downloadUpdate
      )
    } else {
      videoAsset = try await photoLibrary.requestVideoAsset(
        identifier: source.id,
        networkAllowed: true,
        progress: downloadUpdate
      )
    }

    let measuredBytes: Int64
    if let resourceBytes = photoLibrary.knownOriginalResourceBytes(identifier: source.id),
      resourceBytes > 0
    {
      // The value is read only after the request above has completed. It is the
      // actual Photos resource size, never a resolution/bitrate estimate.
      measuredBytes = resourceBytes
    } else if let imageOriginal {
      measuredBytes = Int64(imageOriginal.data.count)
    } else if let videoAsset {
      measuredBytes = await measuredVideoBytes(videoAsset)
    } else {
      measuredBytes = 0
    }

    guard measuredBytes > 0 else { throw CompressionError.originalSizeUnavailable }
    source.originalBytes = measuredBytes
    source.isCloudOnly = false
    source.estimatedOutputBytes = MediaPlanning.estimatedOutputBytes(
      inputBytes: measuredBytes,
      kind: source.kind,
      settings: session.settings,
      duration: source.duration
    )
    updateItem(itemID, makeCurrent: !isPrefetch) {
      $0.source = source
      $0.downloadProgress = 1
      $0.progress = 0.38
    }
    await persist()
    return PreparedDownload(
      source: source,
      imageOriginal: imageOriginal,
      videoAsset: videoAsset
    )
  }

  private func process(
    itemID: UUID,
    in directory: URL,
    prepared: PreparedDownload?
  ) async throws {
    guard let record = item(itemID), let session = currentSession else { return }
    var source = record.source

    if record.state == .fileVerified,
      let temporaryFilename = record.temporaryFilename
    {
      let outputURL = directory.appendingPathComponent(temporaryFilename)
      if FileManager.default.fileExists(atPath: outputURL.path) {
        updateItem(itemID) {
          $0.state = .reviewPending
          $0.progress = 1
        }
        return
      }
    }

    let downloaded: PreparedDownload
    if let prepared {
      downloaded = prepared
    } else {
      downloaded = try await download(itemID: itemID, source: source)
    }
    source = downloaded.source

    // Cloud size is deliberately checked only after the real resource has
    // arrived. The preflight can never know this value from PhotoKit alone.
    let runtimeReport = try diskReport(for: [source])
    guard runtimeReport.hasEnoughSpace else {
      throw CompressionError.insufficientDiskSpace(
        required: runtimeReport.requiredBytes,
        available: runtimeReport.availableBytes
      )
    }

    updateItem(itemID) {
      $0.source = source
      $0.state = .transcoding
      $0.downloadProgress = 1
      $0.progress = 0.38
    }
    updateSessionStatus("正在压缩 \(source.displayTitle)")
    await persist()

    let output = try await compressionEngine.compress(
      source: source,
      imageOriginal: downloaded.imageOriginal,
      videoAsset: downloaded.videoAsset,
      directory: directory,
      settings: session.settings,
      sessionID: session.id,
      itemID: itemID
    ) { [weak self] value in
      Task { @MainActor in
        self?.updateItem(itemID) {
          $0.compressionProgress = value
          $0.progress = 0.38 + value * 0.47
        }
      }
    }

    updateItem(itemID) {
      $0.state = .fileVerified
      $0.temporaryFilename = output.fileURL.lastPathComponent
      $0.actualOutputBytes = output.byteCount
      $0.compressionProgress = 1
      $0.progress = 1
    }
    await persist()
  }

  private func importAndVerify(itemID: UUID, output: CompressionOutput) async throws {
    guard let record = item(itemID) else { return }
    updateItem(itemID) {
      $0.state = .importing
      $0.temporaryFilename = output.fileURL.lastPathComponent
      $0.actualOutputBytes = output.byteCount
      $0.progress = 0.88
    }
    updateSessionStatus("正在创建并核对压缩副本")
    await persist()

    let identifier = try await photoLibrary.importCompressedAsset(
      fileURL: output.fileURL,
      originalFilename: output.originalFilename,
      source: record.source
    )
    updateItem(itemID) {
      $0.createdAssetIdentifier = identifier
      $0.state = .imported
      $0.progress = 0.94
    }
    await persist()

    let verification = try await photoLibrary.verifyImportedAsset(
      identifier: identifier,
      source: record.source,
      expectedFileURL: output.fileURL
    )
    updateItem(itemID) {
      $0.actualOutputBytes = verification.bytes
      $0.state = .reviewPending
      $0.progress = 1
    }
    await persist()
  }

  private func reconcileProcessingSession(directory: URL) async {
    guard let session = currentSession else { return }
    for record in session.items {
      switch record.state {
      case .downloading, .transcoding, .selected:
        updateItem(record.id) {
          $0.state = .selected
          $0.progress = 0
          $0.downloadProgress = $0.source.isCloudOnly ? 0 : 1
          $0.compressionProgress = 0
        }
      case .importing where record.createdAssetIdentifier == nil:
        let marker = "\(session.id.uuidString)/\(record.id.uuidString)"
        if let found = await photoLibrary.findCreatedAsset(
          originalFilename: prettyOutputFilename(for: record.source),
          marker: marker,
          source: record.source
        ) {
          updateItem(record.id) {
            $0.createdAssetIdentifier = found
            $0.state = .imported
            $0.progress = 0.94
          }
          await verifyRecoveredItem(record.id, directory: directory)
        } else {
          updateItem(record.id) { $0.state = .fileVerified }
        }
      case .imported, .metadataVerified:
        await verifyRecoveredItem(record.id, directory: directory)
      default:
        break
      }
    }
    await persist()
  }

  private func verifyRecoveredItem(_ itemID: UUID, directory: URL) async {
    guard let record = item(itemID),
      let identifier = record.createdAssetIdentifier,
      let filename = record.temporaryFilename
    else { return }
    let fileURL = directory.appendingPathComponent(filename)
    do {
      let result = try await photoLibrary.verifyImportedAsset(
        identifier: identifier,
        source: record.source,
        expectedFileURL: fileURL
      )
      updateItem(itemID) {
        $0.state = .reviewPending
        $0.actualOutputBytes = result.bytes
        $0.progress = 1
      }
    } catch {
      updateItem(itemID) {
        $0.state = .failed
        $0.errorMessage = error.localizedDescription
        $0.progress = 1
      }
    }
  }

  private func performRollback() async {
    guard var session = currentSession else { return }
    session.phase = .rollingBack
    session.statusMessage = "正在清理本地压缩结果"
    for index in session.items.indices {
      if session.items[index].createdAssetIdentifier != nil,
        session.items[index].state != .failed
      {
        session.items[index].state = .rollingBack
      }
    }
    currentSession = session
    await persist()

    do {
      let identifiers = session.items.compactMap(\.createdAssetIdentifier)
      if !identifiers.isEmpty {
        session.statusMessage = "正在把旧版压缩副本移到最近删除"
        currentSession = session
        try await photoLibrary.deleteAssets(identifiers: identifiers)
      }
      guard var finished = currentSession else { return }
      for index in finished.items.indices where finished.items[index].state != .failed {
        finished.items[index].state = .rolledBack
      }
      finished.phase = .rolledBack
      finished.statusMessage = identifiers.isEmpty ? "本地压缩结果已清理" : "压缩副本已移到最近删除"
      finished.updatedAt = Date()
      currentSession = finished
      await archiveAndClear(finished)
    } catch {
      restoreReviewAfterDecisionError(error)
    }
  }

  private func ensureImportedAndVerified(itemID: UUID, directory: URL) async throws {
    guard let record = item(itemID),
      let filename = record.temporaryFilename
    else {
      throw CompressionError.outputVerification("找不到本地压缩结果")
    }
    let outputURL = directory.appendingPathComponent(filename)
    guard FileManager.default.fileExists(atPath: outputURL.path) else {
      throw CompressionError.outputVerification("本地压缩结果已丢失")
    }
    let byteCount = Int64(
      (try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    )
    guard byteCount > 0 else {
      throw CompressionError.outputVerification("本地压缩结果为空")
    }
    let output = CompressionOutput(
      fileURL: outputURL,
      byteCount: byteCount,
      originalFilename: prettyOutputFilename(for: record.source)
    )

    if let identifier = record.createdAssetIdentifier {
      let verification = try await photoLibrary.verifyImportedAsset(
        identifier: identifier,
        source: record.source,
        expectedFileURL: outputURL
      )
      updateItem(itemID) {
        $0.actualOutputBytes = verification.bytes
        $0.state = .reviewPending
        $0.progress = 1
      }
      return
    }

    let marker = "\(currentSession?.id.uuidString ?? "")/\(itemID.uuidString)"
    if let found = await photoLibrary.findCreatedAsset(
      originalFilename: output.originalFilename,
      marker: marker,
      source: record.source
    ) {
      updateItem(itemID) {
        $0.createdAssetIdentifier = found
        $0.state = .imported
        $0.progress = 0.94
      }
      await persist()
      let verification = try await photoLibrary.verifyImportedAsset(
        identifier: found,
        source: record.source,
        expectedFileURL: outputURL
      )
      updateItem(itemID) {
        $0.actualOutputBytes = verification.bytes
        $0.state = .reviewPending
        $0.progress = 1
      }
      return
    }

    try await importAndVerify(itemID: itemID, output: output)
  }

  private func performCommit() async {
    guard var session = currentSession else { return }
    session.phase = .committing
    session.statusMessage = "正在把审核通过的压缩结果写入相册"
    currentSession = session
    await persist()

    do {
      let directory = try await store.workingDirectory(for: session.id)
      currentWorkingDirectory = directory

      // Import and verify every local result only after the user has explicitly
      // chosen the commit action. A crash between import and this ledger write is
      // recovered by the marker lookup on the next launch.
      for itemID in session.items.map(\.id) {
        guard let record = item(itemID),
          record.createdAssetIdentifier == nil || record.state != .reviewPending
        else { continue }
        do {
          try await ensureImportedAndVerified(itemID: itemID, directory: directory)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          updateItem(itemID) {
            $0.state = .failed
            $0.errorMessage = error.localizedDescription
            $0.progress = 1
          }
          await persist()
        }
      }

      guard var ready = currentSession else { return }
      let valid = ready.items.filter {
        $0.state == .reviewPending && $0.createdAssetIdentifier != nil
      }
      guard !valid.isEmpty else {
        ready.phase = .reviewPending
        ready.statusMessage = "没有通过验证的压缩结果；原件未修改"
        ready.updatedAt = Date()
        currentSession = ready
        await persist()
        return
      }
      for index in ready.items.indices where
        ready.items[index].state == .reviewPending && ready.items[index].createdAssetIdentifier != nil
      {
        ready.items[index].state = .committing
      }
      ready.statusMessage = "正在删除已确认的原件"
      ready.updatedAt = Date()
      currentSession = ready
      await persist()

      let invalidCreated = ready.items.filter { $0.state == .failed }.compactMap(
        \.createdAssetIdentifier)
      let identifiersToDelete = valid.map(\.source.id) + invalidCreated
      try await photoLibrary.deleteAssets(identifiers: identifiersToDelete)
      guard var finished = currentSession else { return }
      for index in finished.items.indices where finished.items[index].state == .committing {
        finished.items[index].state = .committed
      }
      for item in finished.items where item.state == .committed {
        processedAssetIdentifiers.insert(item.source.id)
        if let createdAssetIdentifier = item.createdAssetIdentifier {
          processedAssetIdentifiers.insert(createdAssetIdentifier)
        }
      }
      finished.phase = .committed
      finished.statusMessage = "原件已移到最近删除"
      finished.updatedAt = Date()
      currentSession = finished
      await recalculatePlanningEstimates()
      await saveLibraryIndexIfAvailable()
      await archiveAndClear(finished)
    } catch {
      restoreReviewAfterDecisionError(error)
    }
  }

  private func restoreReviewAfterDecisionError(_ error: Error) {
    guard var session = currentSession else { return }
    session.phase = .reviewPending
    session.statusMessage = "操作未完成，请重新选择"
    for index in session.items.indices {
      if session.items[index].state == .committing || session.items[index].state == .rollingBack {
        session.items[index].state = .reviewPending
      }
    }
    currentSession = session
    notice = AppNotice(title: "照片图库没有完成操作", message: error.localizedDescription)
    Task { await persist() }
  }

  private func archiveAndClear(_ session: CompressionSession) async {
    if session.phase == .committed {
      for item in session.items where item.state == .committed {
        processedAssetIdentifiers.insert(item.source.id)
        if let createdAssetIdentifier = item.createdAssetIdentifier {
          processedAssetIdentifiers.insert(createdAssetIdentifier)
        }
      }
      await recalculatePlanningEstimates()
      await saveLibraryIndexIfAvailable()
    }
    if !history.contains(where: { $0.id == session.id }) {
      history.append(TaskHistoryRecord(session: session))
    }
    currentSession = nil
    isTaskPanelMinimized = false
    try? await store.removeWorkingDirectory(for: session.id)
    currentWorkingDirectory = nil
    await persist()
    removeSelectedIdentifiers(session.items.map(\.source.id))
    await startNextQueuedTaskIfPossible()
    scanLibrary()
  }

  private func startNextQueuedTaskIfPossible() async {
    guard currentSession == nil, let next = queue.first else { return }
    do {
      let report = try diskReport(for: next.assets)
      guard report.hasEnoughSpace else {
        destination = .queue
        queueStatusMessage =
          "队首任务因空间不足暂停。需要 \(MediaFormatting.bytes(report.requiredBytes))，当前可用 \(MediaFormatting.bytes(report.availableBytes))。"
        await persist()
        return
      }
      queue.removeFirst()
      await persist()
      start(task: next)
    } catch {
      destination = .queue
      queueStatusMessage = "队首任务空间检查失败：\(error.localizedDescription)"
    }
  }

  private func recoverSessionIfNeeded() async {
    guard let session = currentSession else {
      await startNextQueuedTaskIfPossible()
      return
    }
    switch session.phase {
    case .processing:
      runner = Task { await runCurrentSession() }
    case .committing:
      runner = Task { await performCommit() }
    case .rollingBack:
      runner = Task { await performRollback() }
    case .reviewPending:
      currentWorkingDirectory = try? await store.workingDirectory(for: session.id)
      isTaskPanelMinimized = false
    case .failed:
      isTaskPanelMinimized = false
    case .committed, .rolledBack:
      await archiveAndClear(session)
    case .cancelled:
      currentSession = nil
      currentWorkingDirectory = nil
      await startNextQueuedTaskIfPossible()
    }
  }

  private func item(_ id: UUID) -> TaskItemRecord? {
    currentSession?.items.first { $0.id == id }
  }

  private func updateItem(
    _ id: UUID,
    makeCurrent: Bool = true,
    mutation: (inout TaskItemRecord) -> Void
  ) {
    guard var session = currentSession,
      let index = session.items.firstIndex(where: { $0.id == id })
    else { return }
    mutation(&session.items[index])
    session.updatedAt = Date()
    if makeCurrent {
      session.currentItemIndex = index
    }
    currentSession = session
  }

  private func updateSessionStatus(_ status: String) {
    guard var session = currentSession else { return }
    session.statusMessage = status
    session.updatedAt = Date()
    currentSession = session
  }

  private func persist() async {
    let state = PersistedApplicationState(
      currentSession: currentSession,
      queue: queue,
      history: history,
      settings: settings,
      browserFilter: filter,
      processedAssetIdentifiers: processedAssetIdentifiers,
      pendingCleanupSessionID: pendingCleanupSessionID
    )
    do {
      try await store.save(state)
    } catch {
      notice = AppNotice(title: "无法保存会话", message: error.localizedDescription)
    }
  }

  private func diskReport(for assets: [MediaAsset]) throws -> DiskSpaceReport {
    let storage = try updateLocalStorageReport()
    return DiskCapacityService.report(for: assets, availableBytes: storage.availableBytes)
  }

  private var storageVolumeURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
  }

  @discardableResult
  private func updateLocalStorageReport() throws -> LocalStorageReport {
    let report = try DiskCapacityService.localStorage(at: storageVolumeURL)
    localStorageReport = report
    storageStatusError = nil
    return report
  }

  private func orderedSelectedAssets() -> [MediaAsset] {
    guard !selectedIdentifiers.isEmpty else { return [] }
    var assetsByID: [String: MediaAsset] = [:]
    for asset in assets where assetsByID[asset.id] == nil {
      assetsByID[asset.id] = asset
    }

    var result: [MediaAsset] = []
    var included: Set<String> = []
    for identifier in selectionOrder where selectedIdentifiers.contains(identifier) {
      if let asset = assetsByID[identifier], included.insert(identifier).inserted {
        result.append(asset)
      }
    }
    for asset in assets
    where selectedIdentifiers.contains(asset.id) && included.insert(asset.id).inserted
    {
      result.append(asset)
    }
    return result
  }

  @discardableResult
  private func enforceCurrentSelectionLimit(availableBytes: Int64) -> [MediaAsset] {
    let current = orderedSelectedAssets()
    guard !current.isEmpty else {
      clearSelection()
      return []
    }
    let plan = DiskCapacityService.selectionPlan(
      for: current,
      availableBytes: availableBytes
    )
    let acceptedIDs = Set(plan.accepted.map(\.id))
    let removed = current.filter { !acceptedIDs.contains($0.id) }
    applySelection(plan.accepted, report: plan.report)
    return removed
  }

  private func applySelection(_ selected: [MediaAsset], report: DiskSpaceReport) {
    selectedIdentifiers = Set(selected.map(\.id))
    selectionOrder = selected.map(\.id)
    selectionDiskReport = selected.isEmpty ? nil : report
  }

  private func removeSelectedIdentifiers<S: Sequence>(_ identifiers: S)
  where S.Element == String {
    let identifiers = Set(identifiers)
    selectedIdentifiers.subtract(identifiers)
    selectionOrder.removeAll { identifiers.contains($0) }
    refreshStorageStatus(enforceSelectionLimit: false, showNotice: false)
  }

  private func recalculatePlanningEstimates() async {
    let cachedAssets = assets
    let settingsSnapshot = settings
    let processedSnapshot = processedAssetIdentifiers
    let refreshedAssets = await Task.detached(priority: .userInitiated) {
      var result = cachedAssets
      for index in result.indices {
        result[index].refreshPlanning(
          settings: settingsSnapshot,
          processedIdentifiers: processedSnapshot
        )
      }
      return result
    }.value
    guard !Task.isCancelled else { return }
    assets = refreshedAssets
    refreshStorageStatus(enforceSelectionLimit: true, showNotice: false)
  }

  private func prettyOutputFilename(for source: MediaAsset) -> String {
    let base = URL(fileURLWithPath: source.filename).deletingPathExtension().lastPathComponent
    let safe = base.isEmpty ? "PhotoSlim" : base
    return source.kind == .photo ? "\(safe).heic" : "\(safe).mov"
  }

  private func measuredVideoBytes(_ asset: AVAsset) async -> Int64 {
    if let urlAsset = asset as? AVURLAsset,
      let size = try? urlAsset.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    {
      return Int64(size)
    }

    // PhotoKit may return an AVComposition whose segments point at the
    // downloaded source files. Their unique file sizes are a better baseline
    // than a single video-track estimate and include the container/audio data.
    if asset is AVComposition {
      var sourceURLs: Set<URL> = []
      for mediaType in [AVMediaType.video, AVMediaType.audio] {
        let tracks = (try? await asset.loadTracks(withMediaType: mediaType)) ?? []
        for track in tracks {
          guard let compositionTrack = track as? AVCompositionTrack else { continue }
          for segment in compositionTrack.segments where !segment.isEmpty {
            if let sourceURL = segment.sourceURL { sourceURLs.insert(sourceURL) }
          }
        }
      }
      let sourceSizes = sourceURLs.compactMap { url -> Int64? in
        guard url.isFileURL,
          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size > 0
        else { return nil }
        return Int64(size)
      }
      if !sourceSizes.isEmpty {
        return sourceSizes.reduce(0) { total, size in
          total > Int64.max - size ? Int64.max : total + size
        }
      }
    }

    // Estimated data rate is not a file size and can be wildly wrong for
    // iPhone footage. Refuse to turn it into a fake byte count; the task will
    // stop safely and leave the original untouched if no local resource size
    // can be found after the download.
    return 0
  }
}
