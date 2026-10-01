#if SWIFT_PACKAGE
import PhotoSlimMediaCore
#endif
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
          Text(L10n("已节省空间"))
            .font(.system(size: 24, weight: .semibold))
          Text(L10n("只统计已确认完成的任务；撤回和失败的任务不会计入。"))
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
          processedAssetSyncOverview
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

  private var processedAssetSyncOverview: some View {
    HStack(spacing: 14) {
      Image(systemName: syncSymbol)
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(
          model.processedAssetSync.phase == .synced ? PhotoSlimTheme.success : Color.secondary
        )
        .frame(width: 26)
      VStack(alignment: .leading, spacing: 4) {
        Text(L10n("跨设备记录 · \(model.processedAssetSync.statusTitle)"))
          .font(.system(size: 12, weight: .semibold))
        Text(model.processedAssetSync.statusDetail)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let date = model.processedAssetSync.lastSyncDate {
        Text(L10n("更新于 \(MediaFormatting.date(date))"))
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
      }
      if model.processedAssetSync.isConfigured, model.processedAssetSync.isEnabled {
        Button(L10n("同步")) { model.retryProcessedAssetSync() }
      }
    }
    .padding(14)
    .insetPanel()
  }

  private var syncSymbol: String {
    switch model.processedAssetSync.phase {
    case .synced: return "checkmark.icloud"
    case .syncing, .preparing: return "arrow.triangle.2.circlepath.icloud"
    case .waitingForAccount, .waitingForNetwork: return "icloud.slash"
    case .disabled: return "icloud.slash"
    case .unavailable: return "exclamationmark.icloud"
    }
  }

  private var storageOverview: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(L10n("本机存储空间"))
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button {
          model.refreshStorageStatus(enforceSelectionLimit: true, showNotice: true)
        } label: {
          Label(L10n("刷新"), systemImage: "arrow.clockwise")
        }
      }

      if let storage = model.localStorageReport {
        ProgressView(value: storage.usedRatio)
          .progressViewStyle(.linear)
          .tint(storage.usedRatio > 0.90 ? PhotoSlimTheme.warning : PhotoSlimTheme.signal)

        HStack(spacing: 10) {
          storageMetric(L10n("已使用"), storage.usedBytes)
          storageMetric(L10n("立即可用"), storage.immediatelyAvailableBytes)
          storageMetric(L10n("可用于任务"), storage.availableBytes, accent: true)
          storageMetric(L10n("总容量"), storage.totalBytes)
        }

        if storage.reclaimableBytes > 0 {
          Text(
            L10n("系统可按需释放 \(MediaFormatting.bytes(storage.reclaimableBytes)) 空间，可用于任务。")
          )
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
        }
      } else if model.storageStatusError != nil {
        Label(L10n("无法读取本机存储空间，请稍后重试。"), systemImage: "externaldrive.badge.exclamationmark")
          .font(.system(size: 10))
          .foregroundStyle(PhotoSlimTheme.danger)
      } else {
        ProgressView()
          .controlSize(.small)
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
        title: L10n("累计节省"),
        value: MediaFormatting.bytes(model.statistics.savedBytes),
        symbol: "externaldrive.badge.checkmark",
        accent: true
      )
      metricCard(
        title: L10n("已替换项目"),
        value: "\(model.statistics.committedItemCount)",
        symbol: "photo.stack",
        accent: false
      )
      metricCard(
        title: L10n("完成任务"),
        value: "\(model.statistics.completedTaskCount)",
        symbol: "checkmark.seal",
        accent: false
      )
      metricCard(
        title: L10n("最近完成"),
        value: model.statistics.latestCompletionDate.map(MediaFormatting.date) ?? L10n("暂无"),
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
        Text(L10n("按任务"))
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Text(L10n("节省比例按实际结果计算"))
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
            Text(L10n("\(record.itemCount - record.failedCount) 个项目"))
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
      Text(L10n("还没有已确认的节省记录"))
        .font(.system(size: 14, weight: .semibold))
      Text(L10n("完成一次任务并选择“确认删除原件”后，统计会出现在这里。"))
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 260)
    .insetPanel()
  }
}
