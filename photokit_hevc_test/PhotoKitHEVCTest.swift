import Foundation
import Photos
import AVFoundation
import CoreMedia
import AppKit
import Darwin

private let testLogURL = URL(fileURLWithPath: "/private/tmp/codex_photokit/status.log")

private func appendTestLog(_ message: String) {
    let line = message + "\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: testLogURL.path) {
            if let handle = try? FileHandle(forWritingTo: testLogURL) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            try? data.write(to: testLogURL)
        }
    }
}

enum PhotoKitHEVCTest {
    static func run() async {
        appendTestLog("run_start")
        do {
            appendTestLog("request_authorization")
            let status = await requestPhotoAccess()
            appendTestLog("authorization_status=\(status.rawValue)")
            guard status == .authorized || status == .limited else {
                throw TestError.message("Photos access was not granted. Status: \(status.rawValue)")
            }

            let videos = fetchVideos()
            print("VIDEO_COUNT=\(videos.count)")

            var candidate: Candidate?
            let inspectLimit = min(videos.count, 120)
            for index in 0..<inspectLimit {
                let asset = videos.object(at: index)
                do {
                    let avAsset = try await requestAVAsset(for: asset, allowNetwork: true)
                    let codec = codecName(for: avAsset) ?? "unknown"
                    print("INSPECT index=\(index) id=\(asset.localIdentifier) date=\(iso(asset.creationDate)) codec=\(codec)")
                    if !isHEVC(codec) {
                        candidate = Candidate(photoAsset: asset, avAsset: avAsset, codec: codec, index: index)
                        break
                    }
                } catch {
                    print("INSPECT_ERROR index=\(index) id=\(asset.localIdentifier) error=\(error.localizedDescription)")
                }
            }

            guard let candidate else {
                throw TestError.message("No non-HEVC video found in the first \(inspectLimit) oldest videos.")
            }

            printCandidate(candidate)
            let outputURL = try await transcodeToHEVC(candidate.avAsset, candidate: candidate)
            printOutputComparison(source: candidate.avAsset, outputURL: outputURL)
            print("OUTPUT=\(outputURL.path)")
            print("PHOTOS_LIBRARY_CHANGED=false")
        } catch {
            appendTestLog("error=\(error.localizedDescription)")
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func requestPhotoAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                appendTestLog("authorization_callback=\(status.rawValue)")
                continuation.resume(returning: status)
            }
        }
    }

    private static func fetchVideos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: .video, options: options)
    }

    private static func requestAVAsset(for asset: PHAsset, allowNetwork: Bool) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .original
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = allowNetwork

            var didResume = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard !didResume else { return }
                if let error = info?[PHImageErrorKey] as? Error {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }
                if let avAsset {
                    didResume = true
                    continuation.resume(returning: avAsset)
                    return
                }
                if let inCloud = info?[PHImageResultIsInCloudKey] as? Bool, inCloud {
                    didResume = true
                    continuation.resume(throwing: TestError.message("Asset requires iCloud download"))
                }
            }
        }
    }

    private static func codecName(for asset: AVAsset) -> String? {
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        guard let rawDescription = track.formatDescriptions.first else { return nil }
        let description = rawDescription as! CMFormatDescription
        return fourCC(CMFormatDescriptionGetMediaSubType(description))
    }

    private static func isHEVC(_ codec: String) -> Bool {
        codec == "hvc1" || codec == "hev1"
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "%08x", value)
    }

    private static func transcodeToHEVC(_ source: AVAsset, candidate: Candidate) async throws -> URL {
        guard AVAssetExportSession.exportPresets(compatibleWith: source).contains(AVAssetExportPresetHEVCHighestQuality) else {
            throw TestError.message("This Mac does not expose AVAssetExportPresetHEVCHighestQuality for the selected video.")
        }

        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PhotoKitHEVCTest", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let name = "old-video-\(candidate.index)-hevc.mov"
        let outputURL = outputDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: outputURL)

        guard let session = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetHEVCHighestQuality) else {
            throw TestError.message("Could not create an HEVC export session.")
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
                    continuation.resume(throwing: session.error ?? TestError.message("HEVC export failed"))
                case .cancelled:
                    continuation.resume(throwing: TestError.message("HEVC export cancelled"))
                default:
                    continuation.resume(throwing: TestError.message("HEVC export ended with status \(session.status.rawValue)"))
                }
            }
        }
        return outputURL
    }

    private static func printCandidate(_ candidate: Candidate) {
        let asset = candidate.photoAsset
        print("CANDIDATE_INDEX=\(candidate.index)")
        print("CANDIDATE_ID=\(asset.localIdentifier)")
        print("CANDIDATE_DATE=\(iso(asset.creationDate))")
        print("CANDIDATE_DURATION=\(asset.duration)")
        print("CANDIDATE_PIXEL_SIZE=\(asset.pixelWidth)x\(asset.pixelHeight)")
        print("CANDIDATE_CODEC=\(candidate.codec)")
        print("CANDIDATE_LOCATION=\(locationString(asset.location))")
        print("CANDIDATE_FILENAME=\(PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "unknown")")
        print("CANDIDATE_FAVORITE=\(asset.isFavorite)")
        print("CANDIDATE_HIDDEN=\(asset.isHidden)")
        print("CANDIDATE_ADDED_DATE=unavailable_via_public_PhotoKit")
    }

    private static func printOutputComparison(source: AVAsset, outputURL: URL) {
        let output = AVURLAsset(url: outputURL)
        let sourceTrack = source.tracks(withMediaType: .video).first
        let outputTrack = output.tracks(withMediaType: .video).first
        let sourceCodec = codecName(for: source) ?? "unknown"
        let outputCodec = codecName(for: output) ?? "unknown"
        print("SOURCE_CODEC=\(sourceCodec)")
        print("OUTPUT_CODEC=\(outputCodec)")
        print("SOURCE_DURATION=\(CMTimeGetSeconds(source.duration))")
        print("OUTPUT_DURATION=\(CMTimeGetSeconds(output.duration))")
        print("SOURCE_NOMINAL_FPS=\(sourceTrack?.nominalFrameRate ?? 0)")
        print("OUTPUT_NOMINAL_FPS=\(outputTrack?.nominalFrameRate ?? 0)")
        print("SOURCE_ESTIMATED_DATA_RATE=\(sourceTrack?.estimatedDataRate ?? 0)")
        print("OUTPUT_ESTIMATED_DATA_RATE=\(outputTrack?.estimatedDataRate ?? 0)")
        print("SOURCE_CONTAINS_HDR=\(sourceTrack?.hasMediaCharacteristic(.containsHDRVideo) ?? false)")
        print("OUTPUT_CONTAINS_HDR=\(outputTrack?.hasMediaCharacteristic(.containsHDRVideo) ?? false)")
        print("SOURCE_NATURAL_SIZE=\(sourceTrack?.naturalSize ?? .zero)")
        print("OUTPUT_NATURAL_SIZE=\(outputTrack?.naturalSize ?? .zero)")
        print("SOURCE_METADATA_COUNT=\(source.metadata.count)")
        print("OUTPUT_METADATA_COUNT=\(output.metadata.count)")
        printMetadata(label: "SOURCE", items: source.metadata)
        printMetadata(label: "OUTPUT", items: output.metadata)
        if let sourceURLAsset = source as? AVURLAsset,
           let sourceSize = try? sourceURLAsset.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            print("SOURCE_FILE_SIZE=\(sourceSize ?? 0)")
        }
        if let bytes = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            print("OUTPUT_FILE_SIZE=\(bytes)")
        }
    }

    private static func printMetadata(label: String, items: [AVMetadataItem]) {
        for item in items {
            let key = item.identifier?.rawValue ?? String(describing: item.key)
            let value: String
            if let stringValue = item.stringValue {
                value = stringValue
            } else if let numberValue = item.numberValue {
                value = numberValue.stringValue
            } else if let dateValue = item.dateValue {
                value = ISO8601DateFormatter().string(from: dateValue)
            } else {
                value = String(describing: item.value)
            }
            print("\(label)_METADATA \(key)=\(value)")
        }
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

private struct Candidate {
    let photoAsset: PHAsset
    let avAsset: AVAsset
    let codec: String
    let index: Int
}

private enum TestError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appendTestLog("did_finish_launching")
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "PhotoKit HEVC Test"
        window.isReleasedWhenClosed = false
        window.contentView = NSTextField(labelWithString: "Scanning one old non-HEVC video…")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        Task {
            appendTestLog("starting_task")
            await PhotoKitHEVCTest.run()
            appendTestLog("terminating")
            NSApp.terminate(nil)
        }
    }
}

@main
struct PhotoKitHEVCTestMain {
    static func main() {
        _ = freopen(testLogURL.path, "a", stdout)
        _ = freopen(testLogURL.path, "a", stderr)
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
