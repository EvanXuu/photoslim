import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Group {
        if model.shouldForceReview {
          ReviewView()
        } else if model.currentSession?.phase == .failed {
          FailedSessionView()
        } else if model.isProcessing && !model.isTaskPanelMinimized {
          TaskProgressView()
        } else {
          mainShell
        }
      }
      .background(PhotoSlimTheme.canvas)

      if model.isProcessing && model.isTaskPanelMinimized {
        MiniTaskPanel()
          .padding(18)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.18), value: model.isTaskPanelMinimized)
    .sheet(item: $model.pendingTask, onDismiss: model.cancelPreparedTask) { _ in
      DiskPreflightView()
        .environmentObject(model)
    }
    .alert(item: $model.notice) { notice in
      Alert(
        title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好"))
      )
    }
  }

  private var mainShell: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(
          min: PhotoSlimTheme.sidebarWidth,
          ideal: PhotoSlimTheme.sidebarWidth,
          max: 260
        )
    } detail: {
      if !model.accessState.canRead {
        AuthorizationView()
      } else {
        destinationView
      }
    }
    .navigationSplitViewStyle(.balanced)
  }

  @ViewBuilder
  private var destinationView: some View {
    switch model.destination {
    case .library, .photos, .videos, .favorites:
      LibraryBrowserView()
    case .queue:
      QueueView()
    case .statistics:
      StatisticsView()
    case .history:
      HistoryView()
    }
  }
}
