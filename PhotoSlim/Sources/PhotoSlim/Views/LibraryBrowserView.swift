import SwiftUI

struct LibraryBrowserView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsFilters = false
  @State private var showsSettings = false

  var body: some View {
    VStack(spacing: 0) {
      if model.isScanning {
        ScanProgressStrip()
      }

      Group {
        if model.isLoadingLibraryIndex {
          libraryIndexLoadingState
        } else if model.visibleAssets.isEmpty {
          emptyState
        } else if model.filter.layoutMode == .grid {
          AssetGridView(assets: model.visibleAssets)
        } else {
          AssetListView(assets: model.visibleAssets)
        }
      }
    }
    .background(PhotoSlimTheme.canvas)
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        Button {
          showsFilters.toggle()
        } label: {
          Image(
            systemName: activeFilterCount > 0
              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
          )
        }
        .help(activeFilterCount > 0 ? "筛选（已启用 \(activeFilterCount) 项）" : "筛选")
        .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
          FilterPopoverView()
            .environmentObject(model)
        }

        Menu {
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
        } label: {
          Image(systemName: "arrow.up.arrow.down")
        }
        .help("排序：\(model.filter.sortOption.title)")

        Picker("视图", selection: $model.filter.layoutMode) {
          Image(systemName: "square.grid.2x2").tag(BrowserLayoutMode.grid)
          Image(systemName: "list.bullet").tag(BrowserLayoutMode.list)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 72)
        .help("切换列表或网格")

        Button {
          model.selectAllVisible()
        } label: {
          Label(
            model.allVisibleItemsSelected ? "取消全选" : "全选",
            systemImage: model.allVisibleItemsSelected ? "checkmark.circle" : "checkmark.circle"
          )
        }
        .disabled(model.visibleAssets.allSatisfy { !$0.canProcess })

        Button {
          model.scanLibrary()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("扫描图库变更")
        .disabled(model.isScanning || model.isLoadingLibraryIndex)
      }
    }
    .searchable(text: $model.filter.searchText, placement: .toolbar, prompt: "搜索文件名")
    .onChange(of: model.filter.layoutMode) { model.savePreferences() }
    .onDisappear { model.savePreferences() }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SelectionBar(showsSettings: $showsSettings)
    }
    .sheet(isPresented: $showsSettings) {
      CompressionSettingsView(current: model.settings, mediaKind: model.destination.mediaKind) { value in
        model.applyCompressionSettings(value)
      }
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

  private var emptyState: some View {
    VStack(spacing: 13) {
      Image(systemName: model.isScanning ? "photo.stack" : "line.3.horizontal.decrease.circle")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(.secondary)
      Text(model.isScanning ? "正在扫描图库" : "当前筛选下没有项目")
        .font(.system(size: 16, weight: .semibold))
      Text(model.isScanning ? "请稍候。" : "可以调整筛选条件后再试。")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var libraryIndexLoadingState: some View {
    VStack(spacing: 13) {
      ProgressView()
        .controlSize(.small)
      Text("正在恢复已扫描的图库")
        .font(.system(size: 16, weight: .semibold))
      Text("已有数据会在恢复完成后显示，随后只检查图库变更。")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ScanProgressStrip: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    HStack(spacing: 10) {
      ProgressView(value: Double(model.scanCompleted), total: Double(max(model.scanTotal, 1)))
        .progressViewStyle(.linear)
        .frame(maxWidth: 210)
        .tint(PhotoSlimTheme.signal)
      Text(model.scanTotal > 0 ? "正在扫描 \(model.scanCompleted)/\(model.scanTotal)" : "正在扫描图库")
        .font(.system(size: 11, weight: .medium))
      Text(model.scanFilename)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer()
      Button("停止") { model.cancelScan() }
        .font(.system(size: 11))
    }
    .padding(.horizontal, 20)
    .frame(height: 34)
    .background(PhotoSlimTheme.signalSoft)
  }
}

private struct SelectionBar: View {
  @EnvironmentObject private var model: AppModel
  @Binding var showsSettings: Bool

  var body: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(
          model.selectedIdentifiers.isEmpty
            ? "选择要压缩的项目" : "已选择 \(model.selectedIdentifiers.count) 个项目"
        )
        .font(.system(size: 13, weight: .semibold))
        Text(storageSummary)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 3) {
        HStack(spacing: 7) {
          Text("推荐参数")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(PhotoSlimTheme.signal)
          Button("编辑") { showsSettings = true }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        Text(model.settings.summary(for: model.destination.mediaKind))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }

      if !model.selectedIdentifiers.isEmpty {
        Button("清除") { model.clearSelection() }
      }
      Button(model.currentSession?.phase.blocksNewTask == true ? "加入准备队列" : "开始压缩") {
        model.beginSelectedTask()
      }
      .buttonStyle(SignalButtonStyle())
      .disabled(model.selectedIdentifiers.isEmpty)
    }
    .padding(.horizontal, 20)
    .frame(minHeight: 72)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }

  private var storageSummary: String {
    if let storage = model.localStorageReport {
      return "\(MediaFormatting.bytes(storage.availableBytes)) 可用 · 共 \(MediaFormatting.bytes(storage.totalBytes))"
    }
    return model.storageStatusError == nil ? "正在读取存储空间" : "存储空间暂不可用"
  }
}

private struct AssetGridView: View {
  @EnvironmentObject private var model: AppModel
  let assets: [MediaAsset]
  private let columns = [GridItem(.adaptive(minimum: 174, maximum: 230), spacing: 12)]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
        ForEach(assets) { asset in
          AssetCard(asset: asset, selected: model.selectedIdentifiers.contains(asset.id)) {
            model.toggleSelection(asset)
          }
        }
      }
      .padding(20)
    }
  }
}

private struct AssetCard: View {
  @EnvironmentObject private var model: AppModel
  let asset: MediaAsset
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        ZStack(alignment: .topLeading) {
          AssetThumbnailView(asset: asset)
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(
              selected ? PhotoSlimTheme.signalForeground : Color.white,
              selected ? PhotoSlimTheme.signal : Color.black.opacity(0.38)
            )
            .shadow(radius: 2, y: 1)
            .padding(8)

          HStack(spacing: 5) {
            if asset.originalAvailability != .local {
              Image(systemName: asset.originalAvailability.symbolName)
            }
            if asset.kind == .video { Text(MediaFormatting.duration(asset.duration)) }
          }
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(.black.opacity(0.62))
          .clipShape(Capsule())
          .padding(7)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 5) {
            Text(asset.displayTitle)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(PhotoSlimTheme.ink)
              .lineLimit(1)
            Spacer(minLength: 2)
            if asset.isPinned {
              Image(systemName: "pin.fill")
                .foregroundStyle(PhotoSlimTheme.signal)
                .help("已置顶")
            }
            Text(asset.format.title)
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(.secondary)
            if asset.isPlainHVC1 {
              Text("再次压缩")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(PhotoSlimTheme.warning)
            }
          }
          if let sizeSummary = sizeSummary(for: asset) {
            Text(sizeSummary)
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.secondary)
          }
          Text(MediaFormatting.date(asset.creationDate))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      .padding(8)
      .background(selected ? PhotoSlimTheme.signalSoft : PhotoSlimTheme.surface)
      .clipShape(RoundedRectangle(cornerRadius: PhotoSlimTheme.cardRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: PhotoSlimTheme.cardRadius, style: .continuous)
          .stroke(
            selected ? PhotoSlimTheme.signal : PhotoSlimTheme.hairline,
            lineWidth: selected ? 1.5 : 1)
      }
      .opacity(asset.canProcess ? 1 : 0.64)
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button {
        model.togglePinned(asset)
      } label: {
        Label(asset.isPinned ? "取消置顶" : "置顶", systemImage: asset.isPinned ? "pin.slash" : "pin")
      }
      Button {
        action()
      } label: {
        Label(selected ? "取消选择" : "选择", systemImage: selected ? "checkmark.circle" : "circle")
      }
    }
    .accessibilityLabel(
      accessibilityLabelText
    )
    .accessibilityValue(selected ? "已选择" : (asset.canProcess ? "未选择" : "不可处理"))
  }

  private var accessibilityLabelText: String {
    var parts = [asset.displayTitle, asset.format.title]
    if let inputBytes = MediaFormatting.inputBytes(for: asset) {
      parts.append(inputBytes)
    }
    return parts.joined(separator: "，")
  }

  private func sizeSummary(for asset: MediaAsset) -> String? {
    MediaFormatting.inputBytes(for: asset)
  }
}

private struct AssetListView: View {
  @EnvironmentObject private var model: AppModel
  let assets: [MediaAsset]

  var body: some View {
    ScrollView {
      LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
        Section {
          ForEach(assets) { asset in
            AssetListRow(asset: asset, selected: model.selectedIdentifiers.contains(asset.id)) {
              model.toggleSelection(asset)
            }
            Divider().padding(.leading, 72)
          }
        } header: {
          HStack(spacing: 12) {
            Text("项目").frame(maxWidth: .infinity, alignment: .leading)
            Text("格式").frame(width: 70, alignment: .leading)
            Text("拍摄日期").frame(width: 100, alignment: .leading)
            Text("文件大小").frame(width: 90, alignment: .trailing)
          }
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 20)
          .frame(height: 30)
          .background(.bar)
        }
      }
    }
  }
}

private struct AssetListRow: View {
  @EnvironmentObject private var model: AppModel
  let asset: MediaAsset
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? PhotoSlimTheme.signal : .secondary)
          .font(.system(size: 16, weight: .medium))
        AssetThumbnailView(asset: asset)
          .frame(width: 44, height: 44)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 5) {
            Text(asset.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if asset.isPinned {
              Image(systemName: "pin.fill")
                .foregroundStyle(PhotoSlimTheme.signal)
                .help("已置顶")
            }
          }
          Text(
            asset.dimensionsLabel
              + (asset.kind == .video ? " · " + MediaFormatting.duration(asset.duration) : "")
            + (asset.isPlainHVC1 ? " · 再次压缩" : "")
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(asset.format.title).frame(width: 70, alignment: .leading)
        Text(MediaFormatting.date(asset.creationDate)).frame(width: 100, alignment: .leading)
        Text(MediaFormatting.inputBytes(for: asset) ?? "")
          .frame(width: 90, alignment: .trailing)
      }
      .font(.system(size: 11))
      .padding(.horizontal, 20)
      .frame(height: 58)
      .contentShape(Rectangle())
      .background(selected ? PhotoSlimTheme.signalSoft : Color.clear)
      .opacity(asset.canProcess ? 1 : 0.58)
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button {
        model.togglePinned(asset)
      } label: {
        Label(asset.isPinned ? "取消置顶" : "置顶", systemImage: asset.isPinned ? "pin.slash" : "pin")
      }
      Button {
        action()
      } label: {
        Label(selected ? "取消选择" : "选择", systemImage: selected ? "checkmark.circle" : "circle")
      }
    }
  }
}

private struct AssetThumbnailView: View {
  let asset: MediaAsset
  @StateObject private var loader = ThumbnailLoader()

  var body: some View {
    GeometryReader { proxy in
      Group {
        if let image = loader.image {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
        } else {
          ZStack {
            PhotoSlimTheme.raisedSurface
            Image(systemName: asset.kind.symbolName)
              .font(.system(size: 25, weight: .light))
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      .background(PhotoSlimTheme.raisedSurface)
      .clipped()
      .overlay(alignment: .topTrailing) {
        if !asset.canProcess {
          Image(systemName: "lock.fill")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.58))
            .clipShape(Circle())
            .padding(6)
        }
      }
      .onAppear {
        loader.load(
          identifier: asset.id,
          targetSize: CGSize(
            width: max(100, proxy.size.width * 2), height: max(100, proxy.size.height * 2))
        )
      }
      .onDisappear { loader.cancel() }
    }
  }
}
