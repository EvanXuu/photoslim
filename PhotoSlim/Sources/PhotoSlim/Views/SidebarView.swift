import SwiftUI

struct SidebarView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $model.destination) {
        Section("媒体类型") {
          navigationRow(.library)
          navigationRow(.photos)
          navigationRow(.videos)
        }

        Section("图库") {
          navigationRow(.favorites)
        }

        Section("工作区") {
          navigationRow(.queue, badge: model.queue.count)
          navigationRow(.statistics)
          navigationRow(.history)
        }
      }
      .listStyle(.sidebar)

      Divider()
      HStack(spacing: 9) {
        Image(
          systemName: model.accessState.canRead
            ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        )
        .foregroundStyle(
          model.accessState.canRead ? PhotoSlimTheme.success : PhotoSlimTheme.warning)
        VStack(alignment: .leading, spacing: 2) {
          Text("Apple 照片")
            .font(.system(size: 11, weight: .semibold))
          Text(model.accessState.title)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(12)
    }
    .background(.bar)
  }

  @ViewBuilder
  private func navigationRow(_ destination: SidebarDestination, badge: Int = 0) -> some View {
    Label {
      HStack {
        Text(destination.title)
        Spacer()
        if badge > 0 {
          Text("\(badge)")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(PhotoSlimTheme.signalSoft)
            .foregroundStyle(PhotoSlimTheme.signal)
            .clipShape(Capsule())
        }
      }
    } icon: {
      Image(systemName: destination.symbol)
    }
    .tag(destination)
  }
}
