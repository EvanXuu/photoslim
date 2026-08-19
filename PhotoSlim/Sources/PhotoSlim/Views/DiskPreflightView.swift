import SwiftUI

struct DiskPreflightView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 14) {
        Image(
          systemName: report.hasEnoughSpace
            ? "externaldrive.badge.checkmark" : "externaldrive.badge.exclamationmark"
        )
        .font(.system(size: 27, weight: .medium))
        .foregroundStyle(report.hasEnoughSpace ? PhotoSlimTheme.success : PhotoSlimTheme.danger)
        VStack(alignment: .leading, spacing: 4) {
          Text(
            report.hasEnoughSpace
              ? (report.hasUnknownCloudSizes ? "空间检查通过" : "可以开始")
              : "可用空间不足"
          )
            .font(.system(size: 19, weight: .semibold))
          Text("\(model.pendingTask?.assets.count ?? 0) 个项目 · 开始前会再次核对")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)
      Divider()

      VStack(spacing: 0) {
        spaceRow("本机文件", report.knownLocalInputBytes, secondary: true)
        if report.knownCloudDownloadBytes > 0 {
          spaceRow("云端文件", report.knownCloudDownloadBytes, secondary: true)
        }
        spaceRow("处理所需空间", report.knownLocalInputBytes + report.knownCloudDownloadBytes, secondary: false)
        spaceRow("安全余量", report.safetyMarginBytes, secondary: false)
        Divider().padding(.vertical, 8)
        spaceRow("任务需要", report.requiredBytes, emphasized: true)
        spaceRow("当前可用", report.availableBytes, emphasized: true)
      }
      .padding(20)

      if report.hasUnknownCloudSizes {
        Label(
          "\(report.unknownCloudAssetCount) 个云端项目的大小暂时未知。开始后会逐项下载并检查空间；空间不足时会停止，原件不会被修改。",
          systemImage: "icloud.and.arrow.down"
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(PhotoSlimTheme.signalSoft)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 20)
      }

      Spacer(minLength: 12)
      Divider()
      HStack {
        Button("取消") {
          model.cancelPreparedTask()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Spacer()
        Button(model.currentSession?.phase.blocksNewTask == true ? "加入准备队列" : "开始压缩") {
          model.confirmPreparedTask()
          if report.hasEnoughSpace { dismiss() }
        }
        .buttonStyle(SignalButtonStyle())
        .disabled(!report.hasEnoughSpace)
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 520, height: 500)
    .background(PhotoSlimTheme.canvas)
  }

  private var report: DiskSpaceReport {
    model.pendingDiskReport
      ?? DiskSpaceReport(
        knownLocalInputBytes: 0,
        knownCloudDownloadBytes: 0,
        unknownCloudAssetCount: 0,
        safetyMarginBytes: 0,
        availableBytes: 0
      )
  }

  private func spaceRow(
    _ title: String, _ bytes: Int64, secondary: Bool = false, emphasized: Bool = false
  ) -> some View {
    HStack {
      Text(title)
        .foregroundStyle(secondary ? Color.secondary : PhotoSlimTheme.ink)
      Spacer()
      Text(MediaFormatting.bytes(bytes))
        .font(
          .system(
            size: emphasized ? 14 : 12, weight: emphasized ? .semibold : .regular,
            design: .monospaced)
        )
        .foregroundStyle(emphasized ? PhotoSlimTheme.ink : Color.secondary)
    }
    .frame(height: 30)
  }
}
