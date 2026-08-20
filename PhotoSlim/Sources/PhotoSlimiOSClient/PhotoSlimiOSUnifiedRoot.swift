#if os(iOS) && PHOTOSLIM_UNIFIED_APP
import SwiftUI

enum PhotoSlimiOSWorkspace: String, CaseIterable, Identifiable {
  case library
  case queue
  case statistics
  case history

  var id: String { rawValue }

  var title: String {
    switch self {
    case .library: return "图库"
    case .queue: return "队列"
    case .statistics: return "统计"
    case .history: return "历史"
    }
  }

  var symbol: String {
    switch self {
    case .library: return "photo.on.rectangle.angled"
    case .queue: return "list.bullet.rectangle"
    case .statistics: return "chart.bar.xaxis"
    case .history: return "clock.arrow.circlepath"
    }
  }

  var modelDestination: SidebarDestination {
    switch self {
    case .library: return .library
    case .queue: return .queue
    case .statistics: return .statistics
    case .history: return .history
    }
  }

  init?(destination: SidebarDestination) {
    switch destination {
    case .library, .photos, .videos, .favorites: self = .library
    case .queue: self = .queue
    case .statistics: self = .statistics
    case .history: self = .history
    }
  }
}

@MainActor
struct PhotoSlimiOSUnifiedRootView: View {
  @StateObject private var model = AppModel()
  @State private var workspace = PhotoSlimiOSWorkspace.library
  @State private var showsSettings = false

  var body: some View {
    ZStack {
      tabContainer

      workflowOverlay
        .zIndex(10)
    }
    .environmentObject(model)
    .task { model.bootstrap() }
    .onChange(of: workspace) { _, value in
      let destination = value.modelDestination
      if value != .library || !isLibraryDestination(model.destination) {
        model.destination = destination
      }
    }
    .onChange(of: model.destination) { _, value in
      guard let destination = PhotoSlimiOSWorkspace(destination: value) else { return }
      if workspace != destination { workspace = destination }
    }
    .sheet(isPresented: $showsSettings) {
      PhotoSlimiOSCompressionSettingsSheet(
        current: model.settings,
        mediaKind: selectedMediaKind
      ) { value in
        model.applyCompressionSettings(value)
      }
      .environmentObject(model)
    }
    .alert(item: $model.notice) { notice in
      Alert(
        title: Text(notice.title),
        message: Text(notice.message),
        dismissButton: .default(Text("好"))
      )
    }
  }

  @ViewBuilder
  private var tabContainer: some View {
    if #available(iOS 26.1, *) {
      modernTabContainer
    } else {
      legacyTabContainer
    }
  }

  private var tabView: some View {
    TabView(selection: $workspace) {
      NavigationStack {
        PhotoSlimiOSLibraryWorkspace()
      }
      .toolbar(hasSelection ? .hidden : .visible, for: .tabBar)
      .tabItem {
        Label(PhotoSlimiOSWorkspace.library.title, systemImage: PhotoSlimiOSWorkspace.library.symbol)
      }
      .tag(PhotoSlimiOSWorkspace.library)

      NavigationStack {
        PhotoSlimiOSQueueWorkspace()
      }
      .toolbar(hasSelection ? .hidden : .visible, for: .tabBar)
      .tabItem {
        Label(PhotoSlimiOSWorkspace.queue.title, systemImage: PhotoSlimiOSWorkspace.queue.symbol)
      }
      .badge(model.queue.count)
      .tag(PhotoSlimiOSWorkspace.queue)

      NavigationStack {
        PhotoSlimiOSStatisticsWorkspace()
      }
      .toolbar(hasSelection ? .hidden : .visible, for: .tabBar)
      .tabItem {
        Label(
          PhotoSlimiOSWorkspace.statistics.title,
          systemImage: PhotoSlimiOSWorkspace.statistics.symbol
        )
      }
      .tag(PhotoSlimiOSWorkspace.statistics)

      NavigationStack {
        PhotoSlimiOSHistoryWorkspace()
      }
      .toolbar(hasSelection ? .hidden : .visible, for: .tabBar)
      .tabItem {
        Label(PhotoSlimiOSWorkspace.history.title, systemImage: PhotoSlimiOSWorkspace.history.symbol)
      }
      .tag(PhotoSlimiOSWorkspace.history)
    }
  }

  @available(iOS 26.1, *)
  private var modernTabContainer: some View {
    tabView
      .tabBarMinimizeBehavior(.onScrollDown)
      .tabViewBottomAccessory(isEnabled: showsProcessingStatus) {
        PhotoSlimiOSBottomStatusBar(
          showsSettings: $showsSettings,
          startAction: model.beginSelectedTask
        )
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if hasSelection { selectionStatusCapsule }
      }
  }

  private var legacyTabContainer: some View {
    legacyTabContent
  }

  private var legacyTabContent: some View {
    tabView.safeAreaInset(edge: .bottom, spacing: 0) {
      if hasSelection {
        selectionStatusCapsule
      } else if showsProcessingStatus {
        PhotoSlimiOSBottomStatusBar(
          showsSettings: $showsSettings,
          startAction: model.beginSelectedTask
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
      }
    }
  }

  @ViewBuilder
  private var selectionStatusCapsule: some View {
    if #available(iOS 26.0, *) {
      PhotoSlimiOSBottomStatusBar(
        showsSettings: $showsSettings,
        startAction: model.beginSelectedTask
      )
      .glassEffect(.regular, in: Capsule())
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    } else {
      PhotoSlimiOSBottomStatusBar(
        showsSettings: $showsSettings,
        startAction: model.beginSelectedTask
      )
      .background(.regularMaterial, in: Capsule())
      .overlay {
        Capsule().stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
  }

  @ViewBuilder
  private var workflowOverlay: some View {
    if model.shouldForceReview {
      PhotoSlimiOSSharedReviewWorkspace()
        .transition(.opacity)
    } else if model.currentSession?.phase == .failed {
      PhotoSlimiOSFailedTaskWorkspace()
        .transition(.opacity)
    } else if model.isProcessing && !model.isTaskPanelMinimized {
      PhotoSlimiOSProcessingWorkspace()
        .transition(.opacity)
    }
  }

  private var hasSelection: Bool {
    !model.selectedIdentifiers.isEmpty
  }

  private var showsProcessingStatus: Bool {
    !hasSelection && model.isProcessing && model.isTaskPanelMinimized
  }

  private var selectedMediaKind: MediaKind? {
    let kinds = Set(model.selectedAssets.map(\.kind))
    if kinds.count == 1 { return kinds.first }
    return model.destination.mediaKind
  }

  private func isLibraryDestination(_ destination: SidebarDestination) -> Bool {
    switch destination {
    case .library, .photos, .videos, .favorites: return true
    case .queue, .statistics, .history: return false
    }
  }
}
#endif
