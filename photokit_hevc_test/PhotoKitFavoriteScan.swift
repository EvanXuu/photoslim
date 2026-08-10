import Foundation
import Photos
import AVFoundation
import CoreMedia
import AppKit
import CoreLocation
import Darwin

private let logURL = URL(fileURLWithPath: "/private/tmp/codex_photokit/favorite_scan.log")
private let outputURL = URL(fileURLWithPath: "/private/tmp/codex_photokit/favorite-video-hevc.mov")

private func appendLog(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

enum PhotoKitFavoriteScan {
    static func run() async {
        appendLog("start")
        do {
            let status = await requestPhotoAccess()
            appendLog("authorization_status=\(status.rawValue)")
            guard status == .authorized || status == .limited else {
                throw ScanError.message("Photos access was not granted: \(status.rawValue)")
            }

            let videos = fetchFavoriteVideos()
            appendLog("favorite_video_count=\(videos.count)")

            var candidate: (asset: PHAsset, avAsset: AVAsset, codec: String, index: Int)?
            for index in 0..<videos.count {
                let asset = videos.object(at: index)
                do {
                    let result = try await requestAVAsset(for: asset)
                    let codec = codecName(for: result.asset) ?? "unknown"
                    appendLog("inspect index=\(index) id=\(asset.localIdentifier) date=\(iso(asset.creationDate)) codec=\(codec) in_cloud=\(result.inCloud)")
                    if !isHEVC(codec) {
                        candidate = (asset, result.asset, codec, index)
                        break
                    }
                } catch {
                    appendLog("inspect_error index=\(index) id=\(asset.localIdentifier) error=\(error.localizedDescription)")
                }
            }

            guard let candidate else {
                throw ScanError.message("No favorite non-HEVC video was found")
            }

            appendLog("candidate_index=\(candidate.index)")
            appendLog("candidate_id=\(candidate.asset.localIdentifier)")
            appendLog("candidate_date=\(iso(candidate.asset.creationDate))")
            appendLog("candidate_duration=\(candidate.asset.duration)")
            appendLog("candidate_pixel_size=\(candidate.asset.pixelWidth)x\(candidate.asset.pixelHeight)")
            appendLog("candidate_codec=\(candidate.codec)")
            appendLog("candidate_location=\(locationString(candidate.asset.location))")
            appendLog("candidate_filename=\(PHAssetResource.assetResources(for: candidate.asset).first?.originalFilename ?? "unknown")")
            appendLog("candidate_favorite=\(candidate.asset.isFavorite)")
            appendLog("candidate_hidden=\(candidate.asset.isHidden)")

            try await transcodeToHEVC(candidate.avAsset)
            let outputAsset = AVURLAsset(url: outputURL)
            appendLog("output=\(outputURL.path)")
            appendLog("output_codec=\(codecName(for: outputAsset) ?? "unknown")")
            appendLog("output_duration=\(CMTimeGetSeconds(outputAsset.duration))")
            appendLog("output_file_size=\(try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)")
            appendLog("PHOTOS_LIBRARY_CHANGED=false")
            appendLog("scan_completed=true")
        } catch {
            appendLog("ERROR=\(error.localizedDescription)")
            appendLog("scan_completed=false")
        }
    }

    private static func requestPhotoAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        appendLog("current_authorization_status=\(current.rawValue)")
        guard current == .notDetermined else { return current }
        appendLog("requesting_authorization")
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                appendLog("authorization_callback=\(status.rawValue)")
                continuation.resume(returning: status)
            }
        }
    }

    private static func fetchFavoriteVideos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "isFavorite == YES")
        return PHAsset.fetchAssets(with: .video, options: options)
    }

    private static func requestAVAsset(for asset: PHAsset) async throws -> (asset: AVAsset, inCloud: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .original
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true

            var didResume = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard !didResume else { return }
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
                if let error = info?[PHImageErrorKey] as? Error {
                    didResume = true
                    continuation.resume(throwing: error)
                } else if let avAsset {
                    didResume = true
                    continuation.resume(returning: (avAsset, inCloud))
                } else {
                    didResume = true
                    continuation.resume(throwing: ScanError.message("Photos returned no AVAsset"))
                }
            }
        }
    }

    private static func transcodeToHEVC(_ source: AVAsset) async throws {
        guard AVAssetExportSession.exportPresets(compatibleWith: source).contains(AVAssetExportPresetHEVCHighestQuality) else {
            throw ScanError.message("HEVC export is unavailable for the selected video")
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)
        guard let session = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw ScanError.message("Could not create an HEVC export session")
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.shouldOptimizeForNetworkUse = false
        session.metadata = source.metadata

        try await withCheckedThrowingContinuation { continuation in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: session.error ?? ScanError.message("HEVC export failed"))
                case .cancelled:
                    continuation.resume(throwing: ScanError.message("HEVC export cancelled"))
                default:
                    continuation.resume(throwing: ScanError.message("HEVC export ended with status \(session.status.rawValue)"))
                }
            }
        }
    }

    private static func codecName(for asset: AVAsset) -> String? {
        guard let track = asset.tracks(withMediaType: .video).first,
              let rawDescription = track.formatDescriptions.first else { return nil }
        let description = rawDescription as! CMFormatDescription
        return fourCC(CMFormatDescriptionGetMediaSubType(description))
    }

    private static func isHEVC(_ codec: String) -> Bool {
        codec == "hvc1" || codec == "hev1"
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "%08x", value)
    }

    private static func iso(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func locationString(_ location: CLLocation?) -> String {
        guard let location else { return "nil" }
        return "lat=\(location.coordinate.latitude),lon=\(location.coordinate.longitude)"
    }
}

private enum ScanError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "PhotoKit Favorite HEVC Scan"
        window.contentView = NSTextField(labelWithString: "Finding one favorite non-HEVC video…")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        Task {
            await PhotoKitFavoriteScan.run()
            NSApp.terminate(nil)
        }
    }
}

@main
struct PhotoKitFavoriteScanMain {
    static func main() {
        _ = freopen(logURL.path, "a", stdout)
        _ = freopen(logURL.path, "a", stderr)
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
