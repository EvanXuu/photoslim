import SwiftUI

enum PhotoSlimTheme {
  static let canvas = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.075, alpha: 1)
        : NSColor(calibratedRed: 0.953, green: 0.941, blue: 0.914, alpha: 1)
    })

  static let surface = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.115, alpha: 1)
        : NSColor(calibratedRed: 0.986, green: 0.980, blue: 0.961, alpha: 1)
    })

  static let raisedSurface = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.16, alpha: 1)
        : .white
    })

  static let ink = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.94, alpha: 1)
        : NSColor(calibratedRed: 0.105, green: 0.102, blue: 0.094, alpha: 1)
    })

  static let secondaryInk = Color.secondary
  static let signal = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.871, green: 0.518, blue: 0.212, alpha: 1)
        : NSColor(calibratedRed: 0.725, green: 0.341, blue: 0.059, alpha: 1)
    })
  static let signalForeground = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedWhite: 0.075, alpha: 1)
        : .white
    })
  static let signalSoft = signal.opacity(0.12)
  static let success = Color(nsColor: NSColor.systemGreen)
  static let warning = Color(nsColor: NSColor.systemOrange)
  static let danger = Color(nsColor: NSColor.systemRed)
  static let hairline = Color.primary.opacity(0.11)

  static let sidebarWidth: CGFloat = 224
  static let inspectorWidth: CGFloat = 286
  static let controlRadius: CGFloat = 9
  static let cardRadius: CGFloat = 12
  static let panelRadius: CGFloat = 16
  static let compactSpacing: CGFloat = 8
  static let sectionSpacing: CGFloat = 18
}

struct SignalButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(PhotoSlimTheme.signalForeground)
      .padding(.horizontal, 16)
      .frame(minHeight: 32)
      .background(
        RoundedRectangle(cornerRadius: PhotoSlimTheme.controlRadius, style: .continuous)
          .fill(
            PhotoSlimTheme.signal.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.36))
      )
  }
}

struct InsetPanelModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(PhotoSlimTheme.surface)
      .clipShape(RoundedRectangle(cornerRadius: PhotoSlimTheme.panelRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: PhotoSlimTheme.panelRadius, style: .continuous)
          .stroke(PhotoSlimTheme.hairline, lineWidth: 1)
      }
  }
}

extension View {
  func insetPanel() -> some View { modifier(InsetPanelModifier()) }
}
