import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The platform-neutral settings used by the iOS and macOS clients.
///
/// The default video route deliberately maps to Apple's HEVC export presets.
/// Detailed bitrate/GOP controls remain an opt-in concern of the existing
/// desktop manual path and can be added here without changing the PhotoKit
/// adapters.
public struct PhotoSlimCoreCompressionSettings: Codable, Equatable, Sendable {
    public var photoQuality: Double
    public var videoPreset: PhotoSlimCoreVideoPreset
    public var minimumSavingsRatio: Double

    public init(
        photoQuality: Double = 0.82,
        videoPreset: PhotoSlimCoreVideoPreset = .highestQuality,
        minimumSavingsRatio: Double = 0.08
    ) {
        self.photoQuality = min(1, max(0, photoQuality))
        self.videoPreset = videoPreset
        self.minimumSavingsRatio = min(1, max(0, minimumSavingsRatio))
    }

    public static let recommended = PhotoSlimCoreCompressionSettings()
}

public enum PhotoSlimCoreVideoPreset: String, Codable, CaseIterable, Sendable {
    case highestQuality
    case hevc2160p
    case hevc1080p

    fileprivate var exportCandidates: [String] {
        switch self {
        case .highestQuality:
            return [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHEVC3840x2160,
                    AVAssetExportPresetHEVC1920x1080]
        case .hevc2160p:
            return [AVAssetExportPresetHEVC3840x2160, AVAssetExportPresetHEVCHighestQuality,
                    AVAssetExportPresetHEVC1920x1080]
        case .hevc1080p:
            return [AVAssetExportPresetHEVC1920x1080, AVAssetExportPresetHEVC3840x2160,
                    AVAssetExportPresetHEVCHighestQuality]
        }
    }
}

public struct PhotoSlimCoreCompressionOutput: Sendable {
    public let fileURL: URL
    public let byteCount: Int64
    public let sourceByteCount: Int64?

    public init(fileURL: URL, byteCount: Int64, sourceByteCount: Int64?) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.sourceByteCount = sourceByteCount
    }

    public var savingsRatio: Double? {
        guard let sourceByteCount, sourceByteCount > 0 else { return nil }
        return Double(sourceByteCount - byteCount) / Double(sourceByteCount)
    }
}

public enum PhotoSlimCoreCompressionError: LocalizedError, Sendable {
    case invalidImage
    case cannotCreateDestination
    case imageEncodingFailed
    case missingVideoTrack
    case exportUnavailable
    case exportFailed(String)
    case outputVerification(String)
    case insufficientSavings(actual: Double, required: Double)

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法读取照片。"
        case .cannotCreateDestination:
            return "无法创建压缩结果。"
        case .imageEncodingFailed:
            return "照片压缩失败。"
        case .missingVideoTrack:
            return "无法读取视频轨道。"
        case .exportUnavailable:
            return "当前设备没有可用的 HEVC 导出能力。"
        case .exportFailed(let detail):
            return detail.isEmpty ? "视频压缩失败。" : detail
        case .outputVerification(let detail):
            return detail
        case .insufficientSavings(let actual, let required):
            if actual < 0 { return "压缩结果比原件更大。" }
            return "实际节省 \(Int(actual * 100))%，低于设置的 \(Int(required * 100))%。"
        }
    }
}

/// A shared automatic compressor for PhotoKit clients.
///
/// It intentionally has no PhotoKit dependency: callers download an original
/// to a temporary URL or obtain an AVAsset, then decide when and how to import
/// the verified result back into their library.
@MainActor
public final class PhotoSlimMediaCompressor {
    private final class ExportCancellationBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(session: AVAssetExportSession) {
            self.session = session
        }

        func cancel() {
            session.cancelExport()
        }
    }

    public init() {}

    public func compressImage(
        data: Data,
        to outputURL: URL,
        quality: Double,
        sourceByteCount: Int64? = nil,
        minimumSavingsRatio: Double = 0
    ) throws -> PhotoSlimCoreCompressionOutput {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw PhotoSlimCoreCompressionError.invalidImage
        }

        try removeExistingOutput(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoSlimCoreCompressionError.cannotCreateDestination
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality))
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoSlimCoreCompressionError.imageEncodingFailed
        }

        let outputBytes = try fileSize(at: outputURL)
        guard outputBytes > 0 else {
            throw PhotoSlimCoreCompressionError.outputVerification("压缩结果为空。")
        }
        guard let outputSource = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceGetCount(outputSource) == 1,
              let outputType = CGImageSourceGetType(outputSource),
              UTType(outputType as String)?.conforms(to: .heic) == true else {
            throw PhotoSlimCoreCompressionError.outputVerification("输出不是有效的 HEIC 文件。")
        }

        try validateSavings(
            sourceByteCount: sourceByteCount ?? Int64(data.count),
            outputByteCount: outputBytes,
            minimumSavingsRatio: minimumSavingsRatio
        )
        return PhotoSlimCoreCompressionOutput(
            fileURL: outputURL,
            byteCount: outputBytes,
            sourceByteCount: sourceByteCount ?? Int64(data.count)
        )
    }

    public func compressVideo(
        asset: AVAsset,
        to outputURL: URL,
        sourceByteCount: Int64? = nil,
        settings: PhotoSlimCoreCompressionSettings = .recommended,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> PhotoSlimCoreCompressionOutput {
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw PhotoSlimCoreCompressionError.missingVideoTrack
        }

        try removeExistingOutput(at: outputURL)
        guard let preset = await compatiblePreset(for: asset, settings: settings) else {
            throw PhotoSlimCoreCompressionError.exportUnavailable
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw PhotoSlimCoreCompressionError.exportUnavailable
        }

        session.outputURL = outputURL
        session.outputFileType = session.supportedFileTypes.contains(.mov)
            ? .mov
            : session.supportedFileTypes.first
        session.shouldOptimizeForNetworkUse = false
        session.metadata = try await asset.load(.metadata)
        progress(0)

        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                if session.status == .completed || session.status == .failed
                    || session.status == .cancelled {
                    break
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        let cancellation = ExportCancellationBox(session: session)
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }
        }, onCancel: {
            cancellation.cancel()
        })
        monitor.cancel()

        if Task.isCancelled { throw CancellationError() }
        guard session.status == .completed else {
            throw PhotoSlimCoreCompressionError.exportFailed(
                session.error?.localizedDescription ?? "视频导出没有完成。"
            )
        }

        try await verifyVideoOutput(
            at: outputURL,
            source: asset
        )
        let outputBytes = try fileSize(at: outputURL)
        guard outputBytes > 0 else {
            throw PhotoSlimCoreCompressionError.outputVerification("压缩结果为空。")
        }
        let measuredSourceBytes = sourceByteCount ?? sourceFileSize(asset)
        try validateSavings(
            sourceByteCount: measuredSourceBytes,
            outputByteCount: outputBytes,
            minimumSavingsRatio: settings.minimumSavingsRatio
        )
        progress(1)
        return PhotoSlimCoreCompressionOutput(
            fileURL: outputURL,
            byteCount: outputBytes,
            sourceByteCount: measuredSourceBytes
        )
    }

    private func compatiblePreset(
        for asset: AVAsset,
        settings: PhotoSlimCoreCompressionSettings
    ) async -> String? {
        for candidate in settings.videoPreset.exportCandidates {
            if await AVAssetExportSession.compatibility(
                ofExportPreset: candidate,
                with: asset,
                outputFileType: .mov
            ) {
                return candidate
            }
        }
        return nil
    }

    private func verifyVideoOutput(at outputURL: URL, source: AVAsset) async throws {
        let output = AVURLAsset(url: outputURL)
        guard let track = try await output.loadTracks(withMediaType: .video).first,
              let description = try await track.load(.formatDescriptions).first else {
            throw PhotoSlimCoreCompressionError.outputVerification("输出缺少视频轨道。")
        }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        guard subtype == kCMVideoCodecType_HEVC || subtype == fourCC("hev1") else {
            throw PhotoSlimCoreCompressionError.outputVerification("输出不是 HEVC。")
        }

        let sourceTrack = try await source.loadTracks(withMediaType: .video).first
        let outputSize = try await track.load(.naturalSize)
        let outputTransform = try await track.load(.preferredTransform)
        let outputWidth = Int(abs(outputSize.applying(outputTransform).width).rounded())
        let outputHeight = Int(abs(outputSize.applying(outputTransform).height).rounded())
        if let sourceTrack {
            let sourceSize = try await sourceTrack.load(.naturalSize)
            let sourceTransform = try await sourceTrack.load(.preferredTransform)
            let sourceWidth = Int(abs(sourceSize.applying(sourceTransform).width).rounded())
            let sourceHeight = Int(abs(sourceSize.applying(sourceTransform).height).rounded())
            guard dimensionsMatch(
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                tolerance: 1
            ) else {
                throw PhotoSlimCoreCompressionError.outputVerification(
                    "输出像素尺寸与原件不一致。"
                )
            }
        }

        let sourceDuration = CMTimeGetSeconds(try await source.load(.duration))
        let outputDuration = CMTimeGetSeconds(try await output.load(.duration))
        guard sourceDuration.isFinite, outputDuration.isFinite,
              abs(sourceDuration - outputDuration) <= max(0.15, sourceDuration * 0.001) else {
            throw PhotoSlimCoreCompressionError.outputVerification("输出时长与原件不一致。")
        }
    }

    private func dimensionsMatch(
        outputWidth: Int,
        outputHeight: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        tolerance: Int
    ) -> Bool {
        let allowed = max(0, tolerance)
        let direct = abs(outputWidth - sourceWidth) <= allowed
            && abs(outputHeight - sourceHeight) <= allowed
        let rotated = abs(outputWidth - sourceHeight) <= allowed
            && abs(outputHeight - sourceWidth) <= allowed
        return direct || rotated
    }

    private func sourceFileSize(_ asset: AVAsset) -> Int64? {
        guard let urlAsset = asset as? AVURLAsset,
              let size = try? urlAsset.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return nil }
        return Int64(size)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return 0 }
        return Int64(size)
    }

    private func removeExistingOutput(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func validateSavings(
        sourceByteCount: Int64?,
        outputByteCount: Int64,
        minimumSavingsRatio: Double
    ) throws {
        // A zero threshold is used by the macOS adapter, which performs the
        // final transaction-level savings check after all output validation.
        guard minimumSavingsRatio > 0,
              let sourceByteCount,
              sourceByteCount > 0 else { return }
        let savings = Double(sourceByteCount - outputByteCount) / Double(sourceByteCount)
        guard savings >= minimumSavingsRatio else {
            throw PhotoSlimCoreCompressionError.insufficientSavings(
                actual: savings,
                required: minimumSavingsRatio
            )
        }
    }

    private func fourCC(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
