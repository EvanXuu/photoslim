import SwiftUI

struct CompressionSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: CompressionSettings
  let mediaKind: MediaKind?
  let onSave: (CompressionSettings) -> Void

  init(
    current: CompressionSettings,
    mediaKind: MediaKind? = nil,
    onSave: @escaping (CompressionSettings) -> Void
  ) {
    _draft = State(initialValue: current)
    self.mediaKind = mediaKind
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("详细压缩设置")
            .font(.system(size: 19, weight: .semibold))
          Text(headerDescription)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("恢复推荐参数") { draft = .recommended }
      }
      .padding(20)
      Divider()

      Form {
        if mediaKind == nil || mediaKind == .photo {
          photoSection
        }
        if mediaKind == nil || mediaKind == .video {
          videoSection
        }
        taskSafetySection
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存设置") {
          onSave(draft)
          dismiss()
        }
        .buttonStyle(SignalButtonStyle())
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 660, height: mediaKind == nil ? 720 : 650)
    .background(PhotoSlimTheme.canvas)
  }

  private var headerDescription: String {
    switch mediaKind {
    case .photo:
      return "只显示照片参数。"
    case .video:
      return draft.videoEncodingMode == .automatic
        ? "自动使用系统推荐设置。"
        : "手动设置视频码率和音频。"
    case nil:
      return "自动使用系统推荐设置；手动模式可调整视频参数。"
    }
  }

  private var photoSection: some View {
    Section("照片") {
      LabeledContent("质量") {
        HStack {
          Slider(value: $draft.photoQuality, in: 0.55...0.95, step: 0.01)
            .frame(width: 220)
          Text("\(Int(draft.photoQuality * 100))")
            .monospacedDigit()
            .frame(width: 32, alignment: .trailing)
        }
      }
      Text("保持原始尺寸、方向和照片信息。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var videoSection: some View {
    Section("视频") {
      Picker("编码方式", selection: $draft.videoEncodingMode) {
        ForEach(VideoEncodingMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }

      if draft.videoEncodingMode == .manual {
        manualBitrateTable

        LabeledContent("视频硬上限") {
          HStack(spacing: 8) {
            TextField("0", value: $draft.videoMaxBitrateKbps, format: .number)
              .textFieldStyle(.roundedBorder)
              .frame(width: 100)
            Text("kbps（0 = 不设置）")
              .foregroundStyle(.secondary)
          }
        }

        LabeledContent("关键帧间隔") {
          Stepper(
            "\(draft.videoKeyframeIntervalSeconds, specifier: "%.1f") 秒",
            value: $draft.videoKeyframeIntervalSeconds,
            in: 0.5...10,
            step: 0.5
          )
        }
        Toggle("允许帧重排（B 帧）", isOn: $draft.videoAllowFrameReordering)

        Picker("音频", selection: $draft.audioPolicy) {
          ForEach(AudioPolicy.allCases) { Text($0.title).tag($0) }
        }
        if draft.audioPolicy == .aac {
          Picker("AAC 码率", selection: $draft.aacBitrate) {
            Text("128 kbps").tag(128_000)
            Text("192 kbps").tag(192_000)
            Text("256 kbps").tag(256_000)
          }
        }
        Label("保持原始尺寸、方向、帧率和时长", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var manualBitrateTable: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("手动平均视频码率")
        .font(.system(size: 12, weight: .semibold))

      Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 7) {
        GridRow {
          Text("分辨率")
            .foregroundStyle(.secondary)
          ForEach(VideoFrameRateTier.allCases) { frameRate in
            Text(frameRate.title)
              .foregroundStyle(.secondary)
          }
        }
        ForEach(VideoResolutionTier.allCases) { resolution in
          GridRow {
            Text(resolution.title)
              .frame(width: 82, alignment: .leading)
            ForEach(VideoFrameRateTier.allCases) { frameRate in
              bitrateField(for: resolution, frameRate: frameRate)
            }
          }
        }
      }
      .font(.system(size: 11, design: .monospaced))

      Text("默认值为 6 / 20 / 80 Mbps（30 fps），60 fps 自动使用两倍。非标准分辨率按像素数量插值；与标准尺寸相差 1 像素以内视为同一档。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private func bitrateField(
    for resolution: VideoResolutionTier,
    frameRate: VideoFrameRateTier
  ) -> some View {
    HStack(spacing: 4) {
      TextField(
        "0",
        value: Binding(
          get: { draft.manualVideoBitrates.value(for: resolution, frameRate: frameRate) },
          set: { draft.manualVideoBitrates.setValue($0, for: resolution, frameRate: frameRate) }
        ),
        format: .number.precision(.fractionLength(0...2))
      )
      .textFieldStyle(.roundedBorder)
      .frame(width: 78)
      Text("Mbps")
        .foregroundStyle(.secondary)
        .font(.system(size: 9, design: .default))
    }
  }

  private var taskSafetySection: some View {
    Section("任务安全") {
      LabeledContent("最低节省") {
        HStack {
          Slider(value: $draft.minimumSavingsRatio, in: 0.05...0.30, step: 0.01)
            .frame(width: 220)
          Text("\(Int(draft.minimumSavingsRatio * 100))%")
            .monospacedDigit()
            .frame(width: 32, alignment: .trailing)
        }
      }
      Text("只在压缩完成后判断，不影响扫描和选择。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
