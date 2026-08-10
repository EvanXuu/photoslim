import AppKit
import SwiftUI

final class PhotoSlimAppDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard model?.requiresQuitConfirmation == true else { return .terminateNow }

    let first = NSAlert()
    first.alertStyle = .warning
    first.messageText = "任务尚未完成"
    first.informativeText = "退出会中断当前操作或离开待审核会话。下一次打开 PhotoSlim 时会从持久化账本恢复。"
    first.addButton(withTitle: "留在 PhotoSlim")
    first.addButton(withTitle: "仍要退出…")
    guard first.runModal() == .alertSecondButtonReturn else { return .terminateCancel }

    let second = NSAlert()
    second.alertStyle = .critical
    second.messageText = "确认退出并保留会话？"
    second.informativeText = "会话不会被清除。若压缩副本已创建，重新打开后仍必须选择“撤回压缩副本”或“确认删除原件”。"
    second.addButton(withTitle: "取消")
    second.addButton(withTitle: "退出并保留会话")
    return second.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
  }
}

@main
struct PhotoSlimApp: App {
  @NSApplicationDelegateAdaptor(PhotoSlimAppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 980, minHeight: 660)
        .onAppear {
          appDelegate.model = model
          model.bootstrap()
        }
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(after: .sidebar) {
        Button("扫描照片图库变更") { model.scanLibrary() }
          .keyboardShortcut("r", modifiers: [.command])
          .disabled(!model.accessState.canRead || model.isScanning)
      }
    }
  }
}
