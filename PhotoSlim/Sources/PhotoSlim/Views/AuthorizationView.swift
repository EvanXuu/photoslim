import AppKit
import SwiftUI

struct AuthorizationView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 24) {
      ZStack {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(PhotoSlimTheme.signalSoft)
          .frame(width: 84, height: 84)
        Image(systemName: "photo.stack")
          .font(.system(size: 34, weight: .medium))
          .foregroundStyle(PhotoSlimTheme.signal)
      }

      VStack(spacing: 9) {
        Text("安全整理你的照片图库")
          .font(.system(size: 26, weight: .semibold))
          .foregroundStyle(PhotoSlimTheme.ink)
        Text("PhotoSlim 只在本机处理照片。压缩结果检查无误后，\n原件仍会保留，直到你亲自确认。")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .lineSpacing(3)
      }

      if model.accessState == .notDetermined {
        Button("允许访问照片") { model.requestAccessAndScan() }
          .buttonStyle(SignalButtonStyle())
      } else {
        VStack(spacing: 12) {
          Text(model.accessState.title)
            .font(.system(size: 13, weight: .medium))
          Button("打开系统设置") {
            if let url = URL(
              string:
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Photos"
            ) {
              NSWorkspace.shared.open(url)
            }
          }
        }
      }

      HStack(spacing: 22) {
        permissionFact("不改数据库", symbol: "checkmark.shield")
        permissionFact("本机压缩", symbol: "desktopcomputer")
        permissionFact("删除前审核", symbol: "eye")
      }
      .padding(.top, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(PhotoSlimTheme.canvas)
  }

  private func permissionFact(_ title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.secondary)
  }
}
