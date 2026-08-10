import SwiftUI

struct CompressionSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: CompressionSettings
  let onSave: (CompressionSettings) -> Void

  init(current: CompressionSettings, onSave: @escaping (CompressionSettings) -> Void) {
    _draft = State(initialValue: current)
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("详细压缩设置")
            .font(.system(size: 19, weight: .semibold))
          Text("推荐值只是填写起点；视频编码参数会直接写入 VideoToolbox。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("恢复推荐参数") { draft = .recommended }
      }
      .padding(20)
      Divider()

      Form {
        Section("照片 · HEIC") {
          LabeledContent("质量") {
            HStack {
              Slider(value: $draft.photoQuality, in: 0.55...0.95, step: 0.01)
                .frame(width: 220)
              Text("\(Int(draft.photoQuality * 100))")
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            }
          }
          Text("保持像素尺寸、方向、色彩配置和公开可复制的 EXIF/IPTC 元数据。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("视频 · HEVC（手动编码）") {
          Picker("码率策略", selection: $draft.videoBitrateMode) {
            ForEach(VideoBitrateMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }

          if draft.videoBitrateMode == .sourceRatio {
            LabeledContent("目标平均码率") {
              HStack {
                Slider(value: $draft.videoBitrateRatio, in: 0.25...0.90, step: 0.05)
                  .frame(width: 220)
                Text("源文件的 \(Int(draft.videoBitrateRatio * 100))%")
                  .monospacedDigit()
                  .frame(width: 90, alignment: .trailing)
              }
            }
            Text("下载完成后按原件总字节数计算视频目标码率。")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            LabeledContent("视频平均码率") {
              HStack(spacing: 8) {
                TextField("2000", value: $draft.videoTargetBitrateKbps, format: .number)
                  .textFieldStyle(.roundedBorder)
                  .frame(width: 100)
                Text("kbps")
                  .foregroundStyle(.secondary)
              }
            }
            Text("直接写入 HEVC 的平均码率，不使用导出预设。音频码率另行计算。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

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
          Label("保持原始分辨率、方向、可变帧率时间轴和时长", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("任务安全") {
          LabeledContent("最低实际节省") {
            HStack {
              Slider(value: $draft.minimumSavingsRatio, in: 0.05...0.30, step: 0.05)
                .frame(width: 220)
              Text("\(Int(draft.minimumSavingsRatio * 100))%")
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            }
          }
          Text("输出低于此节省比例时不会导入照片图库。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
    .frame(width: 600, height: 620)
    .background(PhotoSlimTheme.canvas)
  }
}
