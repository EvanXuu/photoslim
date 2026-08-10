import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreLocation
import Darwin
import Foundation
import Photos

private let logURL = URL(fileURLWithPath: "/private/tmp/codex_avasset_presets/result.log")
private let outputDirectory = URL(fileURLWithPath: "/private/tmp/codex_avasset_presets/outputs", isDirectory: true)

private func appendLog(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    try? FileManager.default.createDirectory(
        at: logURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if let handle = try? FileHandle(forWritingTo: logURL) {
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

private func emit(_ message: String) {
    appendLog(message)
    fputs((message + "\n"), stdout)
    fflush(stdout)
}

private struct Candidate {
    let asset: PHAsset
    let avAsset: AVAsset
    let codec: String
    let index: Int
}

private struct QualityMetrics {
    let sampleCount: Int
    let meanAbsoluteError: Double
    let psnr: Double
}

private struct ExportResult {
    let preset: String
    let outputURL: URL
    let outputCodec: String
    let sourceBytes: Int64
    let outputBytes: Int64
    let sourceDuration: Double
    let outputDuration: Double
    let sourceRate: Double
    let outputRate: Double
    let sourceSize: CGSize
    let outputSize: CGSize
    let sourceFPS: Float
    let outputFPS: Float
    let sourceMetadata: Set<String>
    let outputMetadata: Set<String>
    let quality: QualityMetrics?
}

private enum PresetTestError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

private enum PhotoKitExportPresetsTest {
    static func run() async {
        appendLog("start")
        do {
            try prepareOutputDirectory()

            let status = await ensurePhotoAccess()
            appendLog("authorization_status=\(status.rawValue)")
            guard status == .authorized || status == .limited else {
                throw PresetTestError.message("Photos access was not granted: \(status.rawValue)")
            }

            let videos = fetchVideos()
            appendLog("VIDEO_COUNT=\(videos.count)")

            let candidate = try await findH264Candidate(in: videos)
            printCandidate(candidate)

            let compatible = AVAssetExportSession.exportPresets(compatibleWith: candidate.avAsset)
            appendLog("COMPATIBLE_PRESET_COUNT=\(compatible.count)")
            appendLog("COMPATIBLE_PRESETS=\(compatible.sorted().joined(separator: " | "))")

            let hevcPresets = compatible
                .filter { $0.localizedCaseInsensitiveContains("hevc") }
                .sorted()
            guard !hevcPresets.isEmpty else {
                throw PresetTestError.message("No compatible HEVC export preset was exposed for this video")
            }
            appendLog("HEVC_PRESET_COUNT=\(hevcPresets.count)")

            var passed = 0
            for (index, preset) in hevcPresets.enumerated() {
                appendLog("PRESET_START index=\(index + 1)/\(hevcPresets.count) name=\(preset)")
                do {
                    let result = try await export(
                        source: candidate.avAsset,
                        preset: preset,
                        sourceIndex: candidate.index,
                        ordinal: index
                    )
                    printResult(result)
                    passed += 1
                } catch {
                    appendLog("PRESET_ERROR name=\(preset) error=\(error.localizedDescription)")
                }
            }

            appendLog("PRESET_TEST_SUMMARY passed=\(passed) total=\(hevcPresets.count)")
            appendLog("PHOTOS_LIBRARY_CHANGED=false")
            appendLog("completed=true")
        } catch {
            appendLog("ERROR=\(error.localizedDescription)")
            appendLog("ERROR=\(error.localizedDescription)")
        }
    }

    private static func prepareOutputDirectory() throws {
        if FileManager.default.fileExists(atPath: outputDirectory.path) {
            try FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private static func ensurePhotoAccess() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func fetchVideos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: .video, options: options)
    }

    private static func findH264Candidate(in videos: PHFetchResult<PHAsset>) async throws -> Candidate {
        let inspectLimit = min(videos.count, 80)
        var bestCandidate: Candidate?
        var bestRate = 0.0
        for index in 0..<inspectLimit {
            let asset = videos.object(at: index)
            do {
                let avAsset = try await requestAVAsset(for: asset)
                let codec = codecName(for: avAsset) ?? "unknown"
                appendLog("INSPECT index=\(index) id=\(asset.localIdentifier) codec=\(codec)")
                if codec == "avc1" || codec == "avc3" {
                    let trackRate = Double(
                        avAsset.tracks(withMediaType: .video).first?.estimatedDataRate ?? 0
                    )
                    let nominalFPS = Double(
                        avAsset.tracks(withMediaType: .video).first?.nominalFrameRate ?? 0
                    )
                    let duration = max(CMTimeGetSeconds(avAsset.duration), 0.001)
                    let measuredRate = Double(fileSize(of: avAsset) ?? 0) * 8 / duration
                    let score = max(trackRate, measuredRate)
                    appendLog("H264_CANDIDATE index=\(index) track_rate=\(trackRate) measured_rate=\(measuredRate) fps=\(nominalFPS)")
                    let candidate = Candidate(asset: asset, avAsset: avAsset, codec: codec, index: index)
                    let normalFrameRate = nominalFPS == 0 || nominalFPS <= 60
                    if duration >= 5 && normalFrameRate && (score > bestRate || bestCandidate == nil) {
                        bestRate = score
                        bestCandidate = candidate
                    }
                }
            } catch {
                appendLog("INSPECT_ERROR index=\(index) id=\(asset.localIdentifier) error=\(error.localizedDescription)")
            }
        }
        if let bestCandidate {
            return bestCandidate
        }
        throw PresetTestError.message("No H.264 video found in the first \(inspectLimit) videos")
    }

    private static func requestAVAsset(for asset: PHAsset) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.version = .original
            options.deliveryMode = .highQualityFormat
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
                } else {
                    didResume = true
                    continuation.resume(throwing: PresetTestError.message("Photos returned no AVAsset"))
                }
            }
        }
    }

    private static func export(
        source: AVAsset,
        preset: String,
        sourceIndex: Int,
        ordinal: Int
    ) async throws -> ExportResult {
        guard let session = AVAssetExportSession(asset: source, presetName: preset) else {
            throw PresetTestError.message("Could not create AVAssetExportSession for \(preset)")
        }

        let fileType: AVFileType
        if session.supportedFileTypes.contains(.mov) {
            fileType = .mov
        } else if session.supportedFileTypes.contains(.mp4) {
            fileType = .mp4
        } else {
            throw PresetTestError.message(
                "No MOV/MP4 output type for \(preset): \(session.supportedFileTypes.map(\.rawValue).joined(separator: ","))"
            )
        }

        let safeName = preset.replacingOccurrences(of: "/", with: "-")
        let outputURL = outputDirectory.appendingPathComponent(
            "video-\(sourceIndex)-\(ordinal)-\(safeName).\(fileType == .mp4 ? "mp4" : "mov")"
        )
        try? FileManager.default.removeItem(at: outputURL)

        session.outputURL = outputURL
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = false
        session.metadata = source.metadata

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: session.error ?? PresetTestError.message("Export failed"))
                case .cancelled:
                    continuation.resume(throwing: PresetTestError.message("Export cancelled"))
                default:
                    continuation.resume(
                        throwing: PresetTestError.message("Export ended with status \(session.status.rawValue)")
                    )
                }
            }
        }

        let output = AVURLAsset(url: outputURL)
        let sourceTrack = source.tracks(withMediaType: .video).first
        let outputTrack = output.tracks(withMediaType: .video).first
        let sourceDuration = CMTimeGetSeconds(source.duration)
        let outputDuration = CMTimeGetSeconds(output.duration)
        let sourceBytes = fileSize(of: source) ?? 0
        let outputBytes = fileSize(of: outputURL) ?? 0
        let sourceMetadata = metadataKeys(source.metadata)
        let outputMetadata = metadataKeys(output.metadata)

        return ExportResult(
            preset: preset,
            outputURL: outputURL,
            outputCodec: codecName(for: output) ?? "unknown",
            sourceBytes: sourceBytes,
            outputBytes: outputBytes,
            sourceDuration: sourceDuration,
            outputDuration: outputDuration,
            sourceRate: Double(sourceTrack?.estimatedDataRate ?? 0),
            outputRate: Double(outputTrack?.estimatedDataRate ?? 0),
            sourceSize: sourceTrack?.naturalSize ?? .zero,
            outputSize: outputTrack?.naturalSize ?? .zero,
            sourceFPS: sourceTrack?.nominalFrameRate ?? 0,
            outputFPS: outputTrack?.nominalFrameRate ?? 0,
            sourceMetadata: sourceMetadata,
            outputMetadata: outputMetadata,
            quality: try? compareQuality(source: source, output: output)
        )
    }

    private static func printCandidate(_ candidate: Candidate) {
        let track = candidate.avAsset.tracks(withMediaType: .video).first
        let sourceBytes = fileSize(of: candidate.avAsset) ?? 0
        appendLog("CANDIDATE_INDEX=\(candidate.index)")
        appendLog("CANDIDATE_ID=\(candidate.asset.localIdentifier)")
        appendLog("CANDIDATE_FILENAME=\(PHAssetResource.assetResources(for: candidate.asset).first?.originalFilename ?? "unknown")")
        appendLog("CANDIDATE_DATE=\(iso(candidate.asset.creationDate))")
        appendLog("CANDIDATE_CODEC=\(candidate.codec)")
        appendLog("CANDIDATE_BYTES=\(sourceBytes)")
        appendLog("CANDIDATE_DURATION=\(CMTimeGetSeconds(candidate.avAsset.duration))")
        appendLog("CANDIDATE_PIXEL_SIZE=\(track?.naturalSize ?? .zero)")
        appendLog("CANDIDATE_ESTIMATED_RATE=\(track?.estimatedDataRate ?? 0)")
        appendLog("CANDIDATE_FAVORITE=\(candidate.asset.isFavorite)")
        appendLog("CANDIDATE_HIDDEN=\(candidate.asset.isHidden)")
        appendLog("CANDIDATE_LOCATION=\(locationString(candidate.asset.location))")
    }

    private static func printResult(_ result: ExportResult) {
        let sizeRatio = result.sourceBytes > 0
            ? Double(result.outputBytes) / Double(result.sourceBytes)
            : 0
        let savings = result.sourceBytes > 0 ? 1 - sizeRatio : 0
        let rateRatio = result.sourceRate > 0 ? result.outputRate / result.sourceRate : 0
        let quality = result.quality.map {
            "samples=\($0.sampleCount),psnr_db=\(format($0.psnr)),mae=\(format($0.meanAbsoluteError))"
        } ?? "unavailable"

        appendLog("PRESET_RESULT name=\(result.preset)")
        appendLog("OUTPUT=\(result.outputURL.path)")
        appendLog("OUTPUT_CODEC=\(result.outputCodec)")
        appendLog("SOURCE_BYTES=\(result.sourceBytes)")
        appendLog("OUTPUT_BYTES=\(result.outputBytes)")
        appendLog("SIZE_RATIO=\(format(sizeRatio))")
        appendLog("SAVINGS_RATIO=\(format(savings))")
        appendLog("SOURCE_RATE=\(format(result.sourceRate))")
        appendLog("OUTPUT_RATE=\(format(result.outputRate))")
        appendLog("RATE_RATIO=\(format(rateRatio))")
        appendLog("SOURCE_DURATION=\(format(result.sourceDuration))")
        appendLog("OUTPUT_DURATION=\(format(result.outputDuration))")
        appendLog("SOURCE_FPS=\(format(Double(result.sourceFPS)))")
        appendLog("OUTPUT_FPS=\(format(Double(result.outputFPS)))")
        appendLog("SOURCE_SIZE=\(result.sourceSize)")
        appendLog("OUTPUT_SIZE=\(result.outputSize)")
        appendLog("METADATA_SOURCE_COUNT=\(result.sourceMetadata.count)")
        appendLog("METADATA_OUTPUT_COUNT=\(result.outputMetadata.count)")
        appendLog("METADATA_KEYS_PRESERVED=\(result.sourceMetadata.isSubset(of: result.outputMetadata))")
        appendLog("QUALITY=\(quality)")
        appendLog("PRESET_END name=\(result.preset)")
    }

    private static func compareQuality(source: AVAsset, output: AVAsset) throws -> QualityMetrics {
        let sourceDuration = CMTimeGetSeconds(source.duration)
        let outputDuration = CMTimeGetSeconds(output.duration)
        let duration = min(sourceDuration, outputDuration)
        guard duration.isFinite, duration > 0 else {
            throw PresetTestError.message("Invalid duration for quality comparison")
        }

        let fractions: [Double] = [0.10, 0.30, 0.50, 0.70, 0.90]
        var absoluteError = 0.0
        var squaredError = 0.0
        var comparedSamples = 0

        for fraction in fractions {
            let seconds = max(0.01, min(duration - 0.01, duration * fraction))
            let sourceImage = try image(from: source, at: CMTime(seconds: seconds, preferredTimescale: 600))
            let outputImage = try image(from: output, at: CMTime(seconds: seconds, preferredTimescale: 600))
            guard let sourcePixels = normalizedPixels(sourceImage),
                  let outputPixels = normalizedPixels(outputImage),
                  sourcePixels.width == outputPixels.width,
                  sourcePixels.height == outputPixels.height,
                  sourcePixels.bytes.count == outputPixels.bytes.count else {
                continue
            }

            let pixelCount = sourcePixels.width * sourcePixels.height
            guard pixelCount > 0 else { continue }
            var index = 0
            while index + 2 < sourcePixels.bytes.count {
                for channel in 0..<3 {
                    let delta = Double(abs(Int(sourcePixels.bytes[index + channel]) - Int(outputPixels.bytes[index + channel])))
                    absoluteError += delta
                    squaredError += delta * delta
                }
                index += 4
            }
            comparedSamples += 1
        }

        guard comparedSamples > 0 else {
            throw PresetTestError.message("Could not compare matching frames")
        }
        let channelCount = Double(comparedSamples) * Double(try framePixelCount(source: source, output: output)) * 3
        let mae = absoluteError / max(1, channelCount)
        let mse = squaredError / max(1, channelCount)
        let psnr = mse == 0 ? .infinity : 10 * log10((255 * 255) / mse)
        return QualityMetrics(sampleCount: comparedSamples, meanAbsoluteError: mae, psnr: psnr)
    }

    private static func framePixelCount(source: AVAsset, output: AVAsset) throws -> Int {
        let sourceTrack = source.tracks(withMediaType: .video).first
        let outputTrack = output.tracks(withMediaType: .video).first
        let sourceSize = sourceTrack?.naturalSize ?? .zero
        let outputSize = outputTrack?.naturalSize ?? .zero
        let width = min(abs(sourceSize.width), abs(outputSize.width))
        let height = min(abs(sourceSize.height), abs(outputSize.height))
        guard width > 0, height > 0 else {
            throw PresetTestError.message("Invalid video dimensions")
        }
        let scale = min(640 / width, 640 / height, 1)
        return max(1, Int((width * scale).rounded())) * max(1, Int((height * scale).rounded()))
    }

    private struct PixelBuffer {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private static func image(from asset: AVAsset, at time: CMTime) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        var actualTime = CMTime.zero
        return try generator.copyCGImage(at: time, actualTime: &actualTime)
    }

    private static func normalizedPixels(_ image: CGImage) -> PixelBuffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var didDraw = false
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            didDraw = true
        }
        guard didDraw else { return nil }
        return PixelBuffer(width: width, height: height, bytes: bytes)
    }

    private static func codecName(for asset: AVAsset) -> String? {
        guard let track = asset.tracks(withMediaType: .video).first,
              let rawDescription = track.formatDescriptions.first else {
            return nil
        }
        let description = rawDescription as! CMFormatDescription
        return fourCC(CMFormatDescriptionGetMediaSubType(description))
    }

    private static func fileSize(of asset: AVAsset) -> Int64? {
        guard let urlAsset = asset as? AVURLAsset else { return nil }
        return fileSize(of: urlAsset.url)
    }

    private static func fileSize(of url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
    }

    private static func metadataKeys(_ metadata: [AVMetadataItem]) -> Set<String> {
        Set(metadata.map { $0.identifier?.rawValue ?? String(describing: $0.key) })
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

    private static func format(_ value: Double) -> String {
        if value.isInfinite { return "inf" }
        return String(format: "%.4f", value)
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

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AVAssetExportSession Preset Test"
        window.contentView = NSTextField(labelWithString: "Testing compatible HEVC export presets…")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        Task {
            await PhotoKitExportPresetsTest.run()
            fflush(stdout)
            fflush(stderr)
            NSApp.terminate(nil)
        }
    }
}

@main
struct PhotoKitExportPresetsTestMain {
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
