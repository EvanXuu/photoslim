import AVFoundation
import AVKit
import Combine
import CoreLocation
import Foundation
import Photos
#if canImport(AppKit)
import AppKit
#endif
#if SWIFT_PACKAGE
import PhotoSlimMediaCore
#endif
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum PhotoSlimiOSMediaKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case photo
    case video

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "全部"
        case .photo: return "照片"
        case .video: return "视频"
        }
    }
}

public enum PhotoSlimiOSLayoutMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case list
    case grid

    public var id: String { rawValue }
}

public struct PhotoSlimiOSAssetItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: PhotoSlimiOSMediaKind
    public let filename: String
    public let creationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: Double
    public let isFavorite: Bool
    public let isCloudOnly: Bool
    public let originalByteCount: Int64?

    public var displayTitle: String {
        filename.isEmpty ? (kind == .video ? "未命名视频" : "未命名照片") : filename
    }

    public var dimensionsLabel: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "尺寸未知" }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    public var durationLabel: String? {
        guard kind == .video, duration.isFinite, duration > 0 else { return nil }
        let totalSeconds = Int(duration.rounded())
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    public var sizeLabel: String? {
        guard let originalByteCount, originalByteCount > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: originalByteCount, countStyle: .file)
    }
}

public struct PhotoSlimiOSPreview: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceID: String
    public let sourceFilename: String
    public let kind: PhotoSlimiOSMediaKind
    public let outputURL: URL
    public let originalURL: URL?
    public let sourceByteCount: Int64?
    public let outputByteCount: Int64

    public var savedBytes: Int64? {
        guard let sourceByteCount else { return nil }
        return sourceByteCount - outputByteCount
    }

    public var savingsRatio: Double? {
        guard let sourceByteCount, sourceByteCount > 0 else { return nil }
        return Double(sourceByteCount - outputByteCount) / Double(sourceByteCount)
    }
}

private struct PhotoSlimiOSPreviewManifest: Codable {
    let previews: [PhotoSlimiOSPreview]
}

private actor PhotoSlimDownloadLimiter {
    private var availableSlots: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        availableSlots = max(1, limit)
    }

    func acquire() async {
        if availableSlots > 0 {
            availableSlots -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            availableSlots += 1
        }
    }
}

private enum PhotoSlimiOSDownloadedResource {
    case image(data: Data, originalURL: URL?, sourceByteCount: Int64)
    case video(asset: AVAsset, originalURL: URL?, sourceByteCount: Int64?)

    var originalURL: URL? {
        switch self {
        case .image(_, let originalURL, _), .video(_, let originalURL, _):
            return originalURL
        }
    }
}

private enum PhotoSlimiOSProcessingResult {
    case success(PhotoSlimiOSPreview)
    case failure(identifier: String, message: String)
}

private final class PhotoSlimContinuationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}

private final class PhotoSlimRequestIDBox: @unchecked Sendable {
    var id: PHImageRequestID = PHInvalidImageRequestID
}

/// Observable PhotoKit authorization state shared by the iOS SwiftUI shell.
@MainActor
public final class PhotoSlimiOSLibraryModel: ObservableObject {
    @Published public private(set) var authorizationStatus: PHAuthorizationStatus
    @Published public private(set) var isRequestingAccess = false
    @Published public private(set) var photoCount = 0
    @Published public private(set) var videoCount = 0
    @Published public private(set) var lastScanDate: Date?
    @Published public private(set) var libraryItems: [PhotoSlimiOSAssetItem] = []
    @Published public var selectedIdentifiers: Set<String> = []
    @Published public var searchText = ""
    @Published public var mediaFilter: PhotoSlimiOSMediaKind = .all
    @Published public var layoutMode: PhotoSlimiOSLayoutMode = .list
    @Published public private(set) var isScanning = false
    @Published public private(set) var scanProgress = 0.0
    @Published public private(set) var isProcessing = false
    @Published public private(set) var currentItemName = ""
    @Published public private(set) var downloadProgress = 0.0
    @Published public private(set) var compressionProgress = 0.0
    @Published public private(set) var completedItemCount = 0
    @Published public private(set) var processingStatus = ""
    @Published public private(set) var previews: [PhotoSlimiOSPreview] = []
    @Published public private(set) var workflowError: String?

    private let imageManager = PHCachingImageManager()
    private let compressor = PhotoSlimMediaCompressor()
    private let downloadLimiter = PhotoSlimDownloadLimiter(limit: 5)
    private var photoAssets: [String: PHAsset] = [:]
    private var activeRequestIdentifiers: Set<PHImageRequestID> = []
    private var processingTask: Task<Void, Never>?
    private var previewDirectory: URL?
    private var downloadProgressByIdentifier: [String: Double] = [:]
    private var compressionProgressByIdentifier: [String: Double] = [:]
    private let manifestURL: URL

    public init() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = applicationSupport.appendingPathComponent("PhotoSlim", isDirectory: true)
        manifestURL = directory.appendingPathComponent("ios-preview-manifest.json")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        restorePreviews()
    }

    public func refreshAuthorizationStatus() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func requestPhotoAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationStatus = status
                self.isRequestingAccess = false
                if self.canReadPhotos {
                    self.scanLibrary()
                }
            }
        }
    }

    /// Reads the PhotoKit index only. Original resources are not downloaded.
    public func scanLibrary() {
        guard canReadPhotos else {
            photoCount = 0
            videoCount = 0
            lastScanDate = nil
            libraryItems = []
            photoAssets = [:]
            return
        }
        guard !isScanning, !isProcessing else { return }

        isScanning = true
        scanProgress = 0
        workflowError = nil
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var photos = 0
        var videos = 0
        var items: [PhotoSlimiOSAssetItem] = []
        var fetchedAssets: [String: PHAsset] = [:]
        items.reserveCapacity(result.count)
        fetchedAssets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            let kind: PhotoSlimiOSMediaKind
            switch asset.mediaType {
            case .image:
                photos += 1
                kind = .photo
            case .video:
                videos += 1
                kind = .video
            default:
                return
            }
            let resource = Self.primaryResource(for: asset)
            let originalBytes = Self.resourceByteCount(resource)
            let item = PhotoSlimiOSAssetItem(
                id: asset.localIdentifier,
                kind: kind,
                filename: resource?.originalFilename ?? "",
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration,
                isFavorite: asset.isFavorite,
                isCloudOnly: Self.resourceIsCloudOnly(resource),
                originalByteCount: originalBytes
            )
            items.append(item)
            fetchedAssets[asset.localIdentifier] = asset
            self.scanProgress = result.count > 0 ? Double(items.count) / Double(result.count) : 1
        }
        photoCount = photos
        videoCount = videos
        libraryItems = items
        photoAssets = fetchedAssets
        lastScanDate = Date()
        isScanning = false
        scanProgress = 1
    }

    public var filteredItems: [PhotoSlimiOSAssetItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return libraryItems.filter { item in
            let kindMatches = mediaFilter == .all || item.kind == mediaFilter
            let textMatches = query.isEmpty
                || item.displayTitle.localizedCaseInsensitiveContains(query)
            return kindMatches && textMatches
        }
    }

    public var selectedItems: [PhotoSlimiOSAssetItem] {
        libraryItems.filter { selectedIdentifiers.contains($0.id) }
    }

    public var selectedItemCount: Int { selectedItems.count }

    public var availableStorageLabel: String? {
        guard let capacity = availableStorageBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
    }

#if canImport(UIKit)
    @discardableResult
    public func requestThumbnail(
        for identifier: String,
        targetSize: CGSize,
        completion: @escaping (UIImage?) -> Void
    ) -> PHImageRequestID? {
        guard let asset = photoAssets[identifier] else {
            completion(nil)
            return nil
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            Task { @MainActor in
                completion(image)
            }
        }
    }

    public func cancelThumbnailRequest(_ identifier: PHImageRequestID) {
        imageManager.cancelImageRequest(identifier)
    }
#endif

    public var allVisibleItemsSelected: Bool {
        let visibleIDs = Set(filteredItems.map(\.id))
        return !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedIdentifiers)
    }

    public func toggleSelection(_ item: PhotoSlimiOSAssetItem) {
        guard !isProcessing else { return }
        if selectedIdentifiers.contains(item.id) {
            selectedIdentifiers.remove(item.id)
        } else {
            selectedIdentifiers.insert(item.id)
        }
    }

    public func selectAllVisible() {
        if allVisibleItemsSelected {
            selectedIdentifiers.subtract(filteredItems.map(\.id))
        } else {
            selectedIdentifiers.formUnion(filteredItems.map(\.id))
        }
    }

    public func startCompression() {
        guard canReadPhotos, !isScanning, !isProcessing else { return }
        guard previews.isEmpty else {
            workflowError = "请先选择“撤回压缩副本”或“确认写入相册并删除原件”。"
            return
        }
        let items = selectedItems
        guard !items.isEmpty else {
            workflowError = "请先选择要压缩的项目。"
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoSlim-iOS-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            workflowError = "无法创建临时工作目录。"
            return
        }

        previewDirectory = directory
        isProcessing = true
        currentItemName = "准备处理"
        processingStatus = "正在准备"
        downloadProgress = 0
        compressionProgress = 0
        completedItemCount = 0
        workflowError = nil
        downloadProgressByIdentifier = Dictionary(uniqueKeysWithValues: items.map { ($0.id, 0) })
        compressionProgressByIdentifier = Dictionary(uniqueKeysWithValues: items.map { ($0.id, 0) })

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCompression(items: items, directory: directory)
        }
    }

    public func cancelCompression() {
        guard isProcessing else { return }
        processingStatus = "正在终止并清理临时文件"
        processingTask?.cancel()
        cancelActivePhotoRequests()
    }

    /// Removes only the local preview copy. The original Photos asset is not touched.
    public func discardPreviews() {
        guard !isProcessing else { return }
        clearPreviewFiles()
        processingStatus = "已撤回压缩副本"
    }

    public func commitPreviews() {
        guard !previews.isEmpty, !isProcessing else { return }
        guard canReadPhotos else {
            workflowError = "需要照片访问权限才能写入相册。"
            return
        }

        let pending = previews
        isProcessing = true
        processingStatus = "正在写入相册"
        workflowError = nil
        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.performPhotoChanges(for: pending)
                self.clearPreviewFiles()
                self.processingStatus = "已写入相册并删除原件"
                self.isProcessing = false
                self.processingTask = nil
                self.scanLibrary()
            } catch is CancellationError {
                self.isProcessing = false
                self.processingTask = nil
            } catch {
                self.workflowError = Self.userMessage(for: error)
                self.processingStatus = "写入失败，原件未删除"
                self.isProcessing = false
                self.processingTask = nil
            }
        }
    }

    private func runCompression(
        items: [PhotoSlimiOSAssetItem],
        directory: URL
    ) async {
        var completedPreviews: [PhotoSlimiOSPreview] = []
        var failures: [String] = []

        await withTaskGroup(of: PhotoSlimiOSProcessingResult.self) { group in
            for item in items {
                group.addTask { @MainActor [weak self] in
                    guard let self else {
                        return .failure(identifier: item.id, message: "任务已结束")
                    }
                    return await self.process(item: item, directory: directory)
                }
            }

            for await result in group {
                switch result {
                case .success(let preview):
                    completedPreviews.append(preview)
                case .failure(_, let message):
                    failures.append(message)
                }
                completedItemCount += 1
            }
        }

        do {
            try Task.checkCancellation()
            completedPreviews.sort { left, right in
                let leftIndex = items.firstIndex { $0.id == left.sourceID } ?? .max
                let rightIndex = items.firstIndex { $0.id == right.sourceID } ?? .max
                return leftIndex < rightIndex
            }
            previews = completedPreviews
            previewDirectory = directory
            persistPreviews()
            isProcessing = false
            processingTask = nil
            processingStatus = completedPreviews.isEmpty
                ? "没有生成可用的压缩结果"
                : "压缩完成，请检查结果"
            if !failures.isEmpty {
                workflowError = failures.prefix(2).joined(separator: "；")
            }
        } catch is CancellationError {
            removeDirectory(directory)
            previews = []
            previewDirectory = nil
            isProcessing = false
            processingTask = nil
            processingStatus = "已终止，临时文件已清理"
            downloadProgress = 0
            compressionProgress = 0
        } catch {
            removeDirectory(directory)
            previews = []
            previewDirectory = nil
            isProcessing = false
            processingTask = nil
            workflowError = Self.userMessage(for: error)
            processingStatus = "处理失败，原件未修改"
        }
    }

    private func process(
        item: PhotoSlimiOSAssetItem,
        directory: URL
    ) async -> PhotoSlimiOSProcessingResult {
        currentItemName = item.displayTitle
        processingStatus = "正在下载原件"
        do {
            try Task.checkCancellation()
            let downloaded = try await download(item: item, directory: directory)
            try Task.checkCancellation()
            setDownloadProgress(1, for: item.id)
            processingStatus = "正在压缩"

            let outputURL: URL
            let output: PhotoSlimCoreCompressionOutput
            switch downloaded {
            case .image(let data, _, let sourceByteCount):
                outputURL = directory.appendingPathComponent("\(item.id.hashValue)-compressed.heic")
                output = try compressor.compressImage(
                    data: data,
                    to: outputURL,
                    quality: 0.82,
                    sourceByteCount: sourceByteCount,
                    minimumSavingsRatio: 0.08
                )
                setCompressionProgress(1, for: item.id)
            case .video(let asset, _, let sourceByteCount):
                outputURL = directory.appendingPathComponent("\(item.id.hashValue)-compressed.mov")
                output = try await compressor.compressVideo(
                    asset: asset,
                    to: outputURL,
                    sourceByteCount: sourceByteCount,
                    settings: PhotoSlimCoreCompressionSettings(
                        videoPreset: .highestQuality,
                        minimumSavingsRatio: 0.08
                    ),
                    progress: { [weak self] value in
                        Task { @MainActor [weak self] in
                            self?.setCompressionProgress(value, for: item.id)
                        }
                    }
                )
            }

            return .success(
                PhotoSlimiOSPreview(
                    id: UUID(),
                    sourceID: item.id,
                    sourceFilename: item.displayTitle,
                    kind: item.kind,
                    outputURL: output.fileURL,
                    originalURL: downloaded.originalURL,
                    sourceByteCount: output.sourceByteCount,
                    outputByteCount: output.byteCount
                )
            )
        } catch is CancellationError {
            return .failure(identifier: item.id, message: "已终止")
        } catch {
            return .failure(identifier: item.id, message: "\(item.displayTitle)：\(Self.userMessage(for: error))")
        }
    }

    private func download(
        item: PhotoSlimiOSAssetItem,
        directory: URL
    ) async throws -> PhotoSlimiOSDownloadedResource {
        guard let asset = photoAssets[item.id] else {
            throw PhotoSlimCoreCompressionError.outputVerification("找不到图库项目。")
        }
        await downloadLimiter.acquire()
        do {
            let result: PhotoSlimiOSDownloadedResource
            switch item.kind {
            case .photo:
                let data = try await requestImageData(for: asset, identifier: item.id)
                let originalURL = directory.appendingPathComponent("\(item.id.hashValue)-original.data")
                try data.write(to: originalURL, options: .atomic)
                result = .image(
                    data: data,
                    originalURL: originalURL,
                    sourceByteCount: Int64(data.count)
                )
            case .video:
                let fetchedAsset = try await requestVideoAsset(for: asset, identifier: item.id)
                var compressionAsset = fetchedAsset
                var originalURL: URL?
                var sourceByteCount = item.originalByteCount
                if let urlAsset = fetchedAsset as? AVURLAsset {
                    let copiedURL = directory.appendingPathComponent(
                        "\(item.id.hashValue)-original\(urlAsset.url.pathExtension.isEmpty ? ".mov" : ".\(urlAsset.url.pathExtension)")"
                    )
                    try FileManager.default.copyItem(at: urlAsset.url, to: copiedURL)
                    originalURL = copiedURL
                    compressionAsset = AVURLAsset(url: copiedURL)
                    sourceByteCount = try? copiedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        .map(Int64.init) ?? sourceByteCount
                }
                result = .video(
                    asset: compressionAsset,
                    originalURL: originalURL,
                    sourceByteCount: sourceByteCount
                )
            case .all:
                throw PhotoSlimCoreCompressionError.outputVerification("媒体类型无效。")
            }
            await downloadLimiter.release()
            return result
        } catch {
            await downloadLimiter.release()
            throw error
        }
    }

    private func requestImageData(for asset: PHAsset, identifier: String) async throws -> Data {
        let options = PHImageRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] value, _, _, _ in
            Task { @MainActor [weak self] in
                self?.setDownloadProgress(value, for: identifier)
            }
        }

        let continuation = PhotoSlimContinuationBox<Data>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (checked: CheckedContinuation<Data, Error>) in
                continuation.install(checked)
                let requestIDBox = PhotoSlimRequestIDBox()
                let requestID = imageManager.requestImageDataAndOrientation(
                    for: asset,
                    options: options
                ) { [weak self] data, _, _, info in
                    Task { @MainActor [weak self] in
                        if requestIDBox.id != PHInvalidImageRequestID {
                            self?.activeRequestIdentifiers.remove(requestIDBox.id)
                        }
                        if let error = info?[PHImageErrorKey] as? Error {
                            continuation.finish(.failure(error))
                        } else if let data {
                            continuation.finish(.success(data))
                        } else {
                            continuation.finish(
                                .failure(PhotoSlimCoreCompressionError.invalidImage)
                            )
                        }
                    }
                }
                requestIDBox.id = requestID
                activeRequestIdentifiers.insert(requestID)
            }
        }, onCancel: {
            continuation.cancel()
            Task { @MainActor [weak self] in
                self?.cancelActivePhotoRequests()
            }
        })
    }

    private func requestVideoAsset(for asset: PHAsset, identifier: String) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] value, _, _, _ in
            Task { @MainActor [weak self] in
                self?.setDownloadProgress(value, for: identifier)
            }
        }

        let continuation = PhotoSlimContinuationBox<AVAsset>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (checked: CheckedContinuation<AVAsset, Error>) in
                continuation.install(checked)
                let requestIDBox = PhotoSlimRequestIDBox()
                let requestID = imageManager.requestAVAsset(forVideo: asset, options: options) {
                    [weak self] avAsset, _, info in
                    Task { @MainActor [weak self] in
                        if requestIDBox.id != PHInvalidImageRequestID {
                            self?.activeRequestIdentifiers.remove(requestIDBox.id)
                        }
                        if let error = info?[PHImageErrorKey] as? Error {
                            continuation.finish(.failure(error))
                        } else if let avAsset {
                            continuation.finish(.success(avAsset))
                        } else {
                            continuation.finish(
                                .failure(PhotoSlimCoreCompressionError.missingVideoTrack)
                            )
                        }
                    }
                }
                requestIDBox.id = requestID
                activeRequestIdentifiers.insert(requestID)
            }
        }, onCancel: {
            continuation.cancel()
            Task { @MainActor [weak self] in
                self?.cancelActivePhotoRequests()
            }
        })
    }

    private func cancelActivePhotoRequests() {
        for identifier in activeRequestIdentifiers {
            imageManager.cancelImageRequest(identifier)
        }
        activeRequestIdentifiers.removeAll()
    }

    private func setDownloadProgress(_ value: Double, for identifier: String) {
        downloadProgressByIdentifier[identifier] = min(1, max(0, value))
        downloadProgress = averageProgress(downloadProgressByIdentifier)
    }

    private func setCompressionProgress(_ value: Double, for identifier: String) {
        compressionProgressByIdentifier[identifier] = min(1, max(0, value))
        compressionProgress = averageProgress(compressionProgressByIdentifier)
    }

    private func averageProgress(_ values: [String: Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.values.reduce(0, +) / Double(values.count)
    }

    private var availableStorageBytes: Int64? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }

    private func restorePreviews() {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(
                PhotoSlimiOSPreviewManifest.self,
                from: data
              ) else { return }
        let valid = manifest.previews.filter {
            FileManager.default.fileExists(atPath: $0.outputURL.path)
        }
        previews = valid
        previewDirectory = valid.first?.outputURL.deletingLastPathComponent()
        if valid.isEmpty { try? FileManager.default.removeItem(at: manifestURL) }
    }

    private func persistPreviews() {
        let manifest = PhotoSlimiOSPreviewManifest(previews: previews)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func clearPreviewFiles() {
        if let previewDirectory { removeDirectory(previewDirectory) }
        for preview in previews {
            if let originalURL = preview.originalURL,
               originalURL.deletingLastPathComponent() != previewDirectory {
                try? FileManager.default.removeItem(at: originalURL)
            }
            try? FileManager.default.removeItem(at: preview.outputURL)
        }
        previews = []
        previewDirectory = nil
        try? FileManager.default.removeItem(at: manifestURL)
    }

    private func removeDirectory(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first(where: { resource in
            resource.type == .fullSizePhoto || resource.type == .fullSizeVideo
                || resource.type == .photo || resource.type == .video
        }) ?? resources.first
    }

    private static func resourceByteCount(_ resource: PHAssetResource?) -> Int64? {
        guard let resource,
              let number = resource.value(forKey: "fileSize") as? NSNumber,
              number.int64Value > 0 else { return nil }
        return number.int64Value
    }

    private static func resourceIsCloudOnly(_ resource: PHAssetResource?) -> Bool {
        guard let resource,
              let locallyAvailable = resource.value(forKey: "locallyAvailable") as? NSNumber else {
            return false
        }
        return !locallyAvailable.boolValue
    }

    private static func userMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func performPhotoChanges(for pending: [PhotoSlimiOSPreview]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                for preview in pending {
                    guard FileManager.default.fileExists(atPath: preview.outputURL.path),
                          let source = PHAsset.fetchAssets(
                            withLocalIdentifiers: [preview.sourceID],
                            options: nil
                          ).firstObject else { continue }

                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = source.creationDate
                    request.isFavorite = source.isFavorite
                    request.isHidden = source.isHidden
                    request.location = source.location
                    let resourceOptions = PHAssetResourceCreationOptions()
                    resourceOptions.originalFilename = preview.sourceFilename
                    resourceOptions.shouldMoveFile = false
                    request.addResource(
                        with: preview.kind == .photo ? .photo : .video,
                        fileURL: preview.outputURL,
                        options: resourceOptions
                    )
                    PHAssetChangeRequest.deleteAssets([source] as NSArray)
                }
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: error ?? PhotoSlimCoreCompressionError.exportFailed(
                            "照片图库没有完成写入。"
                        )
                    )
                }
            }
        }
    }

    public var accessTitle: String {
        switch authorizationStatus {
        case .authorized, .limited:
            return "已允许访问照片"
        case .denied, .restricted:
            return "照片访问已关闭"
        case .notDetermined:
            return "尚未允许访问照片"
        @unknown default:
            return "照片访问状态未知"
        }
    }

    public var canReadPhotos: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }
}

/// The iOS SwiftUI surface. PhotoKit index scanning is intentionally separate
/// from original-resource downloads and the shared compression core.
@MainActor
private struct PhotoSlimiOSLegacyRootView: View {
    @StateObject private var libraryModel: PhotoSlimiOSLibraryModel

    public init() {
        self.init(libraryModel: PhotoSlimiOSLibraryModel())
    }

    public init(libraryModel: PhotoSlimiOSLibraryModel) {
        _libraryModel = StateObject(wrappedValue: libraryModel)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    accessCard
                    if libraryModel.canReadPhotos {
                        libraryBrowser
                        taskProgressCard
                        previewCard
                    }
                    capabilityCard
                }
                .padding(20)
            }
            .background(Color.secondary.opacity(0.08))
            .navigationTitle("PhotoSlim")
        }
        .task {
            libraryModel.refreshAuthorizationStatus()
            if libraryModel.canReadPhotos {
                libraryModel.scanLibrary()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("整理照片和视频")
                .font(.largeTitle.weight(.bold))
            Text("在设备上整理媒体，扫描时不会修改原件。")
                .foregroundStyle(.secondary)
        }
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("照片图库", systemImage: "photo.on.rectangle")
                .font(.headline)
            Text(libraryModel.accessTitle)
                .foregroundStyle(.secondary)

            if !libraryModel.canReadPhotos {
                Button {
                    libraryModel.requestPhotoAccess()
                } label: {
                    Label(
                        libraryModel.isRequestingAccess ? "正在请求…" : "允许访问照片",
                        systemImage: "lock.open"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(libraryModel.isRequestingAccess)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(libraryModel.photoCount) 张照片 · \(libraryModel.videoCount) 个视频")
                            .font(.headline)
                        if let lastScanDate = libraryModel.lastScanDate {
                            Text("已读取图库索引 · \(lastScanDate.formatted(date: .omitted, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("尚未读取图库索引")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("扫描图库") {
                        libraryModel.scanLibrary()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var capabilityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("设备能力", systemImage: "cpu")
                .font(.headline)
            HStack {
                Text("HEVC 硬件编码")
                Spacer()
                Text(PhotoSlimMediaCore.supportsHardwareHEVCEncoding ? "可用" : "不可用")
                    .foregroundStyle(PhotoSlimMediaCore.supportsHardwareHEVCEncoding ? .green : .orange)
            }
            HStack {
                Text("最低系统")
                Spacer()
                Text("iOS \(PhotoSlimMediaCore.minimumSupportedIOSVersion)")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var libraryBrowser: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("选择要压缩的项目", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Button(libraryModel.allVisibleItemsSelected ? "取消全选" : "全选") {
                    libraryModel.selectAllVisible()
                }
                .buttonStyle(.bordered)
            }

            TextField("搜索文件名", text: $libraryModel.searchText)
                .textFieldStyle(.roundedBorder)

            Picker("媒体类型", selection: $libraryModel.mediaFilter) {
                ForEach(PhotoSlimiOSMediaKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            if let availableStorageLabel = libraryModel.availableStorageLabel {
                Text("本机可用空间 \(availableStorageLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if libraryModel.isScanning {
                ProgressView(value: libraryModel.scanProgress)
            } else if libraryModel.filteredItems.isEmpty {
                Text("当前没有符合条件的项目")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(libraryModel.filteredItems) { item in
                        iOSAssetRow(item: item)
                        Divider()
                    }
                }
                .frame(maxHeight: 360)
            }

            if let workflowError = libraryModel.workflowError {
                Text(workflowError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text("已选择 \(libraryModel.selectedItemCount) 项")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("开始压缩") {
                    libraryModel.startCompression()
                }
                .buttonStyle(.borderedProminent)
                .disabled(libraryModel.selectedItemCount == 0 || libraryModel.isProcessing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func iOSAssetRow(item: PhotoSlimiOSAssetItem) -> some View {
        Button {
            libraryModel.toggleSelection(item)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: libraryModel.selectedIdentifiers.contains(item.id)
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(libraryModel.selectedIdentifiers.contains(item.id) ? .blue : .secondary)
                    .font(.title3)
                Image(systemName: item.kind == .photo ? "photo" : "video")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(item.dimensionsLabel)
                        if let durationLabel = item.durationLabel { Text(durationLabel) }
                        if let sizeLabel = item.sizeLabel {
                            Text(sizeLabel)
                        } else if item.isCloudOnly {
                            Text("iCloud · 下载后确认大小")
                        } else {
                            Text("大小未知")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var taskProgressCard: some View {
        if libraryModel.isProcessing {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("正在处理", systemImage: "gearshape.2.fill")
                        .font(.headline)
                    Spacer()
                    Button("终止") { libraryModel.cancelCompression() }
                        .buttonStyle(.bordered)
                }
                Text(libraryModel.currentItemName)
                    .lineLimit(1)
                ProgressView(value: libraryModel.downloadProgress) {
                    Text("下载原件")
                }
                ProgressView(value: libraryModel.compressionProgress) {
                    Text("压缩")
                }
                Text("\(libraryModel.completedItemCount) 项已完成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder
    private var previewCard: some View {
        if !libraryModel.previews.isEmpty && !libraryModel.isProcessing {
            VStack(alignment: .leading, spacing: 14) {
                Label("检查压缩结果", systemImage: "rectangle.on.rectangle")
                    .font(.headline)
                Text("按住预览查看原图。确认后才会写入相册并删除原件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 12
                ) {
                    ForEach(libraryModel.previews) { preview in
                        PhotoSlimiOSPreviewTile(preview: preview)
                    }
                }

                HStack {
                    Button("撤回压缩副本") {
                        libraryModel.discardPreviews()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("确认写入相册并删除原件") {
                        libraryModel.commitPreviews()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
        } else if !libraryModel.processingStatus.isEmpty {
            Text(libraryModel.processingStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PhotoSlimiOSPreviewTile: View {
    let preview: PhotoSlimiOSPreview
    @State private var showingOriginal = false
    @State private var showingDetail = false

    private var displayedURL: URL {
        showingOriginal ? (preview.originalURL ?? preview.outputURL) : preview.outputURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if preview.kind == .video {
                    VideoPlayer(player: AVPlayer(url: displayedURL))
                } else {
                    imagePreview
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                Text(showingOriginal ? "原图" : "压缩结果")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.58), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                showingOriginal = pressing
            }, perform: {})
            .onTapGesture {
                showingDetail = true
            }

            .sheet(isPresented: $showingDetail) {
                PhotoSlimiOSPreviewDetail(preview: preview)
            }

            Text(preview.sourceFilename)
                .lineLimit(1)
                .font(.caption)
            if let savedBytes = preview.savedBytes {
                Text(savedBytes >= 0
                    ? "实际节省 \(ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file))"
                    : "结果更大")
                    .font(.caption2)
                    .foregroundStyle(savedBytes >= 0 ? Color.secondary : Color.orange)
            } else {
                Text("原件大小未知")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        #if canImport(UIKit)
        if let image = UIImage(contentsOfFile: displayedURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.12))
        } else {
            Image(systemName: "photo")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.12))
        }
        #else
        Image(systemName: "photo")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.12))
        #endif
    }
}

private struct PhotoSlimiOSPreviewDetail: View {
    let preview: PhotoSlimiOSPreview
    @Environment(\.dismiss) private var dismiss
    @State private var showingOriginal = false
    @State private var scale = 1.0
    @State private var settledScale = 1.0

    private var displayedURL: URL {
        showingOriginal ? (preview.originalURL ?? preview.outputURL) : preview.outputURL
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                Group {
                    if preview.kind == .video {
                        VideoPlayer(player: AVPlayer(url: displayedURL))
                    } else {
                        imagePreview
                    }
                }
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1, settledScale * value)
                        }
                        .onEnded { value in
                            settledScale = min(max(1, settledScale * value), 5)
                            scale = settledScale
                        }
                )
                .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                    showingOriginal = pressing
                }, perform: {})
                .overlay(alignment: .topTrailing) {
                    Text(showingOriginal ? "原图" : "压缩结果")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.62), in: Capsule())
                        .foregroundStyle(.white)
                        .padding()
                }
            }
            .navigationTitle(preview.sourceFilename)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        #if canImport(UIKit)
        if let image = UIImage(contentsOfFile: displayedURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.white)
        }
        #else
        Image(systemName: "photo")
            .foregroundStyle(.white)
        #endif
    }
}

private enum PhotoSlimiOSTheme {
#if canImport(UIKit)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevated = Color(uiColor: .systemBackground)
#else
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let elevated = Color(nsColor: .textBackgroundColor)
#endif

    // The amber signal is the iOS counterpart of the macOS PhotoSlim accent.
    static let signal = Color(red: 0.72, green: 0.34, blue: 0.06)
    static let signalSoft = signal.opacity(0.12)
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red
    static let minimumTouchHeight: CGFloat = 44
}

/// Native iOS adaptation of the macOS browser flow.
///
/// The model and compression pipeline remain shared. This surface intentionally
/// uses iOS navigation, grouped content, a searchable list/grid, and a bottom
/// action layer instead of carrying the desktop card layout onto a phone.
@MainActor
public struct PhotoSlimiOSRootView: View {
    @StateObject private var libraryModel: PhotoSlimiOSLibraryModel

    public init() {
        self.init(libraryModel: PhotoSlimiOSLibraryModel())
    }

    public init(libraryModel: PhotoSlimiOSLibraryModel) {
        _libraryModel = StateObject(wrappedValue: libraryModel)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if libraryModel.canReadPhotos {
                        if isReviewing {
                            reviewContent
                        } else {
                            libraryContent
                        }
                    } else {
                        authorizationContent
                    }
                }
                .padding(.bottom, bottomContentPadding)
            }
            .background(PhotoSlimiOSTheme.canvas)
            .scrollIndicators(.hidden)
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(navigationTitleText)
                            .font(.headline)
                        Text(navigationSubtitleText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            libraryModel.scanLibrary()
                        } label: {
                            Label("扫描图库", systemImage: "arrow.clockwise")
                        }
                        .disabled(libraryModel.isScanning || libraryModel.isProcessing)

                        if libraryModel.canReadPhotos && !isReviewing {
                            Button {
                                libraryModel.selectAllVisible()
                            } label: {
                                Label(
                                    libraryModel.allVisibleItemsSelected ? "取消全选" : "全选",
                                    systemImage: libraryModel.allVisibleItemsSelected
                                        ? "checkmark.circle" : "checkmark.circle"
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("图库操作")
                }
            }
#endif
            .refreshable {
                libraryModel.scanLibrary()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomActionBar
            }
        }
        .task {
            libraryModel.refreshAuthorizationStatus()
            if libraryModel.canReadPhotos {
                libraryModel.scanLibrary()
            }
        }
    }

    private var isReviewing: Bool {
        !libraryModel.previews.isEmpty && !libraryModel.isProcessing
    }

    private var bottomContentPadding: CGFloat {
        if isReviewing || libraryModel.isProcessing || libraryModel.selectedItemCount > 0 {
            return 104
        }
        return 16
    }

    private var navigationTitleText: String {
        if isReviewing { return "检查压缩结果" }
        switch libraryModel.mediaFilter {
        case .all: return "全部媒体"
        case .photo: return "照片"
        case .video: return "视频"
        }
    }

    private var navigationSubtitleText: String {
        if isReviewing { return "\(libraryModel.previews.count) 个结果" }
        return "\(libraryModel.filteredItems.count) 个项目"
    }

    private var authorizationContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(PhotoSlimiOSTheme.signal)

            VStack(alignment: .leading, spacing: 8) {
                Text("连接照片图库")
                    .font(.title2.weight(.semibold))
                Text("允许访问后，你可以选择照片和视频生成本地压缩副本。扫描不会修改原件。")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if libraryModel.authorizationStatus == .denied
                || libraryModel.authorizationStatus == .restricted
            {
                Label("请在系统设置中重新允许照片访问。", systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(PhotoSlimiOSTheme.warning)
            } else {
                Button {
                    libraryModel.requestPhotoAccess()
                } label: {
                    Label(
                        libraryModel.isRequestingAccess ? "正在请求…" : "允许访问照片",
                        systemImage: "lock.open"
                    )
                    .frame(maxWidth: .infinity, minHeight: PhotoSlimiOSTheme.minimumTouchHeight)
                }
                .buttonStyle(.borderedProminent)
                .tint(PhotoSlimiOSTheme.signal)
                .disabled(libraryModel.isRequestingAccess)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PhotoSlimiOSTheme.surface)
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            libraryHeader
            browserControls

            if libraryModel.isScanning && libraryModel.libraryItems.isEmpty {
                scanningState
            } else if libraryModel.filteredItems.isEmpty {
                emptyState
            } else if libraryModel.layoutMode == .grid {
                gridContent
            } else {
                listContent
            }

            if let workflowError = libraryModel.workflowError {
                Label(workflowError, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(PhotoSlimiOSTheme.warning)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }

            if libraryModel.isProcessing {
                taskContent
            }
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle")
                .font(.title3)
                .foregroundStyle(PhotoSlimiOSTheme.signal)
                .frame(width: 32, height: 32)
                .background(PhotoSlimiOSTheme.signalSoft, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("照片图库")
                    .font(.headline)
                        Text("\(libraryModel.photoCount) 张照片 · \(libraryModel.videoCount) 个视频")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let availableStorageLabel = libraryModel.availableStorageLabel {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("本机可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(availableStorageLabel)
                        .font(.caption.weight(.medium).monospacedDigit())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var browserControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("搜索文件名", text: $libraryModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: PhotoSlimiOSTheme.minimumTouchHeight)

            Picker("媒体类型", selection: $libraryModel.mediaFilter) {
                ForEach(PhotoSlimiOSMediaKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Label("显示方式", systemImage: libraryModel.layoutMode == .list
                    ? "list.bullet" : "square.grid.2x2")
                    .font(.subheadline)
                Spacer()
                Picker("显示方式", selection: $libraryModel.layoutMode) {
                    Image(systemName: "list.bullet").tag(PhotoSlimiOSLayoutMode.list)
                    Image(systemName: "square.grid.2x2").tag(PhotoSlimiOSLayoutMode.grid)
                }
                .pickerStyle(.segmented)
                .frame(width: 104)
                .labelsHidden()
            }

            if libraryModel.isScanning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: libraryModel.scanProgress)
                        .tint(PhotoSlimiOSTheme.signal)
                    Text("正在读取图库")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(PhotoSlimiOSTheme.surface)
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(PhotoSlimiOSTheme.signal)
            Text("正在读取图库")
                .font(.headline)
            Text("照片和视频会在列表中逐步出现。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("没有符合条件的项目")
                .font(.headline)
            Text("换一个媒体类型或搜索词试试。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    private var listContent: some View {
        LazyVStack(spacing: 0) {
            ForEach(libraryModel.filteredItems) { item in
                PhotoSlimiOSAssetRow(item: item, model: libraryModel)
                Divider()
                    .padding(.leading, 96)
            }
        }
        .padding(.horizontal, 12)
    }

    private var gridContent: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            ForEach(libraryModel.filteredItems) { item in
                PhotoSlimiOSAssetGridTile(item: item, model: libraryModel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var taskContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(PhotoSlimiOSTheme.signal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("正在准备压缩副本")
                        .font(.headline)
                    Text(libraryModel.currentItemName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }

            progressRow(
                title: "下载原件",
                value: libraryModel.downloadProgress,
                symbol: "icloud.and.arrow.down"
            )
            progressRow(
                title: "压缩",
                value: libraryModel.compressionProgress,
                symbol: "arrow.down.right.and.arrow.up.left"
            )
            Text("\(libraryModel.completedItemCount) 项已完成")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(PhotoSlimiOSTheme.surface)
    }

    private func progressRow(title: String, value: Double, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .frame(width: 72, alignment: .leading)
            ProgressView(value: value)
                .tint(PhotoSlimiOSTheme.signal)
            Text("\(Int(value * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .frame(minHeight: PhotoSlimiOSTheme.minimumTouchHeight)
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("压缩结果已准备好", systemImage: "checkmark.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PhotoSlimiOSTheme.success)
                Text("点按结果放大查看；按住图片可以临时显示原图。原件仍保留在照片图库。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 16
            ) {
                ForEach(libraryModel.previews) { preview in
                    PhotoSlimiOSReviewTile(preview: preview)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
    }

    @ViewBuilder
    private var bottomActionBar: some View {
        if libraryModel.isProcessing {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在处理")
                        .font(.subheadline.weight(.semibold))
                    ProgressView(value: (libraryModel.downloadProgress + libraryModel.compressionProgress) / 2)
                        .tint(PhotoSlimiOSTheme.signal)
                }
                Spacer()
                Button("终止", role: .destructive) {
                    libraryModel.cancelCompression()
                }
                .frame(minHeight: PhotoSlimiOSTheme.minimumTouchHeight)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        } else if !libraryModel.previews.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("确认结果后再写入相册")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    Button("撤回压缩副本") {
                        libraryModel.discardPreviews()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, minHeight: PhotoSlimiOSTheme.minimumTouchHeight)

                    Button("写入相册并删除原件") {
                        libraryModel.commitPreviews()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PhotoSlimiOSTheme.signal)
                    .frame(maxWidth: .infinity, minHeight: PhotoSlimiOSTheme.minimumTouchHeight)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        } else if libraryModel.selectedItemCount > 0 {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已选择 \(libraryModel.selectedItemCount) 项")
                        .font(.subheadline.weight(.semibold))
                    if let storage = libraryModel.availableStorageLabel {
                        Text("可用空间 \(storage)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("开始压缩") {
                    libraryModel.startCompression()
                }
                .buttonStyle(.borderedProminent)
                .tint(PhotoSlimiOSTheme.signal)
                .frame(minHeight: PhotoSlimiOSTheme.minimumTouchHeight)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

private struct PhotoSlimiOSAssetRow: View {
    let item: PhotoSlimiOSAssetItem
    @ObservedObject var model: PhotoSlimiOSLibraryModel

    private var isSelected: Bool {
        model.selectedIdentifiers.contains(item.id)
    }

    var body: some View {
        Button {
            model.toggleSelection(item)
        } label: {
            HStack(spacing: 12) {
                PhotoSlimiOSThumbnailView(
                    item: item,
                    model: model,
                    targetSize: CGSize(width: 180, height: 180),
                    side: 64
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(item.dimensionsLabel)
                        if let durationLabel = item.durationLabel {
                            Text(durationLabel)
                        }
                        if let sizeLabel = item.sizeLabel {
                            Text(sizeLabel)
                        }
                        if item.isCloudOnly {
                            Image(systemName: "icloud")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.pink)
                        .accessibilityLabel("收藏")
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? PhotoSlimiOSTheme.signal : .secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(minHeight: 80)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? PhotoSlimiOSTheme.signalSoft : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(assetAccessibilityLabel)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private var assetAccessibilityLabel: String {
        var values = [item.displayTitle, item.kind.title, item.dimensionsLabel]
        if let sizeLabel = item.sizeLabel {
            values.append(sizeLabel)
        } else if item.isCloudOnly {
            values.append("iCloud 原件")
        }
        return values.joined(separator: "，")
    }
}

private struct PhotoSlimiOSAssetGridTile: View {
    let item: PhotoSlimiOSAssetItem
    @ObservedObject var model: PhotoSlimiOSLibraryModel

    private var isSelected: Bool {
        model.selectedIdentifiers.contains(item.id)
    }

    var body: some View {
        Button {
            model.toggleSelection(item)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    PhotoSlimiOSThumbnailView(
                        item: item,
                        model: model,
                        targetSize: CGSize(width: 500, height: 500),
                        side: nil
                    )
                    .aspectRatio(4 / 3, contentMode: .fit)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? PhotoSlimiOSTheme.signal : .white)
                        .shadow(radius: 2)
                        .padding(8)
                }

                Text(item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(item.sizeLabel ?? item.dimensionsLabel)
                    if item.isCloudOnly {
                        Image(systemName: "icloud")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? PhotoSlimiOSTheme.signalSoft : PhotoSlimiOSTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayTitle)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}

private struct PhotoSlimiOSThumbnailView: View {
    let item: PhotoSlimiOSAssetItem
    @ObservedObject var model: PhotoSlimiOSLibraryModel
    let targetSize: CGSize
    let side: CGFloat?

#if canImport(UIKit)
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
#endif

    var body: some View {
        Group {
#if canImport(UIKit)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
#else
            placeholder
#endif
        }
        .frame(width: side, height: side)
        .frame(maxWidth: side == nil ? .infinity : nil)
        .background(PhotoSlimiOSTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear(perform: load)
        .onDisappear(perform: cancel)
    }

    private var placeholder: some View {
        Image(systemName: item.kind == .video ? "video" : "photo")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
#if canImport(UIKit)
        guard image == nil else { return }
        requestID = model.requestThumbnail(for: item.id, targetSize: targetSize) { image in
            self.image = image
        }
#endif
    }

    private func cancel() {
#if canImport(UIKit)
        if let requestID {
            model.cancelThumbnailRequest(requestID)
            self.requestID = nil
        }
#endif
    }
}

private struct PhotoSlimiOSReviewTile: View {
    let preview: PhotoSlimiOSPreview
    @State private var showingOriginal = false
    @State private var showingDetail = false

    private var displayedURL: URL {
        showingOriginal ? (preview.originalURL ?? preview.outputURL) : preview.outputURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if preview.kind == .video {
                    VideoPlayer(player: AVPlayer(url: displayedURL))
                } else {
                    imagePreview
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Text(showingOriginal ? "原图" : "压缩结果")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.62), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .onTapGesture {
                showingDetail = true
            }
            .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                showingOriginal = pressing
            }, perform: {})

            Text(preview.sourceFilename)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)

            if let savedBytes = preview.savedBytes {
                Text(savedBytes >= 0
                    ? "实际节省 \(ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file))"
                    : "结果更大")
                    .font(.caption)
                    .foregroundStyle(savedBytes >= 0 ? .secondary : PhotoSlimiOSTheme.warning)
            } else {
                Text("原件大小未知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingDetail) {
            PhotoSlimiOSPreviewDetail(preview: preview)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(preview.sourceFilename)，压缩结果")
        .accessibilityHint("点按放大，按住查看原图")
    }

    @ViewBuilder
    private var imagePreview: some View {
#if canImport(UIKit)
        if let image = UIImage(contentsOfFile: displayedURL.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PhotoSlimiOSTheme.elevated)
        } else {
            Image(systemName: "photo")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PhotoSlimiOSTheme.elevated)
        }
#else
        Image(systemName: "photo")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PhotoSlimiOSTheme.elevated)
#endif
    }
}
