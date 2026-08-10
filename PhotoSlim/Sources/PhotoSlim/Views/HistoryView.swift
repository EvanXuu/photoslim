import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("任务历史")
            .font(.system(size: 24, weight: .semibold))
          Text("记录确认、撤回和失败结果，不包含文件名或位置信息。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)
      .background(PhotoSlimTheme.surface)
      Divider()

      if model.history.isEmpty {
        VStack(spacing: 11) {
          Image(systemName: "clock.arrow.circlepath")
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(.secondary)
          Text("暂无任务历史")
            .font(.system(size: 15, weight: .semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(model.history.sorted { $0.finishedAt > $1.finishedAt }) { record in
              historyRow(record)
            }
          }
          .padding(20)
        }
      }
    }
    .background(PhotoSlimTheme.canvas)
  }

  private func historyRow(_ record: TaskHistoryRecord) -> some View {
    HStack(spacing: 14) {
      Image(systemName: outcomeSymbol(record.outcome))
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(outcomeColor(record.outcome))
        .frame(width: 34, height: 34)
        .background(outcomeColor(record.outcome).opacity(0.11))
        .clipShape(Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(outcomeTitle(record.outcome))
          .font(.system(size: 12, weight: .semibold))
        Text(
          "\(MediaFormatting.date(record.startedAt)) · \(record.itemCount) 个项目 · \(record.failedCount) 个失败"
        )
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        Text(
          record.outcome == .committed
            ? "节省 \(MediaFormatting.bytes(max(0, record.originalBytes - record.outputBytes)))"
            : "未计入节省"
        )
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(record.outcome == .committed ? PhotoSlimTheme.signal : Color.secondary)
        Text(MediaFormatting.date(record.finishedAt))
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
        if model.pendingCleanupSessionID == record.id {
          Button("重试清理") { model.retryPendingCleanup() }
            .font(.system(size: 10, weight: .medium))
        }
      }
    }
    .padding(14)
    .insetPanel()
  }

  private func outcomeTitle(_ phase: SessionPhase) -> String {
    switch phase {
    case .committed: return "已确认删除原件"
    case .rolledBack: return "已撤回压缩副本"
    case .cancelled: return "已终止并清理临时文件"
    case .failed: return "任务失败"
    default: return "未完成任务"
    }
  }

  private func outcomeSymbol(_ phase: SessionPhase) -> String {
    switch phase {
    case .committed: return "checkmark"
    case .rolledBack: return "arrow.uturn.backward"
    case .cancelled: return "stop"
    case .failed: return "xmark"
    default: return "ellipsis"
    }
  }

  private func outcomeColor(_ phase: SessionPhase) -> Color {
    switch phase {
    case .committed: return PhotoSlimTheme.success
    case .rolledBack: return PhotoSlimTheme.warning
    case .cancelled: return .secondary
    case .failed: return PhotoSlimTheme.danger
    default: return .secondary
    }
  }
}
