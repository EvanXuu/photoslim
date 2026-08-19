import SwiftUI

struct TaskProgressView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("正在准备压缩副本")
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(PhotoSlimTheme.ink)
          Text("完成后先预览，确认后才写入相册。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          model.minimizeTaskPanel()
        } label: {
          Image(systemName: "arrow.down.right.and.arrow.up.left")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .medium))
        .help("最小化任务，继续准备下一批")
        .accessibilityLabel("最小化任务，继续准备下一批")
        Button {
          model.terminateCurrentTask()
        } label: {
          Image(systemName: "stop.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(PhotoSlimTheme.danger)
        .font(.system(size: 14, weight: .medium))
        .help("停止任务")
        .accessibilityLabel("停止任务")
      }
      .padding(24)

      if let session = model.currentSession {
        VStack(spacing: 18) {
          overallPanel(session)
          if let current = currentItem(in: session) {
            currentItemPanel(current)
          }
          taskItemsPanel(session)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(PhotoSlimTheme.canvas)
  }

  private func overallPanel(_ session: CompressionSession) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(session.statusMessage)
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Text("\(Int(session.progress * 100))%")
          .font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundStyle(PhotoSlimTheme.signal)
      }
      ProgressView(value: session.progress)
        .progressViewStyle(.linear)
        .tint(PhotoSlimTheme.signal)
      HStack(spacing: 12) {
        if session.originalBytes > 0 {
          Text("已处理 " + MediaFormatting.bytes(session.originalBytes))
        }
        if session.outputBytes > 0 {
          Text("结果 " + MediaFormatting.bytes(session.outputBytes))
        }
        if let storage = model.localStorageReport {
          Spacer(minLength: 4)
          Text("本机可用 " + MediaFormatting.bytes(storage.availableBytes))
        }
      }
      .font(.system(size: 10, design: .monospaced))
      .foregroundStyle(.secondary)
      HStack {
        Text("\(session.completedItemCount) / \(session.items.count) 个项目完成")
        Spacer()
        Text("队列等待 \(model.queue.count) 批")
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    }
    .padding(18)
    .insetPanel()
  }

  private func currentItemPanel(_ item: TaskItemRecord) -> some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack(spacing: 10) {
        Image(systemName: item.source.kind.symbolName)
          .foregroundStyle(PhotoSlimTheme.signal)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.source.displayTitle)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
          Text(itemSummary(for: item.source))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text(item.state.title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
      }

      progressLine(
        title: downloadTitle(for: item.source),
        symbol: downloadSymbol(for: item.source),
        value: item.downloadProgress,
        detail: downloadDetail(for: item)
      )
      progressLine(
        title: item.source.kind == .photo ? "照片压缩" : "视频压缩",
        symbol: "gearshape.2",
        value: item.compressionProgress,
        detail: "\(Int(item.compressionProgress * 100))%"
      )
    }
    .padding(18)
    .background(PhotoSlimTheme.raisedSurface)
    .clipShape(RoundedRectangle(cornerRadius: PhotoSlimTheme.panelRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: PhotoSlimTheme.panelRadius, style: .continuous)
        .stroke(PhotoSlimTheme.signal.opacity(0.28))
    }
  }

  private func itemSummary(for asset: MediaAsset) -> String {
    var summary = asset.format.title
    if asset.isPlainHVC1 { summary += " · 再次压缩" }
    if let inputBytes = MediaFormatting.inputBytes(for: asset) {
      summary += " · \(inputBytes)"
    }
    return summary
  }

  private func downloadTitle(for asset: MediaAsset) -> String {
    switch asset.originalAvailability {
    case .local: return "本地原件"
    case .needsDownload: return "下载原件"
    case .unknown: return "准备原件"
    }
  }

  private func downloadSymbol(for asset: MediaAsset) -> String {
    switch asset.originalAvailability {
    case .local: return "externaldrive.fill.badge.checkmark"
    case .needsDownload: return "icloud.and.arrow.down"
    case .unknown: return "questionmark.icloud"
    }
  }

  private func downloadDetail(for item: TaskItemRecord) -> String {
    switch item.source.originalAvailability {
    case .local: return "已就绪"
    case .needsDownload, .unknown: return "\(Int(item.downloadProgress * 100))%"
    }
  }

  private func progressLine(title: String, symbol: String, value: Double, detail: String)
    -> some View
  {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .frame(width: 18)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.system(size: 11, weight: .medium))
        .frame(width: 92, alignment: .leading)
      ProgressView(value: value)
        .progressViewStyle(.linear)
        .tint(PhotoSlimTheme.signal)
      Text(detail)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(width: 48, alignment: .trailing)
    }
  }

  private func taskItemsPanel(_ session: CompressionSession) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text("任务项目")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        if session.failedItemCount > 0 {
          Text("\(session.failedItemCount) 个失败")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(PhotoSlimTheme.danger)
        }
      }
      .padding(14)
      Divider()

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(session.items) { item in
            HStack(spacing: 10) {
              Image(systemName: item.state.symbol)
                .foregroundStyle(
                  item.state == .failed
                    ? PhotoSlimTheme.danger
                    : item.state == .reviewPending ? PhotoSlimTheme.success : Color.secondary
                )
                .frame(width: 18)
              Text(item.source.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
              Spacer()
              Text(item.errorMessage ?? item.state.title)
                .font(.system(size: 10))
                .foregroundStyle(item.state == .failed ? PhotoSlimTheme.danger : Color.secondary)
                .lineLimit(1)
              ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .frame(width: 84)
                .tint(item.state == .failed ? PhotoSlimTheme.danger : PhotoSlimTheme.signal)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            Divider().padding(.leading, 42)
          }
        }
      }
      .frame(maxHeight: 250)
    }
    .insetPanel()
  }

  private func currentItem(in session: CompressionSession) -> TaskItemRecord? {
    if let index = session.currentItemIndex, session.items.indices.contains(index) {
      return session.items[index]
    }
    return session.items.first
  }
}

struct MiniTaskPanel: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if let session = model.currentSession {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Image(systemName: "gearshape.2.fill")
            .foregroundStyle(PhotoSlimTheme.signal)
          Text("正在压缩")
            .font(.system(size: 12, weight: .semibold))
          Spacer()
          Button {
            model.restoreTaskPanel()
          } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
          }
          .buttonStyle(.plain)
          .help("展开任务")
        }
        Text(session.statusMessage)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        ProgressView(value: session.progress)
          .progressViewStyle(.linear)
          .tint(PhotoSlimTheme.signal)
        HStack {
          if let index = session.currentItemIndex, session.items.indices.contains(index) {
            let item = session.items[index]
            Label("云端 \(Int(item.downloadProgress * 100))%", systemImage: "icloud.and.arrow.down")
            Spacer()
            Label("压缩 \(Int(item.compressionProgress * 100))%", systemImage: "gearshape")
          } else {
            Text("准备任务")
          }
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
      }
      .padding(14)
      .frame(width: 330)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(PhotoSlimTheme.hairline)
      }
      .shadow(color: .black.opacity(0.18), radius: 18, y: 7)
      .onTapGesture { model.restoreTaskPanel() }
    }
  }
}
