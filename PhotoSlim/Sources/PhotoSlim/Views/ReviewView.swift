import AVFoundation
import AppKit
import SwiftUI

struct ReviewView: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmsRollback = false
  @State private var selectedItem: TaskItemRecord?
  @State private var hoveredItemID: UUID?
  @State private var keyboardComparing = false

  var body: some View {
    VStack(spacing: 0) {
      reviewHeader
      Divider()

      if let session = model.currentSession {
        ScrollView {
          VStack(spacing: 18) {
            summaryPanel(session)
            reviewInstructions
            reviewPreviewGrid(session)
            itemPanel(session)
          }
          .padding(24)
        }
        decisionBar(session)
      }
    }
    .background(PhotoSlimTheme.canvas)
    .alert("撤回本任务的压缩副本？", isPresented: $confirmsRollback) {
      Button("取消", role: .cancel) {}
      Button("撤回压缩副本", role: .destructive) { model.rollbackCompressedCopies() }
    } message: {
      Text("本次生成的结果会被清理；原件保持不动。")
    }
    .sheet(item: $selectedItem) { item in
      ReviewDetailView(item: item)
        .environmentObject(model)
    }
    .background(
      BeforeAfterKeyMonitor(isEnabled: { selectedItem == nil }) { pressed in
        // The grid shortcut is scoped to the card under the pointer. Do not
        // silently choose the first item when the pointer is elsewhere.
        keyboardComparing = pressed && hoveredItemID != nil
      }
    )
  }

  private var reviewHeader: some View {
    HStack(spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(PhotoSlimTheme.signalSoft)
          .frame(width: 48, height: 48)
        Image(systemName: "eye.circle.fill")
          .font(.system(size: 23))
          .foregroundStyle(PhotoSlimTheme.signal)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("压缩结果已准备好")
          .font(.system(size: 24, weight: .semibold))
        Text("压缩结果暂时保存在本机。确认无误后才会写入相册；原件目前安全保留。")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Label("按住“查看原图”或键盘 \\ 对比", systemImage: "rectangle.on.rectangle")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .padding(22)
    .background(PhotoSlimTheme.surface)
  }

  private func summaryPanel(_ session: CompressionSession) -> some View {
    HStack(spacing: 0) {
      summaryMetric(
        "待写入结果",
        "\(session.verifiedItems.count)",
        symbol: "checkmark.seal")
      Divider().frame(height: 46)
      summaryMetric(
        "原件大小", MediaFormatting.bytes(session.verifiedOriginalBytes), symbol: "externaldrive")
      Divider().frame(height: 46)
      summaryMetric(
        "压缩后", MediaFormatting.bytes(session.verifiedOutputBytes), symbol: "arrow.down.right.circle"
      )
      Divider().frame(height: 46)
      summaryMetric(
        "实际节省", MediaFormatting.bytes(session.verifiedSavedBytes),
        symbol: "chart.line.downtrend.xyaxis")
    }
    .padding(.vertical, 18)
    .insetPanel()
  }

  private func summaryMetric(_ label: String, _ value: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(label, systemImage: symbol)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 17, weight: .semibold, design: .rounded))
        .foregroundStyle(PhotoSlimTheme.ink)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 18)
  }

  private var reviewInstructions: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("检查建议")
        .font(.system(size: 13, weight: .semibold))
      HStack(alignment: .top, spacing: 22) {
        instruction("1", "先在下方网格检查压缩结果；点击项目可单独放大。")
        instruction("2", "按住“查看原图”或键盘 \\，比较清晰度、颜色和画面。")
        instruction("3", "确认无误后写入相册，系统会直接确认删除原件。")
      }
      Label("拍摄日期、位置、收藏和相簿信息会尽量保留；原件的添加时间可能变化。", systemImage: "info.circle")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
    .padding(18)
    .background(PhotoSlimTheme.signalSoft)
    .clipShape(RoundedRectangle(cornerRadius: PhotoSlimTheme.panelRadius, style: .continuous))
  }

  private func reviewPreviewGrid(_ session: CompressionSession) -> some View {
    let items = session.verifiedItems
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("压缩结果")
          .font(.system(size: 15, weight: .semibold))
        Spacer()
        Text("按住查看原图 · 键盘 \\")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      if items.isEmpty {
        Text("没有可供预览的压缩结果。原件未修改。")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(16)
          .insetPanel()
      } else {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 12)],
          alignment: .leading,
          spacing: 14
        ) {
          ForEach(items) { item in
            ReviewPreviewCard(
              item: item,
              keyboardComparing: keyboardComparing && hoveredItemID == item.id,
              onHoverChanged: { isHovering in
                if isHovering {
                  hoveredItemID = item.id
                } else if hoveredItemID == item.id {
                  hoveredItemID = nil
                }
              }
            ) {
              selectedItem = item
            }
          }
        }
      }
    }
  }

  private func instruction(_ number: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Text(number)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(PhotoSlimTheme.signalForeground)
        .frame(width: 20, height: 20)
        .background(PhotoSlimTheme.signal)
        .clipShape(Circle())
      Text(text)
        .font(.system(size: 11))
        .foregroundStyle(PhotoSlimTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func itemPanel(_ session: CompressionSession) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text("本任务项目")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        if session.failedItemCount > 0 {
          Label(
            "\(session.failedItemCount) 个失败项目会保留原件", systemImage: "exclamationmark.triangle.fill"
          )
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(PhotoSlimTheme.warning)
        }
      }
      .padding(14)
      Divider()
      ForEach(session.items) { item in
        HStack(spacing: 10) {
          Image(systemName: item.state.symbol)
            .foregroundStyle(item.state == .failed ? PhotoSlimTheme.danger : PhotoSlimTheme.success)
            .frame(width: 18)
          VStack(alignment: .leading, spacing: 2) {
            Text(item.source.displayTitle)
              .font(.system(size: 11, weight: .semibold))
              .lineLimit(1)
            Text(item.errorMessage ?? "结果已检查，写入相册后会再次确认信息")
              .font(.system(size: 9))
              .foregroundStyle(item.state == .failed ? PhotoSlimTheme.danger : Color.secondary)
              .lineLimit(1)
          }
          Spacer()
          Text(MediaFormatting.bytes(item.source.originalBytes))
            .foregroundStyle(.secondary)
          Image(systemName: "arrow.right")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
          Text(MediaFormatting.bytes(item.actualOutputBytes))
          Text(item.state.title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(item.state == .failed ? PhotoSlimTheme.danger : PhotoSlimTheme.success)
            .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 14)
        .frame(height: 44)
        Divider().padding(.leading, 42)
      }
    }
    .insetPanel()
  }

  private func decisionBar(_ session: CompressionSession) -> some View {
    HStack(spacing: 12) {
      if session.phase == .committing || session.phase == .rollingBack {
        ProgressView().controlSize(.small)
        Text(session.statusMessage)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      } else {
        Text("撤回会保留原件；确认删除后，原件会移到“最近删除”。")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("撤回压缩副本") { confirmsRollback = true }
        .disabled(session.phase != .reviewPending)
      Button("确认删除原件") { model.commitAndDeleteOriginals() }
        .buttonStyle(SignalButtonStyle())
        .disabled(
          session.phase != .reviewPending || session.items.allSatisfy { $0.state == .failed })
    }
    .padding(.horizontal, 22)
    .frame(height: 64)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }
}

private struct ReviewPreviewCard: View {
  @EnvironmentObject private var model: AppModel
  let item: TaskItemRecord
  let keyboardComparing: Bool
  let onHoverChanged: (Bool) -> Void
  let onSelect: () -> Void
  @State private var outputImage: NSImage?
  @State private var originalImage: NSImage?
  @State private var pressingCompare = false

  private var showingOriginal: Bool { keyboardComparing || pressingCompare }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button(action: onSelect) {
        ZStack(alignment: .topLeading) {
          ReviewPreviewImage(
            image: showingOriginal ? originalImage : outputImage,
            kind: item.source.kind,
            isOriginal: showingOriginal
          )
          if showingOriginal {
            Text("原图")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .background(.black.opacity(0.68))
              .clipShape(Capsule())
              .padding(8)
          }
        }
      }
      .buttonStyle(.plain)

      HStack(spacing: 8) {
        Button {
          // The comparison is intentionally driven by the press state below.
        } label: {
          Label("查看原图", systemImage: "rectangle.on.rectangle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .onLongPressGesture(
          minimumDuration: 0,
          maximumDistance: 24,
          pressing: { pressingCompare = $0 },
          perform: {}
        )
        Text(item.source.displayTitle)
          .font(.system(size: 10, weight: .semibold))
          .lineLimit(1)
          .foregroundStyle(PhotoSlimTheme.ink)
      }
      HStack {
        Text(MediaFormatting.bytes(item.source.originalBytes))
        Image(systemName: "arrow.right")
          .foregroundStyle(.tertiary)
        Text(MediaFormatting.bytes(item.actualOutputBytes))
        Spacer()
        if let saved = item.source.originalBytes, let output = item.actualOutputBytes, saved > 0 {
          Text(MediaFormatting.percentage(Double(max(0, saved - output)) / Double(saved)))
            .foregroundStyle(PhotoSlimTheme.signal)
        }
      }
      .font(.system(size: 10, design: .monospaced))
      .foregroundStyle(.secondary)
    }
    .padding(8)
    .background(PhotoSlimTheme.surface)
    .clipShape(RoundedRectangle(cornerRadius: PhotoSlimTheme.cardRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: PhotoSlimTheme.cardRadius, style: .continuous)
        .stroke(PhotoSlimTheme.hairline)
    }
    .onHover(perform: onHoverChanged)
    .task(id: item.id) {
      outputImage = await ReviewPreviewRenderer.image(
        at: model.reviewOutputURL(for: item),
        kind: item.source.kind
      )
      originalImage = await model.loadOriginalReviewImage(
        for: item,
        targetSize: CGSize(width: 1_200, height: 1_200)
      )
    }
  }
}

private struct ReviewDetailView: View {
  @EnvironmentObject private var model: AppModel
  let item: TaskItemRecord
  @State private var outputImage: NSImage?
  @State private var originalImage: NSImage?
  @State private var comparing = false

  var body: some View {
    VStack(spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(item.source.displayTitle)
            .font(.system(size: 17, weight: .semibold))
          Text("按住“查看原图”或键盘 \\ 对比；可缩放和平移结果")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          // Press state below controls the actual before/after image.
        } label: {
          Label("查看原图", systemImage: "rectangle.on.rectangle")
        }
        .buttonStyle(.borderedProminent)
        .onLongPressGesture(
          minimumDuration: 0,
          maximumDistance: 24,
          pressing: { comparing = $0 },
          perform: {}
        )
      }
      ZoomableReviewPreview(
        image: comparing ? originalImage : outputImage,
        kind: item.source.kind,
        isOriginal: comparing
      )
      .frame(minWidth: 560, minHeight: 420)
    }
    .padding(24)
    .frame(minWidth: 640, minHeight: 520)
    .background(PhotoSlimTheme.canvas)
    .background(
      BeforeAfterKeyMonitor(isEnabled: { true }) { pressed in
        comparing = pressed
      }
    )
    .task {
      outputImage = await ReviewPreviewRenderer.image(
        at: model.reviewOutputURL(for: item),
        kind: item.source.kind
      )
      originalImage = await model.loadOriginalReviewImage(
        for: item,
        targetSize: CGSize(width: 2_000, height: 2_000)
      )
    }
  }
}

private struct ReviewPreviewImage: View {
  let image: NSImage?
  let kind: MediaKind
  let isOriginal: Bool

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      PhotoSlimTheme.raisedSurface
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .padding(8)
      } else {
        VStack(spacing: 8) {
          Image(systemName: kind.symbolName)
            .font(.system(size: 30, weight: .light))
          Text(isOriginal ? "正在加载原图" : "正在加载压缩结果")
            .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
      }
      if kind == .video {
        Label("视频首帧", systemImage: "play.rectangle")
          .font(.system(size: 9, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(7)
      }
    }
    .aspectRatio(4 / 3, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
  }
}

private struct ZoomableReviewPreview: View {
  let image: NSImage?
  let kind: MediaKind
  let isOriginal: Bool

  @State private var zoom: CGFloat = 1
  @State private var magnification = CGFloat(1)
  @State private var panOffset = CGSize.zero
  @State private var transientPan = CGSize.zero

  private var effectiveZoom: CGFloat {
    min(max(zoom * magnification, 1), 5)
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Label(isOriginal ? "原图" : "压缩结果", systemImage: isOriginal ? "photo" : "arrow.down.right.circle")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          adjustZoom(by: -0.25)
        } label: {
          Image(systemName: "minus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("缩小")
        .disabled(zoom <= 1)
        Text("\(Int(zoom * 100))%")
          .font(.system(size: 10, design: .monospaced))
          .frame(width: 48)
          .foregroundStyle(.secondary)
        Button {
          adjustZoom(by: 0.25)
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("放大")
        .disabled(zoom >= 5)
        Button("适合窗口") {
          resetZoom()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }

      GeometryReader { proxy in
        ZStack {
          ReviewPreviewImage(image: image, kind: kind, isOriginal: isOriginal)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(effectiveZoom)
            .offset(
              x: panOffset.width + transientPan.width,
              y: panOffset.height + transientPan.height
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
          MagnificationGesture()
            .onChanged { value in magnification = value }
            .onEnded { value in
              zoom = min(max(zoom * value, 1), 5)
              magnification = 1
              if zoom == 1 { panOffset = .zero }
            }
        )
        .simultaneousGesture(
          DragGesture(minimumDistance: 1)
            .onChanged { value in transientPan = value.translation }
            .onEnded { value in
              guard zoom > 1 else {
                transientPan = .zero
                return
              }
              panOffset.width += value.translation.width
              panOffset.height += value.translation.height
              transientPan = .zero
            }
        )
      }
      .frame(minHeight: 360)
      Text("拖动查看 · 使用按钮缩放")
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
    }
    .padding(10)
    .background(PhotoSlimTheme.raisedSurface)
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
  }

  private func adjustZoom(by delta: CGFloat) {
    zoom = min(max(zoom + delta, 1), 5)
    if zoom == 1 { panOffset = .zero }
  }

  private func resetZoom() {
    zoom = 1
    magnification = 1
    panOffset = .zero
    transientPan = .zero
  }
}

private enum ReviewPreviewRenderer {
  static func image(at url: URL?, kind: MediaKind) async -> NSImage? {
    guard let url else { return nil }
    if kind == .photo {
      return NSImage(contentsOf: url)
    }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1_600, height: 1_600)
    return await withCheckedContinuation { continuation in
      generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) {
        _, image, _, _, _ in
        if let image {
          continuation.resume(returning: NSImage(cgImage: image, size: .zero))
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }
}

private struct BeforeAfterKeyMonitor: NSViewRepresentable {
  let isEnabled: () -> Bool
  let onChanged: (Bool) -> Void

  init(isEnabled: @escaping () -> Bool = { true }, onChanged: @escaping (Bool) -> Void) {
    self.isEnabled = isEnabled
    self.onChanged = onChanged
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(isEnabled: isEnabled, onChanged: onChanged)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.start()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.update(isEnabled: isEnabled, onChanged: onChanged)
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  final class Coordinator {
    private var isEnabled: () -> Bool
    private var onChanged: (Bool) -> Void
    private var monitor: Any?

    init(isEnabled: @escaping () -> Bool, onChanged: @escaping (Bool) -> Void) {
      self.isEnabled = isEnabled
      self.onChanged = onChanged
    }

    func update(isEnabled: @escaping () -> Bool, onChanged: @escaping (Bool) -> Void) {
      self.isEnabled = isEnabled
      self.onChanged = onChanged
    }

    func start() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
        [weak self] event in
        guard event.keyCode == 42 || event.charactersIgnoringModifiers == "\\" else { return event }
        guard self?.isEnabled() == true else { return event }
        if event.type == .keyDown && event.isARepeat {
          return nil
        }
        self?.onChanged(event.type == .keyDown)
        // Consume the handled shortcut. Passing it on makes AppKit beep when
        // no text control is focused, and may trigger an unrelated command.
        return nil
      }
    }

    func stop() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }

    deinit { stop() }
  }
}

struct FailedSessionView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 38))
        .foregroundStyle(PhotoSlimTheme.warning)
      Text("没有生成可预览的结果")
        .font(.system(size: 23, weight: .semibold))
      Text(model.currentSession?.statusMessage ?? "任务失败")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)

      if let session = model.currentSession {
        VStack(spacing: 0) {
          ForEach(session.items) { item in
            HStack {
              Image(systemName: "xmark.circle.fill").foregroundStyle(PhotoSlimTheme.danger)
              Text(item.source.displayTitle).lineLimit(1)
              Spacer()
              Text(item.errorMessage ?? "未完成")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider().padding(.leading, 42)
          }
        }
        .frame(maxWidth: 620)
        .insetPanel()
      }

      HStack {
        Button("结束失败任务") { model.finishFailedSession() }
        Button("重试") { model.retryFailedSession() }
          .buttonStyle(SignalButtonStyle())
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(30)
    .background(PhotoSlimTheme.canvas)
  }
}
