#if os(iOS) && PHOTOSLIM_UNIFIED_APP
import AVFoundation
import AVKit
import SwiftUI
import UIKit

@MainActor
struct PhotoSlimiOSSharedAuthorizationView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    ContentUnavailableView {
      Label("连接照片图库", systemImage: "photo.on.rectangle.angled")
    } description: {
      Text(description)
    } actions: {
      if model.accessState == .denied || model.accessState == .restricted {
        Button("打开系统设置") {
          guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
          openURL(url)
        }
        .buttonStyle(.borderedProminent)
        .tint(PhotoSlimiOSUnifiedTheme.signal)
      } else {
        Button("允许访问照片") {
          model.requestAccessAndScan()
        }
        .buttonStyle(.borderedProminent)
        .tint(PhotoSlimiOSUnifiedTheme.signal)
      }
    }
  }

  private var description: String {
    switch model.accessState {
    case .denied:
      return "照片访问已关闭。请在系统设置中允许 PhotoSlim 访问照片。"
    case .restricted:
      return "这台设备限制了照片访问。"
    case .limited:
      return "PhotoSlim 只能读取你允许的项目。"
    case .authorized:
      return ""
    case .notDetermined:
      return "允许访问后即可筛选照片和视频，并在本机生成压缩结果。"
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
          "队列为空",
          systemImage: "list.bullet.rectangle",
          description: Text("从图库选择项目并点击“下一步”，任务会在这里等待处理。")
        )
      } else {
        List {
          if let session = model.currentSession {
            Section("当前任务") {
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
                    Text("\(session.completedItemCount)/\(session.items.count) 个项目")
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
              Button("重新检查并开始") {
                model.retryStartingQueue()
              }
            }
          }

          Section("等待处理") {
            ForEach(model.queue) { task in
              VStack(alignment: .leading, spacing: 5) {
                Text("\(task.assets.count) 个项目")
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
    .navigationTitle("准备队列")
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
      parts.append("\(task.cloudAssetCount) 个 iCloud 项目")
    }
    if parts.isEmpty { parts.append("大小将在任务开始后确认") }
    return parts.joined(separator: " · ")
  }
}

@MainActor
struct PhotoSlimiOSStatisticsWorkspace: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    List {
      Section("已节省空间") {
        LabeledContent(
          "累计节省",
          value: MediaFormatting.bytes(model.statistics.savedBytes)
        )
        LabeledContent(
          "已处理项目",
          value: "\(model.statistics.committedItemCount)"
        )
        LabeledContent(
          "完成任务",
          value: "\(model.statistics.completedTaskCount)"
        )
        if let date = model.statistics.latestCompletionDate {
          LabeledContent("最近完成", value: MediaFormatting.date(date))
        }
      }

      Section("本机存储") {
        if let storage = model.localStorageReport {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text("已使用")
              Spacer()
              Text(
                "\(MediaFormatting.bytes(storage.usedBytes)) / \(MediaFormatting.bytes(storage.totalBytes))"
              )
              .foregroundStyle(.secondary)
            }
            ProgressView(value: storage.usedRatio)
              .tint(PhotoSlimiOSUnifiedTheme.signal)
            LabeledContent(
              "立即可用",
              value: MediaFormatting.bytes(storage.immediatelyAvailableBytes)
            )
            if storage.reclaimableBytes > 0 {
              LabeledContent(
                "系统可回收",
                value: MediaFormatting.bytes(storage.reclaimableBytes)
              )
            }
          }
          .padding(.vertical, 4)
        } else {
          Text(model.storageStatusError ?? "正在读取存储空间")
            .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("统计")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          model.refreshStorageStatus(enforceSelectionLimit: true, showNotice: false)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .accessibilityLabel("刷新存储空间")
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
          "还没有任务记录",
          systemImage: "clock.arrow.circlepath",
          description: Text("确认写入或撤回压缩结果后，任务会显示在这里。")
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
            Text("\(record.itemCount) 个项目 · \(record.failedCount) 个失败")
              .font(.caption)
              .foregroundStyle(.secondary)
            if record.outcome == .committed {
              Text("实际节省 \(MediaFormatting.bytes(max(0, record.originalBytes - record.outputBytes)))")
                .font(.caption.weight(.medium))
                .foregroundStyle(PhotoSlimiOSUnifiedTheme.success)
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .navigationTitle("任务历史")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func historyTitle(_ record: TaskHistoryRecord) -> String {
    switch record.outcome {
    case .committed: return "已写入相册"
    case .rolledBack: return "已撤回压缩结果"
    case .cancelled: return "任务已终止"
    case .failed: return "任务失败"
    default: return "任务结束"
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
                Text("\(session.completedItemCount)/\(session.items.count) 个项目")
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
      .navigationTitle("正在准备与压缩")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            model.minimizeTaskPanel()
          } label: {
            Image(systemName: "chevron.down")
          }
          .accessibilityLabel("收起任务")
        }

        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .destructive) {
            confirmsTermination = true
          } label: {
            Image(systemName: "stop.circle")
          }
          .accessibilityLabel("终止任务")
        }
      }
      .confirmationDialog(
        "终止当前任务？",
        isPresented: $confirmsTermination,
        titleVisibility: .visible
      ) {
        Button("终止并清理临时文件", role: .destructive) {
          model.terminateCurrentTask()
        }
        Button("继续任务", role: .cancel) {}
      } message: {
        Text("原件不会被修改，已经生成但尚未写入相册的临时文件会被删除。")
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
        progressLine("iCloud 下载", item.downloadProgress)
      }
      if item.state == .transcoding || item.compressionProgress > 0 {
        progressLine("压缩", item.compressionProgress)
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
            model.currentSession?.statusMessage ?? "任务没有完成",
            systemImage: "exclamationmark.triangle"
          )
        }

        if let items = model.currentSession?.items.filter({ $0.state == .failed }) {
          Section("失败项目") {
            ForEach(items) { item in
              VStack(alignment: .leading, spacing: 4) {
                Text(item.source.displayTitle)
                  .font(.body.weight(.semibold))
                Text(item.errorMessage ?? "处理失败")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        Section {
          Button("重试失败项目") { model.retryFailedSession() }
            .foregroundStyle(PhotoSlimiOSUnifiedTheme.signal)
          Button("结束任务", role: .destructive) { model.finishFailedSession() }
        }
      }
      .navigationTitle("任务未完成")
      .navigationBarTitleDisplayMode(.inline)
    }
    .background(Color(.systemBackground).ignoresSafeArea())
  }
}

@MainActor
struct PhotoSlimiOSSharedReviewWorkspace: View {
  @EnvironmentObject private var model: AppModel
  private let columns = [
    GridItem(.flexible(minimum: 130), spacing: 10),
    GridItem(.flexible(minimum: 130), spacing: 10),
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        if let session = model.currentSession {
          VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
              Text("压缩结果已准备好")
                .font(.title3.weight(.semibold))
              Text("点按结果放大；按住图片临时查看原图。原件尚未修改。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              if session.verifiedSavedBytes > 0 {
                Text("实际节省 \(MediaFormatting.bytes(session.verifiedSavedBytes))")
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
                Text("\(failedItems.count) 个项目未生成结果")
                  .font(.headline)
                ForEach(failedItems) { item in
                  Text("\(item.source.displayTitle)：\(item.errorMessage ?? "处理失败")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .padding(16)
            }
          }
          .padding(.top, 12)
          .padding(.bottom, 104)
        }
      }
      .background(PhotoSlimiOSUnifiedTheme.canvas)
      .navigationTitle("检查压缩结果")
      .navigationBarTitleDisplayMode(.inline)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        reviewActions
      }
    }
    .background(Color(.systemBackground).ignoresSafeArea())
  }

  private var reviewActions: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("确认结果后再写入相册")
        .font(.subheadline.weight(.semibold))

      HStack(spacing: 10) {
        Button("撤回压缩副本") {
          model.rollbackCompressedCopies()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)

        Button("写入相册并删除原件") {
          model.commitAndDeleteOriginals()
        }
        .buttonStyle(.borderedProminent)
        .tint(PhotoSlimiOSUnifiedTheme.signal)
        .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.bar)
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
            Text(isPressing && originalImage != nil ? "原图" : "压缩结果")
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
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            isPressing = true
            loadOriginalIfNeeded()
          }
          .onEnded { _ in
            isPressing = false
          }
      )

      Text(item.source.displayTitle)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      if let saved = savedBytes, saved > 0 {
        Text("实际节省 \(MediaFormatting.bytes(saved))")
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
    .accessibilityLabel("\(item.source.displayTitle)，压缩结果")
    .accessibilityHint("点按放大，按住查看原图")
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

  func load(url: URL, kind: MediaKind) {
    loadTask?.cancel()
    loadTask = Task {
      if kind == .photo {
        image = UIImage(contentsOfFile: url.path)
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
            if let cgImage { self.image = UIImage(cgImage: cgImage) }
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
  @State private var originalImage: UIImage?
  @State private var isShowingOriginal = false
  @State private var scale = 1.0
  @State private var lastScale = 1.0

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
  }

  var body: some View {
    NavigationStack {
      Group {
        if item.source.kind == .video, !isShowingOriginal {
          VideoPlayer(player: AVPlayer(url: outputURL))
            .background(Color.black)
        } else if let image = isShowingOriginal ? originalImage : outputImage {
          ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image)
              .resizable()
              .scaledToFit()
              .scaleEffect(scale)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .gesture(
                MagnifyGesture()
                  .onChanged { value in
                    scale = min(6, max(1, lastScale * value.magnification))
                  }
                  .onEnded { _ in lastScale = scale }
              )
          }
          .background(Color.black)
        } else {
          ProgressView()
            .task { await loadOriginal() }
        }
      }
      .navigationTitle(item.source.displayTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("完成") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(isShowingOriginal ? "压缩结果" : "原图") {
            Task {
              if originalImage == nil { await loadOriginal() }
              isShowingOriginal.toggle()
              scale = 1
              lastScale = 1
            }
          }
        }
      }
    }
  }

  private func loadOriginal() async {
    guard originalImage == nil else { return }
    originalImage = await model.loadOriginalReviewImage(
      for: item,
      targetSize: CGSize(width: 2_400, height: 2_400)
    )
  }
}
#endif
