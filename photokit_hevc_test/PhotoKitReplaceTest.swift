import Foundation
import Photos
import AVFoundation
import CoreMedia
import AppKit
import CoreLocation
import Darwin

private let logURL = URL(fileURLWithPath: "/private/tmp/codex_photokit/favorite_replacement.log")
private let targetAssetID = "521B05C3-3E55-4602-9067-0AA1DC0D31DA/L0/001"
private let convertedURL = URL(fileURLWithPath: "/private/tmp/codex_photokit/favorite-video-hevc.mov")

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

enum PhotoKitReplaceTest {
    static func run() async {
        appendLog("start")
        do {
            let status = await ensurePhotoAccess()
            appendLog("authorization_status=\(status.rawValue)")
            guard status == .authorized || status == .limited else {
                throw ReplaceError.message("Photos access was not granted: \(status.rawValue)")
            }

            guard FileManager.default.fileExists(atPath: convertedURL.path) else {
                throw ReplaceError.message("Converted HEVC file is missing: \(convertedURL.path)")
            }
            let convertedAsset = AVURLAsset(url: convertedURL)
            let convertedCodec = codecName(for: convertedAsset) ?? "unknown"
            guard isHEVC(convertedCodec) else {
                throw ReplaceError.message("The test file is not HEVC: \(convertedCodec)")
            }
            appendLog("converted_file_codec=\(convertedCodec)")

            guard let original = fetchAsset(localIdentifier: targetAssetID) else {
                throw ReplaceError.message("Original asset was not found or was already deleted")
            }
            appendLog("original_id=\(original.localIdentifier)")
            appendLog("original_date=\(iso(original.creationDate))")
            appendLog("original_location=\(locationString(original.location))")
            appendLog("original_favorite=\(original.isFavorite)")
            appendLog("original_hidden=\(original.isHidden)")
            appendLog("original_filename=\(PHAssetResource.assetResources(for: original).first?.originalFilename ?? "unknown")")
            appendLog("original_added_date=unavailable_via_public_PhotoKit")

            let albums = albumsContaining(original)
            appendLog("original_album_count=\(albums.count)")

            let newAssetID = try await createAsset(from: convertedURL, copying: original, albums: albums)
            appendLog("new_id=\(newAssetID)")

            guard let newAsset = fetchAsset(localIdentifier: newAssetID) else {
                throw ReplaceError.message("New asset was created but could not be fetched")
            }
            let newAVAsset = try await requestAVAsset(for: newAsset)
            let newCodec = codecName(for: newAVAsset) ?? "unknown"
            appendLog("new_codec=\(newCodec)")
            appendLog("new_date=\(iso(newAsset.creationDate))")
            appendLog("new_location=\(locationString(newAsset.location))")
            appendLog("new_favorite=\(newAsset.isFavorite)")
            appendLog("new_hidden=\(newAsset.isHidden)")
            appendLog("new_filename=\(PHAssetResource.assetResources(for: newAsset).first?.originalFilename ?? "unknown")")
            appendLog("new_added_date=unavailable_via_public_PhotoKit")
            appendLog("new_album_count=\(albumsContaining(newAsset).count)")

            guard isHEVC(newCodec),
                  newAsset.creationDate == original.creationDate,
                  newAsset.location?.coordinate.latitude == original.location?.coordinate.latitude,
                  newAsset.location?.coordinate.longitude == original.location?.coordinate.longitude,
                  newAsset.isFavorite == original.isFavorite,
                  newAsset.isHidden == original.isHidden else {
                throw ReplaceError.message("New asset validation failed; original was not deleted")
            }

            try await deleteOriginal(localIdentifier: targetAssetID)
            let originalStillExists = fetchAsset(localIdentifier: targetAssetID) != nil
            let newStillExists = fetchAsset(localIdentifier: newAssetID) != nil
            appendLog("original_present_after_delete=\(originalStillExists)")
            appendLog("new_present_after_delete=\(newStillExists)")
            appendLog("original_moved_to_recently_deleted=true")
            appendLog("PHOTOS_LIBRARY_CHANGED=true")
            appendLog("replacement_completed=true")
        } catch {
            appendLog("ERROR=\(error.localizedDescription)")
            appendLog("replacement_completed=false")
        }
    }

    private static func ensurePhotoAccess() async -> PHAuthorizationStatus {
        appendLog("before_authorization_status")
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

    private static func fetchAsset(localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    private static func createAsset(from url: URL, copying original: PHAsset, albums: [PHAssetCollection]) async throws -> String {
        var placeholderID: String?
        var creationRequestFailed = false

        try await performChanges {
            guard let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url),
                  let placeholder = request.placeholderForCreatedAsset else {
                creationRequestFailed = true
                return
            }

            request.creationDate = original.creationDate
            request.location = original.location
            request.isFavorite = original.isFavorite
            request.isHidden = original.isHidden
            placeholderID = placeholder.localIdentifier

            for album in albums {
                if let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                    albumRequest.addAssets(NSArray(object: placeholder))
                }
            }
        }

        if creationRequestFailed {
            throw ReplaceError.message("Photos rejected the HEVC asset creation request")
        }
        guard let placeholderID else {
            throw ReplaceError.message("Photos did not return a placeholder for the new asset")
        }
        return placeholderID
    }

    private static func deleteOriginal(localIdentifier: String) async throws {
        guard let original = fetchAsset(localIdentifier: localIdentifier) else {
            throw ReplaceError.message("Original asset disappeared before deletion")
        }
        try await performChanges {
            PHAssetChangeRequest.deleteAssets(NSArray(object: original))
        }
    }

    private static func albumsContaining(_ asset: PHAsset) -> [PHAssetCollection] {
        let allAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var matches: [PHAssetCollection] = []
        for index in 0..<allAlbums.count {
            let album = allAlbums.object(at: index)
            let assets = PHAsset.fetchAssets(in: album, options: nil)
            for assetIndex in 0..<assets.count {
                if assets.object(at: assetIndex).localIdentifier == asset.localIdentifier {
                    matches.append(album)
                    break
                }
            }
        }
        return matches
    }

    private static func performChanges(_ changes: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? ReplaceError.message("Photos change request failed"))
                }
            }
        }
    }

    private static func requestAVAsset(for asset: PHAsset) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .original
            options.isNetworkAccessAllowed = true
            var didResume = false

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard !didResume else { return }
                if let error = info?[PHImageErrorKey] as? Error {
                    didResume = true
                    continuation.resume(throwing: error)
                } else if let avAsset {
                    didResume = true
                    continuation.resume(returning: avAsset)
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

private enum ReplaceError: LocalizedError {
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
        window.title = "PhotoKit HEVC Replacement Test"
        window.contentView = NSTextField(labelWithString: "Creating HEVC asset, validating, then deleting original…")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        Task {
            await PhotoKitReplaceTest.run()
            NSApp.terminate(nil)
        }
    }
}

@main
struct PhotoKitReplaceTestMain {
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
