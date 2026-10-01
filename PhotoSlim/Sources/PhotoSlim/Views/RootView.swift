import AppKit
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
    .alert(item: $model.notice) { notice in
      Alert(
        title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("好"))
      )
    }
    .overlay(alignment: .topLeading) {
      WindowTitleBridge(title: windowTitle, subtitle: windowSubtitle)
        .frame(width: 1, height: 1)
        .allowsHitTesting(false)
    }
  }

  private var windowTitle: String {
    switch model.destination {
    case .library: return "全部媒体"
    case .photos: return "照片"
    case .videos: return "视频"
    case .favorites: return "收藏"
    case .queue: return "准备队列"
    case .statistics: return "统计"
    case .history: return "任务历史"
    }
  }

  private var windowSubtitle: String {
    switch model.destination {
    case .library, .photos, .videos, .favorites:
      return "\(model.visibleAssets.count) 个项目"
    case .queue:
      return "\(model.queue.count) 批待处理"
    case .statistics:
      return "已节省空间"
    case .history:
      return "\(model.history.count) 条记录"
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

private struct WindowTitleBridge: NSViewRepresentable {
  let title: String
  let subtitle: String

  func makeNSView(context: Context) -> WindowTitleView {
    let view = WindowTitleView(frame: .zero)
    view.title = title
    view.subtitle = subtitle
    return view
  }

  func updateNSView(_ nsView: WindowTitleView, context: Context) {
    nsView.title = title
    nsView.subtitle = subtitle
    nsView.applyTitle()
  }
}

private final class WindowTitleView: NSView {
  var title = ""
  var subtitle = ""

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyTitle()
  }

  func applyTitle() {
    guard let window else { return }
    window.title = title
    window.subtitle = subtitle
    window.titleVisibility = .visible
  }
}
