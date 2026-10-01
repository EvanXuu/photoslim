#if SWIFT_PACKAGE
import PhotoSlimMediaCore
#endif
#if os(iOS) && PHOTOSLIM_UNIFIED_APP
import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import UIKit

@MainActor
struct PhotoSlimiOSSharedAuthorizationView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    ContentUnavailableView {
      Label(L10n("连接照片图库"), systemImage: "photo.on.rectangle.angled")
    } description: {
      Text(description)
    } actions: {
      if model.accessState == .denied || model.accessState == .restricted {
        Button(L10n("打开系统设置")) {
          guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
          openURL(url)
        }
        .buttonStyle(.borderedProminent)
        .tint(PhotoSlimiOSUnifiedTheme.signal)
        .foregroundStyle(PhotoSlimiOSUnifiedTheme.signalForeground)
      } else {
        Button(L10n("允许访问照片")) {
          model.requestAccessAndScan()
        }
        .buttonStyle(.borderedProminent)
        .tint(PhotoSlimiOSUnifiedTheme.signal)
        .foregroundStyle(PhotoSlimiOSUnifiedTheme.signalForeground)
      }
    }
  }

  private var description: String {
    switch model.accessState {
    case .denied:
      return L10n("照片访问已关闭。请在系统设置中允许 PhotoSlim 访问照片。")
    case .restricted:
      return L10n("这台设备限制了照片访问。")
    case .limited:
      return L10n("PhotoSlim 只能读取你允许的项目。")
    case .authorized:
      return ""
    case .notDetermined:
      return L10n("允许访问后即可筛选照片和视频，并在本机生成压缩结果。")
    }
  }
}

@MainActor
struct PhotoSlimiOSQueueWorkspace: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Group {
      if model.queue.isEmpty && model.currentSession == nil {
        ContentUnavailableView(
          L10n("队列为空"),
          systemImage: "list.bullet.rectangle",
          description: Text(L10n("从图库选择项目并点击“下一步”，任务会在这里等待处理。"))
        )
      } else {
        List {
          if let session = model.currentSession {
            Section(L10n("当前任务")) {
              Button {
                if model.isProcessing { model.restoreTaskPanel() }
              } label: {
                HStack(spacing: 12) {
                  ProgressView(value: session.progress)
                    .tint(PhotoSlimiOSUnifiedTheme.signal)
                    .frame(width: 42)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(session.statusMessage)
                      .font(.body.weight(.semibold))
                    Text(L10n("\(session.completedItemCount)/\(session.items.count) 个项目"))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  if model.isProcessing {
                    Image(systemName: "chevron.right")
                      .foregroundStyle(.tertiary)
                  }
                }
              }
              .buttonStyle(.plain)
            }
          }

          if let message = model.queueStatusMessage {
            Section {
              Label(message, systemImage: "info.circle")
                .font(.subheadline)
              Button(L10n("重新检查并开始")) {
                model.retryStartingQueue()
              }
            }
          }

          Section(L10n("等待处理")) {
            ForEach(model.queue) { task in
              VStack(alignment: .leading, spacing: 5) {
                Text(L10n("\(task.assets.count) 个项目"))
                  .font(.body.weight(.semibold))
                Text(queueSummary(task))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(task.settings.summary(for: task.mediaKind))
                  .font(.caption)
                  .foregroundStyle(PhotoSlimiOSUnifiedTheme.signal)
              }
              .padding(.vertical, 4)
            }
            .onDelete { offsets in
              for index in offsets {
                guard model.queue.indices.contains(index) else { continue }
                model.removeQueuedTask(model.queue[index].id)
              }
            }
            .onMove(perform: model.moveQueuedTasks)
          }
        }
      }
    }
    .navigationTitle(L10n("准备队列"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.queue.count > 1 {
        ToolbarItem(placement: .topBarTrailing) {
          EditButton()
        }
      }
    }
  }

  private func queueSummary(_ task: QueuedCompressionTask) -> String {
    var parts: [String] = []
    if task.knownInputBytes > 0 {
      parts.append(MediaFormatting.bytes(task.knownInputBytes))
    }
    if task.cloudAssetCount > 0 {
      parts.append(L10n("\(task.cloudAssetCount) 个 iCloud 项目"))
    }
    if parts.isEmpty { parts.append(L10n("大小将在任务开始后确认")) }
    return parts.joined(separator: " · ")
  }
}

@MainActor
struct PhotoSlimiOSStatisticsWorkspace: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    List {
      Section(L10n("已节省空间")) {
        LabeledContent(
          L10n("累计节省"),
          value: MediaFormatting.bytes(model.statistics.savedBytes)
        )
        LabeledContent(
          L10n("已处理项目"),
          value: "\(model.statistics.committedItemCount)"
        )
        LabeledContent(
          L10n("完成任务"),
          value: "\(model.statistics.completedTaskCount)"
        )
        if let date = model.statistics.latestCompletionDate {
          LabeledContent(L10n("最近完成"), value: MediaFormatting.date(date))
        }
      }

      Section(L10n("本机存储")) {
        if let storage = model.localStorageReport {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(L10n("已使用"))
              Spacer()
              Text(
                "\(MediaFormatting.bytes(storage.usedBytes)) / \(MediaFormatting.bytes(storage.totalBytes))"
              )
              .foregroundStyle(.secondary)
            }
            ProgressView(value: storage.usedRatio)
              .tint(PhotoSlimiOSUnifiedTheme.signal)
            LabeledContent(
              L10n("立即可用"),
              value: MediaFormatting.bytes(storage.immediatelyAvailableBytes)
            )
            if storage.reclaimableBytes > 0 {
              LabeledContent(
                L10n("系统可回收"),
                value: MediaFormatting.bytes(storage.reclaimableBytes)
              )
            }
          }
          .padding(.vertical, 4)
        } else {
          Text(model.storageStatusError ?? L10n("正在读取存储空间"))
            .foregroundStyle(.secondary)
        }
      }

      Section(L10n("跨设备记录")) {
        LabeledContent(L10n("状态"), value: model.processedAssetSync.statusTitle)
        LabeledContent(
          L10n("已记录项目"),
          value: "\(model.processedAssetSync.syncedRecordCount)"
        )
        if model.processedAssetSync.pendingRecordCount > 0 {
          LabeledContent(
            L10n("等待同步"),
            value: "\(model.processedAssetSync.pendingRecordCount)"
          )
        }
        if let date = model.processedAssetSync.lastSyncDate {
          LabeledContent(L10n("最近更新"), value: MediaFormatting.date(date))
        }
        Text(model.processedAssetSync.statusDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
        if model.processedAssetSync.isConfigured, model.processedAssetSync.isEnabled {
          Button(L10n("立即同步")) { model.retryProcessedAssetSync() }
            .frame(minHeight: 44)
        }
      }
    }
    .navigationTitle(L10n("统计"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          model.refreshStorageStatus(enforceSelectionLimit: true, showNotice: false)
        } label: {
          Label(L10n("刷新存储空间"), systemImage: "arrow.clockwise").labelStyle(.iconOnly)
        }
        .accessibilityLabel(L10n("刷新存储空间"))
      }
    }
  }
}

@MainActor
struct PhotoSlimiOSHistoryWorkspace: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Group {
      if model.history.isEmpty {
        ContentUnavailableView(
          L10n("还没有任务记录"),
          systemImage: "clock.arrow.circlepath",
          description: Text(L10n("确认写入或撤回压缩结果后，任务会显示在这里。"))
        )
      } else {
        List(model.history.reversed()) { record in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Label(historyTitle(record), systemImage: historySymbol(record))
                .font(.body.weight(.semibold))
              Spacer()
              Text(MediaFormatting.date(record.finishedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(L10n("\(record.itemCount) 个项目 · \(record.failedCount) 个失败"))
              .font(.caption)
              .foregroundStyle(.secondary)
            if record.outcome == .committed {
              Text(L10n("实际节省 \(MediaFormatting.bytes(max(0, record.originalBytes - record.outputBytes)))"))
                .font(.caption.weight(.medium))
                .foregroundStyle(PhotoSlimiOSUnifiedTheme.success)
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .navigationTitle(L10n("任务历史"))
    .navigationBarTitleDisplayMode(.inline)
  }

  private func historyTitle(_ record: TaskHistoryRecord) -> String {
    switch record.outcome {
    case .committed: return L10n("已写入相册")
    case .rolledBack: return L10n("已撤回压缩结果")
    case .cancelled: return L10n("任务已终止")
    case .failed: return L10n("任务失败")
    default: return L10n("任务结束")
    }
  }

  private func historySymbol(_ record: TaskHistoryRecord) -> String {
    switch record.outcome {
    case .committed: return "checkmark.circle.fill"
    case .rolledBack: return "arrow.uturn.backward.circle"
    case .cancelled: return "stop.circle"
    case .failed: return "exclamationmark.triangle"
    default: return "clock"
    }
  }
}

@MainActor
struct PhotoSlimiOSProcessingWorkspace: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmsTermination = false

  var body: some View {
    NavigationStack {
      Group {
        if let session = model.currentSession {
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              VStack(alignment: .leading, spacing: 9) {
                Text(session.statusMessage)
                  .font(.title3.weight(.semibold))
                ProgressView(value: session.progress)
                  .tint(PhotoSlimiOSUnifiedTheme.signal)
                Text(L10n("\(session.completedItemCount)/\(session.items.count) 个项目"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .padding(16)

              LazyVStack(spacing: 10) {
                ForEach(session.items) { item in
                  PhotoSlimiOSTaskItemRow(item: item)
                }
              }
              .padding(.horizontal, 16)
              .padding(.bottom, 24)
            }
          }
        } else {
          ProgressView()
        }
      }
      .background(PhotoSlimiOSUnifiedTheme.canvas)
      .navigationTitle(L10n("正在准备与压缩"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            model.minimizeTaskPanel()
          } label: {
            Label(L10n("收起任务"), systemImage: "chevron.down").labelStyle(.iconOnly)
          }
          .accessibilityLabel(L10n("收起任务"))
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .destructive) {
            confirmsTermination = true
          } label: {
            Label(L10n("终止任务"), systemImage: "stop.circle").labelStyle(.iconOnly)
          }
          .accessibilityLabel(L10n("终止任务"))
        }
      }
      .confirmationDialog(
        L10n("终止当前任务？"),
        isPresented: $confirmsTermination,
        titleVisibility: .visible
      ) {
        Button(L10n("终止并清理临时文件"), role: .destructive) {
          model.terminateCurrentTask()
        }
        Button(L10n("继续任务"), role: .cancel) {}
      } message: {
        Text(L10n("原件不会被修改，已经生成但尚未写入相册的临时文件会被删除。"))
      }
    }
    .background(Color(.systemBackground).ignoresSafeArea())
  }
}

private struct PhotoSlimiOSTaskItemRow: View {
  let item: TaskItemRecord

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: item.state.symbol)
          .foregroundStyle(item.state == .failed ? PhotoSlimiOSUnifiedTheme.danger : PhotoSlimiOSUnifiedTheme.signal)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.source.displayTitle)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(item.state.title)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(Int((item.progress * 100).rounded()))%")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      if item.state == .downloading || item.downloadProgress < 1 {
        progressLine(L10n("iCloud 下载"), item.downloadProgress)
      }
      if item.state == .transcoding || item.compressionProgress > 0 {
        progressLine(L10n("压缩"), item.compressionProgress)
      }
      if let error = item.errorMessage {
        Text(error)
          .font(.caption)
          .foregroundStyle(PhotoSlimiOSUnifiedTheme.danger)
      }
    }
    .padding(14)
    .background(
      Color(.secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
  }

  private func progressLine(_ title: String, _ value: Double) -> some View {
    HStack(spacing: 9) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 58, alignment: .leading)
      ProgressView(value: value)
        .tint(PhotoSlimiOSUnifiedTheme.signal)
    }
  }
}

@MainActor
struct PhotoSlimiOSFailedTaskWorkspace: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    NavigationStack {
      List {
        Section {
          Label(
            model.currentSession?.statusMessage ?? L10n("任务没有完成"),
            systemImage: "exclamationmark.triangle"
          )
        }

        if let items = model.currentSession?.items.filter({ $0.state == .failed }) {
          Section(L10n("失败项目")) {
            ForEach(items) { item in
              VStack(alignment: .leading, spacing: 4) {
                Text(item.source.displayTitle)
                  .font(.body.weight(.semibold))
                Text(item.errorMessage ?? L10n("处理失败"))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        Section {
          Button(L10n("重试失败项目")) { model.retryFailedSession() }
            .foregroundStyle(PhotoSlimiOSUnifiedTheme.signal)
          Button(L10n("结束任务"), role: .destructive) { model.finishFailedSession() }
        }
      }
      .navigationTitle(L10n("任务未完成"))
      .navigationBarTitleDisplayMode(.inline)
    }
    .background(Color(.systemBackground).ignoresSafeArea())
  }
}

@MainActor
struct PhotoSlimiOSSharedReviewWorkspace: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
      let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: 10),
        count: AdaptiveMediaLayout.columnCount(
          width: geometry.size.width, accessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
      )
      ScrollView {
        if let session = model.currentSession {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
              Text(L10n("压缩结果已准备好"))
                .font(.title3.weight(.semibold))
              Text(L10n("点按结果放大；按住图片临时查看原图。原件尚未修改。"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
              if session.verifiedSavedBytes > 0 {
                Text(L10n("实际节省 \(MediaFormatting.bytes(session.verifiedSavedBytes))"))
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(PhotoSlimiOSUnifiedTheme.success)
              }
            }
            .padding(.horizontal, 16)

            LazyVGrid(columns: columns, spacing: 14) {
              ForEach(session.verifiedItems) { item in
                if let url = model.reviewOutputURL(for: item) {
                  PhotoSlimiOSSharedReviewTile(item: item, outputURL: url)
                }
              }
            }
            .padding(.horizontal, 12)

            let failedItems = session.items.filter { $0.state == .failed }
            if !failedItems.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text(L10n("\(failedItems.count) 个项目未生成结果"))
                  .font(.headline)
                ForEach(failedItems) { item in
                  Text("\(item.source.displayTitle)：\(item.errorMessage ?? L10n("处理失败"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .padding(16)
            }
          }
          .padding(.top, 12)
          .padding(.bottom, 24)
        }
      }
      .background(PhotoSlimiOSUnifiedTheme.canvas)
      .navigationTitle(L10n("检查压缩结果"))
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        reviewActions
      }
      }
      .navigationTitle(L10n("检查压缩结果"))
      .navigationBarTitleDisplayMode(.inline)
    }
    .background(Color(.systemBackground).ignoresSafeArea())
  }

  private var reviewActions: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n("确认结果后再写入相册"))
        .font(.subheadline.weight(.semibold))

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { reviewButtons }
        VStack(spacing: 10) { reviewButtons }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.bar)
  }

  @ViewBuilder
  private var reviewButtons: some View {
        Button(L10n("撤回压缩副本")) {
          model.rollbackCompressedCopies()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)

        Button(L10n("写入相册并删除原件")) {
          model.commitAndDeleteOriginals()
        }
        .buttonStyle(.borderedProminent)
        .tint(PhotoSlimiOSUnifiedTheme.signal)
        .foregroundStyle(PhotoSlimiOSUnifiedTheme.signalForeground)
        .frame(maxWidth: .infinity)
  }
}

@MainActor
private struct PhotoSlimiOSSharedReviewTile: View {
  @EnvironmentObject private var model: AppModel
  let item: TaskItemRecord
  let outputURL: URL
  @StateObject private var outputLoader = PhotoSlimiOSReviewOutputLoader()
  @State private var originalImage: UIImage?
  @State private var isPressing = false
  @State private var isLoadingOriginal = false
  @State private var showsDetail = false

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ZStack {
        Color(.secondarySystemGroupedBackground)

        if isPressing, let originalImage {
          Image(uiImage: originalImage)
            .resizable()
            .scaledToFit()
        } else if let outputImage = outputLoader.image {
          Image(uiImage: outputImage)
            .resizable()
            .scaledToFit()
        } else {
          ProgressView()
        }

        VStack {
          HStack {
            Spacer()
            Text(isPressing && originalImage != nil ? L10n("原图") : L10n("压缩结果"))
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 8)
              .padding(.vertical, 5)
              .background(.thinMaterial, in: Capsule())
          }
          Spacer()
        }
        .padding(7)
      }
      .aspectRatio(4 / 3, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .contentShape(Rectangle())
      .onTapGesture { showsDetail = true }
      .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 20, pressing: { pressing in
        isPressing = pressing
        if pressing { loadOriginalIfNeeded() }
      }, perform: {})

      Text(item.source.displayTitle)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      if let saved = savedBytes, saved > 0 {
        Text(L10n("实际节省 \(MediaFormatting.bytes(saved))"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .task(id: outputURL) {
      outputLoader.load(url: outputURL, kind: item.source.kind)
    }
    .sheet(isPresented: $showsDetail) {
      PhotoSlimiOSReviewDetail(
        item: item,
        outputURL: outputURL,
        outputImage: outputLoader.image,
        originalImage: originalImage
      )
      .environmentObject(model)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L10n("\(item.source.displayTitle)，压缩结果"))
    .accessibilityHint(L10n("点按放大，按住查看原图"))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { showsDetail = true }
  }

  private var savedBytes: Int64? {
    guard let original = item.source.originalBytes, let output = item.actualOutputBytes else {
      return nil
    }
    return max(0, original - output)
  }

  private func loadOriginalIfNeeded() {
    guard originalImage == nil, !isLoadingOriginal else { return }
    isLoadingOriginal = true
    Task {
      let result = await model.loadOriginalReviewImage(
        for: item,
        targetSize: CGSize(width: 1_600, height: 1_600)
      )
      originalImage = result
      isLoadingOriginal = false
    }
  }
}

@MainActor
private final class PhotoSlimiOSReviewOutputLoader: ObservableObject {
  @Published var image: UIImage?
  private var loadTask: Task<Void, Never>?
  private var loadVersion = 0

  func load(url: URL, kind: MediaKind) {
    loadTask?.cancel()
    loadVersion += 1
    let version = loadVersion
    loadTask = Task {
      if kind == .photo {
        let decoded = await Task.detached(priority: .userInitiated) {
          guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 1_200,
              kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { return Optional<UIImage>.none }
          return UIImage(cgImage: preview)
        }.value
        guard !Task.isCancelled, loadVersion == version else { return }
        image = decoded
        return
      }

      let asset = AVURLAsset(url: url)
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 1_200, height: 1_200)
      let time = NSValue(time: .zero)
      await withCheckedContinuation { continuation in
        generator.generateCGImagesAsynchronously(forTimes: [time]) {
          _, cgImage, _, _, _ in
          Task { @MainActor in
            if self.loadVersion == version, let cgImage { self.image = UIImage(cgImage: cgImage) }
            continuation.resume()
          }
        }
      }
    }
  }

  deinit { loadTask?.cancel() }
}

@MainActor
private struct PhotoSlimiOSReviewDetail: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel
  let item: TaskItemRecord
  let outputURL: URL
  let outputImage: UIImage?
  @State private var detailOutputImage: UIImage?
  @State private var originalImage: UIImage?
  @State private var isShowingOriginal = false
  @State private var player: AVPlayer

  init(
    item: TaskItemRecord,
    outputURL: URL,
    outputImage: UIImage?,
    originalImage: UIImage?
  ) {
    self.item = item
    self.outputURL = outputURL
    self.outputImage = outputImage
    _originalImage = State(initialValue: originalImage)
    _player = State(initialValue: AVPlayer(url: outputURL))
  }

  var body: some View {
    NavigationStack {
      previewLayout
      .navigationTitle(item.source.displayTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button { dismiss() } label: { Label(L10n("完成"), systemImage: "checkmark") }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Label(
            isShowingOriginal ? L10n("原图") : L10n("压缩结果"),
            systemImage: isShowingOriginal ? "photo" : "checkmark.circle"
          )
        }
      }
    }
    .task {
      if item.source.kind == .photo {
        let fileURL = outputURL
        let decoded = await Task.detached(priority: .userInitiated) {
          UIImage(contentsOfFile: fileURL.path)
        }.value
        guard !Task.isCancelled else { return }
        detailOutputImage = decoded
      }
      await loadOriginal()
    }
    .onDisappear { player.pause() }
    .onChange(of: isShowingOriginal) { _, original in
      if original { player.pause() }
    }
  }

  @ViewBuilder
  private var previewLayout: some View {
    #if PHOTOSLIM_DUO_SDK
    if #available(iOS 27.1, *) {
      ArrangementView {
        VStack {
          Spacer(minLength: 0)
          comparisonControl
        }
      } secondary: {
        previewMedia
      }
      .arrangementViewStyle(.overlay)
    } else {
      legacyPreview
    }
    #else
    legacyPreview
    #endif
  }

  private var legacyPreview: some View {
    previewMedia.safeAreaInset(edge: .bottom, spacing: 0) { comparisonControl }
  }

  @ViewBuilder
  private var previewMedia: some View {
    if item.source.kind == .video, !isShowingOriginal {
      VideoPlayer(player: player).background(Color.black)
    } else if let image = isShowingOriginal ? originalImage : (detailOutputImage ?? outputImage) {
      PhotoSlimiOSZoomableImage(image: image)
        .background(Color.black)
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var comparisonControl: some View {
    Button {} label: {
      Label(L10n("查看原图"), systemImage: "photo.on.rectangle")
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in isShowingOriginal = true }
        .onEnded { _ in isShowingOriginal = false }
    )
    .accessibilityAction { isShowingOriginal.toggle() }
    .padding(12)
    .background(.bar)
  }

  private func loadOriginal() async {
    guard item.source.kind == .photo || originalImage == nil else { return }
    originalImage = await model.loadOriginalReviewImage(
      for: item,
      targetSize: item.source.kind == .photo
        ? CGSize(width: CGFloat(item.source.pixelWidth), height: CGFloat(item.source.pixelHeight))
        : CGSize(width: 2_400, height: 2_400)
    )
  }
}
#endif
