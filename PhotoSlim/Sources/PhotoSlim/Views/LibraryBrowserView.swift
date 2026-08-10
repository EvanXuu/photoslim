import SwiftUI

struct LibraryBrowserView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsFilters = false
  @State private var showsSettings = false

  var body: some View {
    VStack(spacing: 0) {
      browserTitle
      Divider()

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
          Picker("排序", selection: $model.filter.sortOption) {
            ForEach(SortOption.allCases) { option in
              Text(option.title).tag(option)
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
      CompressionSettingsView(current: model.settings) { value in
        model.applyCompressionSettings(value)
      }
    }
  }

  private var browserTitle: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(model.destination.title)
          .font(.system(size: 24, weight: .semibold))
          .foregroundStyle(PhotoSlimTheme.ink)
        Text("\(model.visibleAssets.count) 个项目 · 编码待确认的 iCloud 视频默认显示，下载后验证")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      Spacer()
      if model.isScanning {
        Label("正在扫描", systemImage: "arrow.triangle.2.circlepath")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(PhotoSlimTheme.signal)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(PhotoSlimTheme.surface)
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
      Text(model.isScanning ? "正在检查照片图库" : "当前筛选下没有项目")
        .font(.system(size: 16, weight: .semibold))
      Text(model.isScanning ? "本地大小会读取实际资源；iCloud 大小不会估算，任务下载后读取。" : "调整时间、大小或排除项筛选后再试。")
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
      Text(model.scanTotal > 0 ? "正在检查 \(model.scanCompleted)/\(model.scanTotal)" : "正在读取图库")
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
        if model.selectedIdentifiers.isEmpty {
          Text("JPEG、H.264 SDR 与普通 hvc1 HEVC 项目可以加入任务")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
          Text(selectionSummary)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          if let report = model.selectionDiskReport {
            Label(
              "临时空间需 \(MediaFormatting.bytes(report.requiredBytes)) · 本机可用于任务 \(MediaFormatting.bytes(report.availableBytes))",
              systemImage: report.hasEnoughSpace
                ? "externaldrive.badge.checkmark" : "externaldrive.badge.exclamationmark"
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(report.hasEnoughSpace ? PhotoSlimTheme.success : PhotoSlimTheme.danger)
          }
        }
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
        Text(model.settings.summary)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }

      if !model.selectedIdentifiers.isEmpty {
        Button("清除") { model.clearSelection() }
      }
      Button(model.currentSession?.phase.blocksNewTask == true ? "加入准备队列" : "检查空间并开始") {
        model.prepareSelectedTask()
      }
      .buttonStyle(SignalButtonStyle())
      .disabled(model.selectedIdentifiers.isEmpty)
    }
    .padding(.horizontal, 20)
    .frame(minHeight: 72)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }

  private var selectionSummary: String {
    let knownInput = MediaFormatting.bytes(model.selectedInputBytes)
    let cloudNote = model.selectedCloudAssetCount > 0
      ? " · iCloud \(model.selectedCloudAssetCount) 个（下载后读取大小）"
      : ""
    let saving = model.selectedSavingsBytes > 0
      ? " · 已知项目预计节省 \(MediaFormatting.bytes(model.selectedSavingsBytes))"
      : ""
    return "已知原件 \(knownInput)\(cloudNote)\(saving)"
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
            if asset.isCloudOnly { Image(systemName: "icloud.and.arrow.down") }
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
              Text("HEVC→HEVC")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(PhotoSlimTheme.warning)
            }
          }
          Text(sizeSummary(for: asset))
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
          HStack {
            Text(MediaFormatting.date(asset.creationDate))
            Spacer()
            if let savings = asset.estimatedSavingsRatio {
              Text("省 \(MediaFormatting.percentage(savings))")
                .foregroundStyle(PhotoSlimTheme.signal)
            }
          }
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
      "\(asset.displayTitle)，\(asset.format.title)，\(MediaFormatting.inputBytes(for: asset))"
    )
    .accessibilityValue(selected ? "已选择" : (asset.canProcess ? "未选择" : "不可处理"))
  }

  private func sizeSummary(for asset: MediaAsset) -> String {
    guard let output = asset.estimatedOutputBytes else {
      return "\(MediaFormatting.inputBytes(for: asset)) → 下载后计算"
    }
    return "\(MediaFormatting.inputBytes(for: asset)) → \(MediaFormatting.bytes(output))"
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
            Text("原大小").frame(width: 90, alignment: .trailing)
            Text("预计节省").frame(width: 90, alignment: .trailing)
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
              + (asset.isPlainHVC1 ? " · HEVC→HEVC" : "")
          )
          .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(asset.format.title).frame(width: 70, alignment: .leading)
        Text(MediaFormatting.date(asset.creationDate)).frame(width: 100, alignment: .leading)
        Text(MediaFormatting.inputBytes(for: asset)).frame(width: 90, alignment: .trailing)
        Text(MediaFormatting.bytes(asset.estimatedSavingsBytes))
          .foregroundStyle(
            asset.estimatedSavingsBytes == nil ? Color.secondary : PhotoSlimTheme.signal
          )
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
