import SwiftUI

struct QueueView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      pageHeader
      Divider()

      if model.queue.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "list.bullet.rectangle.portrait")
            .font(.system(size: 34, weight: .light))
            .foregroundStyle(.secondary)
          Text("准备队列为空")
            .font(.system(size: 16, weight: .semibold))
          Text("压缩任务缩到角落后，可以继续选择项目并加入这里。")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 12) {
            ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, task in
              QueueTaskCard(position: index + 1, task: task)
            }
          }
          .padding(20)
        }
      }
    }
    .background(PhotoSlimTheme.canvas)
  }

  private var pageHeader: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("准备队列")
          .font(.system(size: 24, weight: .semibold))
        Text("只准备下一批；当前任务完成审核前不会开始。")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        if let message = model.queueStatusMessage {
          Text(message)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(PhotoSlimTheme.warning)
            .padding(.top, 2)
        }
      }
      Spacer()
      if model.currentSession == nil, !model.queue.isEmpty {
        Button("重新检查并开始队首任务") { model.retryStartingQueue() }
          .buttonStyle(SignalButtonStyle())
      } else if let session = model.currentSession {
        Label(session.phase == .reviewPending ? "等待当前审核" : "当前任务处理中", systemImage: "hourglass")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .padding(20)
    .background(PhotoSlimTheme.surface)
  }
}

private struct QueueTaskCard: View {
  @EnvironmentObject private var model: AppModel
  let position: Int
  let task: QueuedCompressionTask
  @State private var expanded = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Text("\(position)")
          .font(.system(size: 13, weight: .bold, design: .rounded))
          .foregroundStyle(PhotoSlimTheme.signal)
          .frame(width: 30, height: 30)
          .background(PhotoSlimTheme.signalSoft)
          .clipShape(Circle())
        VStack(alignment: .leading, spacing: 4) {
          Text("\(task.assets.count) 个项目")
            .font(.system(size: 13, weight: .semibold))
          Text(queueSizeSummary)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        }
        Spacer()
        Text(task.settings.summary)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        Button {
          expanded.toggle()
        } label: {
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.plain)
        Button(role: .destructive) {
          model.removeQueuedTask(task.id)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.plain)
        .help("从队列移除")
      }
      .padding(14)

      if expanded {
        Divider()
        VStack(spacing: 0) {
          ForEach(task.assets) { asset in
            HStack {
              Image(systemName: asset.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
              Text(asset.displayTitle).lineLimit(1)
              Spacer()
              if asset.isCloudOnly {
                Image(systemName: "icloud.and.arrow.down")
              }
              Text(MediaFormatting.inputBytes(for: asset))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .frame(height: 36)
          }
        }
        .background(PhotoSlimTheme.raisedSurface.opacity(0.6))
      }
    }
    .insetPanel()
  }

  private var queueSizeSummary: String {
    let known = task.knownInputBytes > 0
      ? "已知原件 \(MediaFormatting.bytes(task.knownInputBytes))"
      : "原件大小下载后读取"
    let cloud = task.cloudAssetCount > 0 ? " · iCloud \(task.cloudAssetCount) 个" : ""
    return known + cloud
  }
}
