import Foundation

/// Container-based sizing: neither device names nor screen bounds decide layout.
public enum AdaptiveMediaLayout {
    public static func columnCount(width: Double, accessibilitySize: Bool = false) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let minimumTileWidth = accessibilitySize ? 240.0 : 156.0
        return max(1, min(8, Int(floor((max(0, width - 24) + 10) / (minimumTileWidth + 10)))))
    }
}
