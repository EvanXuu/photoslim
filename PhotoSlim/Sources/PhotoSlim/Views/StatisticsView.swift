import SwiftUI

struct StatisticsView: View {
  @EnvironmentObject private var model: AppModel

  private var committed: [TaskHistoryRecord] {
    model.history.filter { $0.outcome == .committed }.sorted { $0.finishedAt > $1.finishedAt }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("已节省空间")
            .font(.system(size: 24, weight: .semibold))
          Text("只统计已确认完成的任务；撤回和失败的任务不会计入。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)
      .background(PhotoSlimTheme.surface)
      Divider()

      ScrollView {
        VStack(spacing: 18) {
          storageOverview
          headlineMetrics
          if committed.isEmpty {
            emptyState
          } else {
            savingsTimeline
          }
        }
        .padding(22)
      }
    }
    .background(PhotoSlimTheme.canvas)
    .onAppear {
      model.refreshStorageStatus(enforceSelectionLimit: true, showNotice: true)
    }
  }

  private var storageOverview: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("本机存储空间")
            .font(.system(size: 13, weight: .semibold))
            Text("显示本机空间状态；云端项目会在处理时确认大小。")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          model.refreshStorageStatus(enforceSelectionLimit: true, showNotice: true)
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
      }

      if let storage = model.localStorageReport {
        ProgressView(value: storage.usedRatio)
          .progressViewStyle(.linear)
          .tint(storage.usedRatio > 0.90 ? PhotoSlimTheme.warning : PhotoSlimTheme.signal)

        HStack(spacing: 10) {
          storageMetric("已使用", storage.usedBytes)
          storageMetric("立即可用", storage.immediatelyAvailableBytes)
          storageMetric("可用于任务", storage.availableBytes, accent: true)
          storageMetric("总容量", storage.totalBytes)
        }

        if storage.reclaimableBytes > 0 {
          Text(
            "系统可按需释放 \(MediaFormatting.bytes(storage.reclaimableBytes)) 空间，可用于任务。"
          )
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
        }
      } else if model.storageStatusError != nil {
        Label("无法读取本机存储空间，请稍后重试。", systemImage: "externaldrive.badge.exclamationmark")
          .font(.system(size: 10))
          .foregroundStyle(PhotoSlimTheme.danger)
      } else {
        ProgressView()
          .controlSize(.small)
      }

      Divider()

      if let report = model.selectionDiskReport {
        HStack {
          Label(
            "当前选择需要 \(MediaFormatting.bytes(report.requiredBytes))",
            systemImage: "checkmark.circle.fill"
          )
          .foregroundStyle(report.hasEnoughSpace ? PhotoSlimTheme.success : PhotoSlimTheme.danger)
          Spacer()
          Text("可用于任务 \(MediaFormatting.bytes(report.availableBytes))")
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 10, weight: .medium))
      } else {
        Text("当前没有待处理选择。")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .insetPanel()
  }

  private func storageMetric(_ title: String, _ bytes: Int64, accent: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(MediaFormatting.bytes(bytes))
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .foregroundStyle(accent ? PhotoSlimTheme.signal : PhotoSlimTheme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
      Text(title)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var headlineMetrics: some View {
    HStack(spacing: 12) {
      metricCard(
        title: "累计节省",
        value: MediaFormatting.bytes(model.statistics.savedBytes),
        symbol: "externaldrive.badge.checkmark",
        accent: true
      )
      metricCard(
        title: "已替换项目",
        value: "\(model.statistics.committedItemCount)",
        symbol: "photo.stack",
        accent: false
      )
      metricCard(
        title: "完成任务",
        value: "\(model.statistics.completedTaskCount)",
        symbol: "checkmark.seal",
        accent: false
      )
      metricCard(
        title: "最近完成",
        value: model.statistics.latestCompletionDate.map(MediaFormatting.date) ?? "暂无",
        symbol: "calendar",
        accent: false
      )
    }
  }

  private func metricCard(title: String, value: String, symbol: String, accent: Bool) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Image(systemName: symbol)
          .foregroundStyle(accent ? PhotoSlimTheme.signal : Color.secondary)
        Spacer()
      }
      Text(value)
        .font(.system(size: accent ? 24 : 20, weight: .semibold, design: .rounded))
        .foregroundStyle(PhotoSlimTheme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.74)
      Text(title)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
    .background(accent ? PhotoSlimTheme.signalSoft : PhotoSlimTheme.surface)
    .clipShape(RoundedRectangle(cornerRadius: PhotoSlimTheme.panelRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: PhotoSlimTheme.panelRadius, style: .continuous)
        .stroke(accent ? PhotoSlimTheme.signal.opacity(0.30) : PhotoSlimTheme.hairline)
    }
  }

  private var savingsTimeline: some View {
    VStack(spacing: 0) {
      HStack {
        Text("按任务")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Text("节省比例按实际结果计算")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
      }
      .padding(14)
      Divider()

      ForEach(committed) { record in
        let saved = max(0, record.originalBytes - record.outputBytes)
        let ratio = record.originalBytes > 0 ? Double(saved) / Double(record.originalBytes) : 0
        HStack(spacing: 14) {
          VStack(alignment: .leading, spacing: 3) {
            Text(MediaFormatting.date(record.finishedAt))
              .font(.system(size: 11, weight: .semibold))
            Text("\(record.itemCount - record.failedCount) 个项目")
              .font(.system(size: 9))
              .foregroundStyle(.secondary)
          }
          .frame(width: 110, alignment: .leading)
          GeometryReader { proxy in
            ZStack(alignment: .leading) {
              Capsule().fill(PhotoSlimTheme.hairline)
              Capsule()
                .fill(PhotoSlimTheme.signal)
                .frame(width: max(2, proxy.size.width * min(1, ratio)))
            }
          }
          .frame(height: 8)
          Text("\(MediaFormatting.bytes(saved)) · \(MediaFormatting.percentage(ratio))")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(PhotoSlimTheme.signal)
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        Divider().padding(.leading, 14)
      }
    }
    .insetPanel()
  }

  private var emptyState: some View {
    VStack(spacing: 11) {
      Image(systemName: "chart.bar.xaxis")
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(.secondary)
      Text("还没有已确认的节省记录")
        .font(.system(size: 14, weight: .semibold))
      Text("完成一次任务并选择“确认删除原件”后，统计会出现在这里。")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 260)
    .insetPanel()
  }
}
