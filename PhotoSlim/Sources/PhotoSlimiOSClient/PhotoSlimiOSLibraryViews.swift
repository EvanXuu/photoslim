#if os(iOS) && PHOTOSLIM_UNIFIED_APP
import Photos
import SwiftUI
import UIKit

enum PhotoSlimiOSUnifiedTheme {
  static let signal = Color(red: 0.78, green: 0.32, blue: 0.04)
  static let signalSoft = Color(red: 0.78, green: 0.32, blue: 0.04).opacity(0.12)
  static let success = Color(red: 0.14, green: 0.55, blue: 0.30)
  static let danger = Color(red: 0.74, green: 0.18, blue: 0.16)
  static let canvas = Color(.systemGroupedBackground)
  static let thumbnail = Color(.secondarySystemGroupedBackground)
}

@MainActor
struct PhotoSlimiOSLibraryWorkspace: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsFilters = false
  @State private var showsSettings = false

  var body: some View {
    Group {
      if model.accessState.canRead {
        libraryContent
      } else {
        PhotoSlimiOSSharedAuthorizationView()
      }
    }
    .background(PhotoSlimiOSUnifiedTheme.canvas)
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        mediaMenu
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button {
          showsFilters = true
        } label: {
          Image(
            systemName: activeFilterCount > 0
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle"
          )
        }
        .accessibilityLabel(
          activeFilterCount > 0 ? "筛选，已启用 \(activeFilterCount) 项" : "筛选"
        )

        moreMenu
      }
    }
    .sheet(isPresented: $showsFilters) {
      PhotoSlimiOSFilterSheet()
        .environmentObject(model)
    }
    .sheet(isPresented: $showsSettings) {
      PhotoSlimiOSCompressionSettingsSheet(
        current: model.settings,
        mediaKind: model.destination.mediaKind
      ) { value in
        model.applyCompressionSettings(value)
      }
      .environmentObject(model)
    }
    .onChange(of: model.filter.layoutMode) { _, _ in model.savePreferences() }
    .onChange(of: model.filter.sortOption) { _, _ in model.savePreferences() }
    .onDisappear { model.savePreferences() }
  }

  private var libraryContent: some View {
    VStack(spacing: 0) {
      if model.isScanning {
        PhotoSlimiOSScanProgressStrip()
      }

      Group {
        if model.isLoadingLibraryIndex {
          PhotoSlimiOSLibraryLoadingState()
        } else if model.visibleAssets.isEmpty {
          PhotoSlimiOSEmptyLibraryState(isScanning: model.isScanning)
        } else if model.filter.layoutMode == .grid {
          PhotoSlimiOSSharedAssetGrid(assets: model.visibleAssets)
        } else {
          PhotoSlimiOSSharedAssetList(assets: model.visibleAssets)
        }
      }
    }
  }

  private var mediaMenu: some View {
    Menu {
      Button {
        model.destination = .library
      } label: {
        mediaMenuLabel(for: .library)
      }
      Button {
        model.destination = .photos
      } label: {
        mediaMenuLabel(for: .photos)
      }
      Button {
        model.destination = .videos
      } label: {
        mediaMenuLabel(for: .videos)
      }
      Button {
        model.destination = .favorites
      } label: {
        mediaMenuLabel(for: .favorites)
      }
    } label: {
      Image(systemName: model.destination.symbol)
        .frame(width: 30, height: 30)
    }
    .accessibilityLabel("媒体类型：\(navigationTitle)")
  }

  private var moreMenu: some View {
    Menu {
      Menu("排序") {
        ForEach(SortOption.allCases.filter(\.isVisible)) { option in
          Button {
            model.filter.sortOption = option
            model.savePreferences()
          } label: {
            if model.filter.sortOption == option {
              Label(option.title, systemImage: "checkmark")
            } else {
              Text(option.title)
            }
          }
        }
      }

      Menu("显示方式") {
        Button {
          model.filter.layoutMode = .grid
        } label: {
          Label("网格", systemImage: model.filter.layoutMode == .grid ? "checkmark" : "square.grid.2x2")
        }
        Button {
          model.filter.layoutMode = .list
        } label: {
          Label("列表", systemImage: model.filter.layoutMode == .list ? "checkmark" : "list.bullet")
        }
      }

      Divider()

      Button {
        model.selectAllVisible()
      } label: {
        Label(
          model.allVisibleItemsSelected ? "取消全选" : "全选",
          systemImage: model.allVisibleItemsSelected ? "xmark.circle" : "checkmark.circle"
        )
      }

      Button {
        showsSettings = true
      } label: {
        Label("压缩参数", systemImage: "slider.horizontal.3")
      }

      Divider()

      Button {
        model.scanLibrary()
      } label: {
        Label("扫描图库变更", systemImage: "arrow.clockwise")
      }
      .disabled(model.isScanning || model.isLoadingLibraryIndex)

      Button {
        model.refreshStorageStatus()
      } label: {
        Label("刷新存储空间", systemImage: "internaldrive")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .frame(width: 30, height: 30)
    }
    .accessibilityLabel("更多")
  }

  @ViewBuilder
  private func mediaMenuLabel(for destination: SidebarDestination) -> some View {
    if model.destination == destination {
      Label(destination.title, systemImage: "checkmark")
    } else {
      Label(destination.title, systemImage: destination.symbol)
    }
  }

  private var navigationTitle: String {
    switch model.destination {
    case .library: return "照片图库"
    case .photos: return "照片"
    case .videos: return "视频"
    case .favorites: return "收藏"
    case .queue, .statistics, .history: return "照片图库"
    }
  }

  private var activeFilterCount: Int {
    var count = 0
    if model.filter.favoritesOnly { count += 1 }
    if model.filter.timeFilter != .all { count += 1 }
    if model.filter.sizeFilter != .all { count += 1 }
    if model.filter.cloudFilter != .all { count += 1 }
    if model.filter.excludedReasons != ExclusionReason.defaultExcluded { count += 1 }
    return count
  }
}

@MainActor
private struct PhotoSlimiOSScanProgressStrip: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 10) {
      ProgressView(
        value: Double(model.scanCompleted),
        total: Double(max(model.scanTotal, 1))
      )
      .tint(PhotoSlimiOSUnifiedTheme.signal)

      Text(
        model.scanTotal > 0
          ? "\(model.scanCompleted)/\(model.scanTotal)"
          : "扫描中"
      )
      .font(.caption.monospacedDigit())
      .foregroundStyle(.secondary)

      Button("停止") { model.cancelScan() }
        .font(.caption.weight(.semibold))
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 38)
    .background(PhotoSlimiOSUnifiedTheme.signalSoft)
    .accessibilityElement(children: .combine)
  }
}

private struct PhotoSlimiOSLibraryLoadingState: View {
  var body: some View {
    ContentUnavailableView {
      Label("正在读取图库", systemImage: "photo.stack")
    }
    .overlay(alignment: .top) {
      ProgressView()
        .padding(.top, 70)
    }
  }
}

private struct PhotoSlimiOSEmptyLibraryState: View {
  let isScanning: Bool

  var body: some View {
    ContentUnavailableView {
      Label(
        isScanning ? "正在扫描图库" : "没有符合条件的项目",
        systemImage: isScanning ? "photo.stack" : "line.3.horizontal.decrease.circle"
      )
    } description: {
      Text(isScanning ? "项目会在扫描完成后显示。" : "下拉可以搜索，也可以调整右上角的筛选条件。")
    }
  }
}

@MainActor
private struct PhotoSlimiOSSharedAssetGrid: View {
  @EnvironmentObject private var model: AppModel
  @State private var positionedBelowSearch = false
  let assets: [MediaAsset]
  private let columns = [
    GridItem(.flexible(minimum: 120), spacing: 10),
    GridItem(.flexible(minimum: 120), spacing: 10),
  ]

  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          PhotoSlimiOSPullDownSearchField()

          Color.clear
            .frame(height: 1)
            .id(PhotoSlimiOSLibraryScrollAnchor.content)

          LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            ForEach(assets) { asset in
              PhotoSlimiOSSharedAssetGridTile(
                asset: asset,
                selected: model.selectedIdentifiers.contains(asset.id)
              ) {
                model.toggleSelection(asset)
              }
              .contextMenu {
                Button {
                  model.togglePinned(asset)
                } label: {
                  Label(
                    asset.isPinned ? "取消置顶" : "置顶",
                    systemImage: asset.isPinned ? "pin.slash" : "pin"
                  )
                }
              }
            }
          }
          .padding(.horizontal, 12)
          .padding(.top, 9)
          .padding(.bottom, 24)
          .frame(minHeight: geometry.size.height, alignment: .top)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { model.scanLibrary() }
        .onAppear {
          guard !positionedBelowSearch else { return }
          positionedBelowSearch = true
          DispatchQueue.main.async {
            proxy.scrollTo(
              assets.first?.id ?? PhotoSlimiOSLibraryScrollAnchor.content,
              anchor: .top
            )
          }
        }
      }
    }
  }
}

@MainActor
private struct PhotoSlimiOSSharedAssetList: View {
  @EnvironmentObject private var model: AppModel
  @State private var positionedBelowSearch = false
  let assets: [MediaAsset]

  var body: some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          PhotoSlimiOSPullDownSearchField()

          Color.clear
            .frame(height: 1)
            .id(PhotoSlimiOSLibraryScrollAnchor.content)

          LazyVStack(spacing: 0) {
            ForEach(assets) { asset in
              PhotoSlimiOSSharedAssetRow(
                asset: asset,
                selected: model.selectedIdentifiers.contains(asset.id)
              ) {
                model.toggleSelection(asset)
              }
              .contextMenu {
                Button {
                  model.togglePinned(asset)
                } label: {
                  Label(
                    asset.isPinned ? "取消置顶" : "置顶",
                    systemImage: asset.isPinned ? "pin.slash" : "pin"
                  )
                }
              }

              Divider()
                .padding(.leading, 100)
            }
          }
          .padding(.bottom, 20)
          .frame(minHeight: geometry.size.height, alignment: .top)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { model.scanLibrary() }
        .onAppear {
          guard !positionedBelowSearch else { return }
          positionedBelowSearch = true
          DispatchQueue.main.async {
            proxy.scrollTo(
              assets.first?.id ?? PhotoSlimiOSLibraryScrollAnchor.content,
              anchor: .top
            )
          }
        }
      }
    }
  }
}

private enum PhotoSlimiOSLibraryScrollAnchor {
  static let content = "photoslim-library-content"
}

@MainActor
private struct PhotoSlimiOSPullDownSearchField: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("搜索文件名", text: $model.filter.searchText)
        .focused($isFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)

      if !model.filter.searchText.isEmpty {
        Button {
          model.filter.searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("清除搜索")
      }
    }
    .padding(.horizontal, 13)
    .frame(height: 38)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
  }
}

private struct PhotoSlimiOSSharedAssetGridTile: View {
  let asset: MediaAsset
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        ZStack(alignment: .topTrailing) {
          PhotoSlimiOSSharedThumbnail(asset: asset, targetSize: CGSize(width: 420, height: 320))
            .aspectRatio(4 / 3, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(PhotoSlimiOSUnifiedTheme.thumbnail)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

          if selected {
            Image(systemName: "checkmark.circle.fill")
              .font(.title3)
              .symbolRenderingMode(.palette)
              .foregroundStyle(.white, PhotoSlimiOSUnifiedTheme.signal)
              .padding(8)
          } else if asset.isPinned {
            Image(systemName: "pin.fill")
              .font(.caption)
              .padding(7)
              .background(.thinMaterial, in: Circle())
              .padding(7)
          }
        }

        Text(asset.displayTitle)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)

        Text(assetMetadata(asset))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(assetAccessibilityDescription(asset))
    .accessibilityValue(selected ? "已选择" : "未选择")
  }
}

private struct PhotoSlimiOSSharedAssetRow: View {
  let asset: MediaAsset
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        PhotoSlimiOSSharedThumbnail(asset: asset, targetSize: CGSize(width: 220, height: 160))
          .frame(width: 76, height: 62)
          .background(PhotoSlimiOSUnifiedTheme.thumbnail)
          .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 6) {
            Text(asset.displayTitle)
              .font(.body.weight(.semibold))
              .lineLimit(1)
            if asset.isPinned {
              Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(PhotoSlimiOSUnifiedTheme.signal)
            }
          }

          Text(assetMetadata(asset))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

          if !asset.canProcess {
            Text(asset.exclusionReasons.first(where: \.isHardBlock)?.title ?? "暂不可处理")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 4)

        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(selected ? PhotoSlimiOSUnifiedTheme.signal : Color.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .frame(minHeight: 80)
      .background(selected ? PhotoSlimiOSUnifiedTheme.signalSoft : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(assetAccessibilityDescription(asset))
    .accessibilityValue(selected ? "已选择" : "未选择")
  }
}

@MainActor
private struct PhotoSlimiOSSharedThumbnail: View {
  let asset: MediaAsset
  let targetSize: CGSize
  @StateObject private var loader = ThumbnailLoader()

  var body: some View {
    ZStack {
      if let image = loader.image {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
      } else {
        Image(
          systemName: asset.isCloudOnly
            ? "icloud"
            : (asset.kind == .video ? "video" : "photo")
        )
        .font(.title2)
        .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .task(id: asset.id) {
      loader.load(identifier: asset.id, targetSize: targetSize)
    }
    .onDisappear { loader.cancel() }
  }
}

private func assetMetadata(_ asset: MediaAsset) -> String {
  var parts = [asset.format.title]
  if asset.pixelWidth > 0, asset.pixelHeight > 0 {
    parts.append("\(asset.pixelWidth) × \(asset.pixelHeight)")
  }
  if asset.kind == .video, asset.duration > 0 {
    parts.append(MediaFormatting.duration(asset.duration))
  }
  if let bytes = MediaFormatting.inputBytes(for: asset) {
    parts.append(bytes)
  }
  if asset.isCloudOnly { parts.append("iCloud") }
  return parts.joined(separator: " · ")
}

private func assetAccessibilityDescription(_ asset: MediaAsset) -> String {
  "\(asset.displayTitle)，\(asset.kind.title)，\(assetMetadata(asset))"
}

@MainActor
struct PhotoSlimiOSBottomStatusBar: View {
  @EnvironmentObject private var model: AppModel
  @Binding var showsSettings: Bool
  let startAction: () -> Void

  var body: some View {
    Group {
      if !model.selectedIdentifiers.isEmpty {
        selectionContent
      } else if model.isProcessing, let session = model.currentSession {
        processingContent(session)
      }
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 58)
  }

  private var selectionContent: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("已选 \(model.selectedIdentifiers.count) 项")
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
        Text(storageSummary)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }

      Spacer(minLength: 0)

      Button {
        showsSettings = true
      } label: {
        Label("参数", systemImage: "slider.horizontal.3")
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 12)
          .frame(minHeight: 44)
          .background(
            Color.secondary.opacity(0.14),
            in: Capsule()
          )
      }
      .buttonStyle(.plain)
      .accessibilityHint(model.settings.summary(for: selectedMediaKind))

      Button(action: startAction) {
        Text(model.currentSession?.phase.blocksNewTask == true ? "入队" : "下一步")
          .font(.subheadline.weight(.semibold))
          .padding(.horizontal, 6)
          .frame(minHeight: 44)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .tint(PhotoSlimiOSUnifiedTheme.signal)
    }
  }

  private func processingContent(_ session: CompressionSession) -> some View {
    HStack(spacing: 10) {
      ProgressView(value: session.progress)
        .tint(PhotoSlimiOSUnifiedTheme.signal)
        .frame(width: 44)

      VStack(alignment: .leading, spacing: 2) {
        Text("正在处理 \(session.completedItemCount)/\(session.items.count)")
          .font(.caption.weight(.semibold))
        Text(session.statusMessage)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 0)

      Button("查看") { model.restoreTaskPanel() }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
    }
  }

  private var selectedMediaKind: MediaKind? {
    let kinds = Set(model.selectedAssets.map(\.kind))
    return kinds.count == 1 ? kinds.first : nil
  }

  private var storageSummary: String {
    if let storage = model.localStorageReport {
      return "\(MediaFormatting.bytes(storage.availableBytes)) 可用 · 共 \(MediaFormatting.bytes(storage.totalBytes))"
    }
    return model.storageStatusError == nil ? "正在读取存储空间" : "存储空间暂不可用"
  }
}

@MainActor
struct PhotoSlimiOSFilterSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel
  @State private var warningReason: ExclusionReason?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle("仅显示收藏", isOn: $model.filter.favoritesOnly)
        }

        Section("时间") {
          Picker("拍摄时间", selection: $model.filter.timeFilter) {
            ForEach(TimeFilter.allCases) { value in
              Text(value.title).tag(value)
            }
          }

          if model.filter.timeFilter == .customOlderThan {
            Stepper(
              "\(model.filter.customMinimumAgeYears ?? 10) 年以上",
              value: Binding(
                get: { model.filter.customMinimumAgeYears ?? 10 },
                set: { model.filter.customMinimumAgeYears = $0 }
              ),
              in: 1...100
            )
          } else if model.filter.timeFilter == .custom {
            DatePicker(
              "开始日期",
              selection: Binding(
                get: { model.filter.customStartDate ?? .distantPast },
                set: { model.filter.customStartDate = $0 }
              ),
              displayedComponents: .date
            )
            DatePicker(
              "结束日期",
              selection: Binding(
                get: { model.filter.customEndDate ?? Date() },
                set: { model.filter.customEndDate = $0 }
              ),
              displayedComponents: .date
            )
          }
        }

        Section("大小") {
          Picker("原件大小", selection: $model.filter.sizeFilter) {
            ForEach(SizeFilter.pickerCases) { value in
              Text(value.title).tag(value)
            }
          }

          if model.filter.sizeFilter == .customMinimum {
            TextField("MB", value: minimumMegabytes, format: .number)
              .keyboardType(.numberPad)
          } else if model.filter.sizeFilter == .custom {
            TextField("最小 MB", value: minimumMegabytes, format: .number)
              .keyboardType(.numberPad)
            TextField("最大 MB", value: maximumMegabytes, format: .number)
              .keyboardType(.numberPad)
          }
        }

        Section("位置") {
          Picker("原件位置", selection: $model.filter.cloudFilter) {
            ForEach(CloudFilter.allCases) { value in
              Text(value.title).tag(value)
            }
          }
        }

        Section {
          DisclosureGroup("排除项目") {
            ForEach(ExclusionReason.allCases.filter { $0 != .lowSavings }) { reason in
              Toggle(
                reason.title,
                isOn: Binding(
                  get: { model.filter.excludedReasons.contains(reason) },
                  set: { excluded in
                    if excluded {
                      model.requestExclusionChange(reason, excluded: true)
                    } else {
                      warningReason = reason
                    }
                  }
                )
              )
            }
          }
        } footer: {
          Text("取消排除后，相关项目会出现在图库中，但受保护的格式仍不能加入任务。")
        }

        Section {
          Button("恢复默认筛选", role: .destructive) {
            let searchText = model.filter.searchText
            let layoutMode = model.filter.layoutMode
            let sortOption = model.filter.sortOption
            model.filter = BrowserFilter()
            model.filter.searchText = searchText
            model.filter.layoutMode = layoutMode
            model.filter.sortOption = sortOption
          }
        }
      }
      .navigationTitle("筛选")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") {
            model.savePreferences()
            dismiss()
          }
        }
      }
      .alert(item: $warningReason) { reason in
        Alert(
          title: Text("显示“\(reason.title)”？"),
          message: Text(reason.warning),
          primaryButton: .destructive(Text("仍要显示")) {
            model.filter.excludedReasons.remove(reason)
            model.savePreferences()
          },
          secondaryButton: .cancel()
        )
      }
    }
  }

  private var minimumMegabytes: Binding<Int> {
    Binding(
      get: { Int((model.filter.customMinimumBytes ?? 0) / 1_000_000) },
      set: { model.filter.customMinimumBytes = Int64(max(0, $0)) * 1_000_000 }
    )
  }

  private var maximumMegabytes: Binding<Int> {
    Binding(
      get: { Int((model.filter.customMaximumBytes ?? 0) / 1_000_000) },
      set: { model.filter.customMaximumBytes = Int64(max(0, $0)) * 1_000_000 }
    )
  }
}

@MainActor
struct PhotoSlimiOSCompressionSettingsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: CompressionSettings
  let mediaKind: MediaKind?
  let onSave: (CompressionSettings) -> Void

  init(
    current: CompressionSettings,
    mediaKind: MediaKind?,
    onSave: @escaping (CompressionSettings) -> Void
  ) {
    _draft = State(initialValue: current)
    self.mediaKind = mediaKind
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        if mediaKind != .video {
          Section("照片") {
            HStack {
              Text("HEIC 质量")
              Slider(value: $draft.photoQuality, in: 0.5...1, step: 0.01)
              Text("\(Int((draft.photoQuality * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
        }

        if mediaKind != .photo {
          Section {
            Picker("编码方式", selection: $draft.videoEncodingMode) {
              ForEach(VideoEncodingMode.allCases) { mode in
                Text(mode.title).tag(mode)
              }
            }
            .pickerStyle(.segmented)

            if draft.videoEncodingMode == .manual {
              bitrateEditor
              Toggle("允许帧重排", isOn: $draft.videoAllowFrameReordering)
              Picker("音频", selection: $draft.audioPolicy) {
                ForEach(AudioPolicy.allCases) { policy in
                  Text(policy.title).tag(policy)
                }
              }
            }
          } header: {
            Text("视频")
          } footer: {
            if draft.videoEncodingMode == .manual {
              Text("非标准分辨率会按像素数量和帧率从这些数值计算目标码率。")
            }
          }
        }

        Section {
          HStack {
            Text("最低实际节省")
            Slider(value: $draft.minimumSavingsRatio, in: 0...0.5, step: 0.01)
            Text("\(Int((draft.minimumSavingsRatio * 100).rounded()))%")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("任务安全")
        } footer: {
          Text("结果未达到这个比例时会被丢弃，不会写入照片图库。")
        }
      }
      .navigationTitle("压缩参数")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            onSave(draft)
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
    }
  }

  private var bitrateEditor: some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
      GridRow {
        Text("分辨率")
          .font(.caption.weight(.semibold))
        Text("30 fps")
          .font(.caption.weight(.semibold))
        Text("60 fps")
          .font(.caption.weight(.semibold))
      }

      ForEach(VideoResolutionTier.allCases) { resolution in
        GridRow {
          Text(resolution.title)
          bitrateField(resolution, .fps30)
          bitrateField(resolution, .fps60)
        }
      }
    }
  }

  private func bitrateField(
    _ resolution: VideoResolutionTier,
    _ frameRate: VideoFrameRateTier
  ) -> some View {
    TextField(
      "Mbps",
      value: Binding(
        get: { draft.manualVideoBitrates.value(for: resolution, frameRate: frameRate) },
        set: { draft.manualVideoBitrates.setValue($0, for: resolution, frameRate: frameRate) }
      ),
      format: .number.precision(.fractionLength(0...1))
    )
    .keyboardType(.decimalPad)
    .multilineTextAlignment(.trailing)
    .textFieldStyle(.roundedBorder)
    .frame(minWidth: 74)
  }
}
#endif
