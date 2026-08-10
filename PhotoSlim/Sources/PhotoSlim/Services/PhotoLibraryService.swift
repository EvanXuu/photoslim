import AVFoundation
import AppKit
import Combine
import CoreLocation
import Foundation
import Photos
import UniformTypeIdentifiers

enum LibraryAccessState: Equatable, Sendable {
  case notDetermined
  case authorized
  case limited
  case denied
  case restricted

  var canRead: Bool { self == .authorized || self == .limited }

  var title: String {
    switch self {
    case .notDetermined: return "尚未授权"
    case .authorized: return "已允许访问所有照片"
    case .limited: return "仅允许部分照片"
    case .denied: return "照片访问已关闭"
    case .restricted: return "照片访问受系统限制"
    }
  }
}

enum PhotoLibraryError: LocalizedError {
  case accessDenied
  case assetNotFound(String)
  case originalUnavailable(String)
  case photoKit(String)
  case verificationFailed(String)

  var errorDescription: String? {
    switch self {
    case .accessDenied:
      return "PhotoSlim 没有读取和修改照片图库的权限。"
    case .assetNotFound(let identifier):
      return "找不到照片资产：\(identifier)"
    case .originalUnavailable(let name):
      return "无法取得原始文件：\(name)"
    case .photoKit(let message):
      return message
    case .verificationFailed(let message):
      return "压缩副本验证失败：\(message)"
    }
  }
}

struct ImageOriginal: Sendable {
  let data: Data
  let uniformTypeIdentifier: String
  let orientation: CGImagePropertyOrientation
}

struct ImportedAssetVerification: Sendable {
  let identifier: String
  let bytes: Int64
}

enum LibraryScanMode: String, Sendable {
  case full
  case incremental
  case metadataDiff
}

struct LibraryScanResult: Sendable {
  let assets: [MediaAsset]
  let changeTokenData: Data?
  let inspectedAssetCount: Int
  let removedAssetCount: Int
  let mode: LibraryScanMode
}

struct LibraryAssetSnapshot: Equatable, Sendable {
  let identifier: String
  let modificationTimestamp: TimeInterval?
}

struct LibraryIndexDiffResult: Equatable, Sendable {
  let changedIdentifiers: Set<String>
  let deletedIdentifiers: Set<String>
}

enum LibraryIndexDiff {
  static func compare(
    cached: [MediaAsset],
    current: [LibraryAssetSnapshot]
  ) -> LibraryIndexDiffResult {
    var cachedByIdentifier: [String: MediaAsset] = [:]
    for asset in cached {
      cachedByIdentifier[asset.id] = asset
    }

    var currentIdentifiers = Set<String>()
    var changedIdentifiers = Set<String>()
    for snapshot in current {
      currentIdentifiers.insert(snapshot.identifier)
      guard let cachedAsset = cachedByIdentifier[snapshot.identifier] else {
        changedIdentifiers.insert(snapshot.identifier)
        continue
      }
      if cachedAsset.modificationTimestamp != snapshot.modificationTimestamp {
        changedIdentifiers.insert(snapshot.identifier)
      }
    }

    return LibraryIndexDiffResult(
      changedIdentifiers: changedIdentifiers,
      deletedIdentifiers: Set(cachedByIdentifier.keys).subtracting(currentIdentifiers)
    )
  }
}

private final class PhotoLibraryChangeMonitor: NSObject, PHPhotoLibraryChangeObserver,
  @unchecked Sendable
{
  private let handler: @Sendable () -> Void

  init(handler: @escaping @Sendable () -> Void) {
    self.handler = handler
  }

  func photoLibraryDidChange(_ changeInstance: PHChange) {
    handler()
  }
}

private final class PhotoRequestCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var requestID = PHInvalidImageRequestID

  func set(_ requestID: PHImageRequestID) {
    lock.lock()
    self.requestID = requestID
    lock.unlock()
  }

  func cancel(using imageManager: PHImageManager) {
    lock.lock()
    let requestID = self.requestID
    lock.unlock()
    if requestID != PHInvalidImageRequestID {
      imageManager.cancelImageRequest(requestID)
    }
  }
}

enum VideoCodecClassifier {
  private static let hevcSubtypes: Set<FourCharCode> = [
    kCMVideoCodecType_HEVC,
    kCMVideoCodecType_HEVCWithAlpha,
    fourCC("hvc1"),
    fourCC("hev1"),
    fourCC("dvh1"),
    fourCC("dvhe"),
  ]
  private static let h264Subtypes: Set<FourCharCode> = [
    kCMVideoCodecType_H264,
    fourCC("avc3"),
  ]

  static func displayName(for subtypes: [FourCharCode]) -> String? {
    let subtypes = Set(subtypes)
    // hvc1 is the ordinary HEVC sample entry used by many camera files. Keep its
    // spelling in the model so the browser can offer an explicit HEVC re-encode,
    // while the other HEVC/Dolby Vision variants remain conservative exclusions.
    if !subtypes.isEmpty && subtypes.allSatisfy({ $0 == fourCC("hvc1") }) {
      return "HEVC (hvc1)"
    }
    // Favor the efficient-codec classification when an asset has multiple video
    // descriptions. This prevents an HEVC source from being offered for lossy re-encode.
    if !subtypes.isDisjoint(with: hevcSubtypes) { return "HEVC" }
    if !subtypes.isDisjoint(with: h264Subtypes) { return "H.264" }
    return subtypes.first.map(fourCCString)
  }

  static func fourCC(_ text: String) -> FourCharCode {
    text.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
  }

  static func fourCCString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08X", code)
  }

  static func isHVC1(_ subtypes: [FourCharCode]) -> Bool {
    !subtypes.isEmpty && subtypes.allSatisfy { $0 == fourCC("hvc1") }
  }

  static func isHEVC(_ subtype: FourCharCode) -> Bool {
    hevcSubtypes.contains(subtype)
  }
}

final class PhotoLibraryService: @unchecked Sendable {
  private let imageManager = PHCachingImageManager()
  private var changeMonitor: PhotoLibraryChangeMonitor?

  deinit {
    if let changeMonitor {
      PHPhotoLibrary.shared().unregisterChangeObserver(changeMonitor)
    }
  }

  var authorizationState: LibraryAccessState {
    Self.mapAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
  }

  func requestAuthorization() async -> LibraryAccessState {
    let status = await withCheckedContinuation { continuation in
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
        continuation.resume(returning: status)
      }
    }
    return Self.mapAuthorization(status)
  }

  func startObservingChanges(handler: @escaping @Sendable () -> Void) {
    if let changeMonitor {
      PHPhotoLibrary.shared().unregisterChangeObserver(changeMonitor)
    }
    let monitor = PhotoLibraryChangeMonitor(handler: handler)
    changeMonitor = monitor
    PHPhotoLibrary.shared().register(monitor)
  }

  func scan(
    settings: CompressionSettings,
    previousIndex: LibraryScanIndex?,
    processedIdentifiers: Set<String>,
    progress: @escaping @Sendable (_ completed: Int, _ total: Int, _ filename: String) -> Void
  ) async throws -> LibraryScanResult {
    guard authorizationState.canRead else { throw PhotoLibraryError.accessDenied }

    guard let previousIndex else {
      let tokenData = try? Self.archiveChangeToken(
        PHPhotoLibrary.shared().currentChangeToken
      )
      let scanned = try await inspectAssets(
        identifiers: nil,
        settings: settings,
        processedIdentifiers: processedIdentifiers,
        progress: progress
      )
      return LibraryScanResult(
        assets: scanned,
        changeTokenData: tokenData,
        inspectedAssetCount: scanned.count,
        removedAssetCount: 0,
        mode: .full
      )
    }

    let cachedAssets = previousIndex.assets.map {
      refreshed(
        $0,
        settings: settings,
        processedIdentifiers: processedIdentifiers
      )
    }

    if let tokenData = previousIndex.changeTokenData {
      do {
        let changes = try persistentAssetChanges(since: tokenData)
        return try await scanChangedAssets(
          cachedAssets: cachedAssets,
          changedIdentifiers: changes.changedIdentifiers,
          deletedIdentifiers: changes.deletedIdentifiers,
          changeTokenData: changes.changeTokenData,
          settings: settings,
          processedIdentifiers: processedIdentifiers,
          mode: .incremental,
          progress: progress
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // An expired token must not force another expensive original-file scan.
      }
    }

    return try await metadataDiffScan(
      cachedAssets: cachedAssets,
      settings: settings,
      processedIdentifiers: processedIdentifiers,
      progress: progress
    )
  }

  private func inspectAssets(
    identifiers: Set<String>?,
    settings: CompressionSettings,
    processedIdentifiers: Set<String>,
    progress: @escaping @Sendable (_ completed: Int, _ total: Int, _ filename: String) -> Void
  ) async throws -> [MediaAsset] {
    guard authorizationState.canRead else { throw PhotoLibraryError.accessDenied }
    if let identifiers, identifiers.isEmpty {
      progress(0, 0, "图库没有变更")
      return []
    }

    let result: PHFetchResult<PHAsset>
    if let identifiers {
      result = PHAsset.fetchAssets(
        withLocalIdentifiers: Array(identifiers),
        options: nil
      )
    } else {
      let options = PHFetchOptions()
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
      result = PHAsset.fetchAssets(with: options)
    }
    var scanned: [MediaAsset] = []
    scanned.reserveCapacity(result.count)

    for index in 0..<result.count {
      try Task.checkCancellation()
      let asset = result.object(at: index)
      let resources = PHAssetResource.assetResources(for: asset)
      let primary = primaryResource(for: asset, resources: resources)
      let filename = primary?.originalFilename ?? "未命名项目"
      progress(index, result.count, filename)

      var reasons = staticExclusionReasons(for: asset, resources: resources, primary: primary)
      if processedIdentifiers.contains(asset.localIdentifier) {
        reasons.insert(.alreadyProcessed)
      }
      var format = formatGroup(for: asset, uti: primary?.uniformTypeIdentifier)
      var codec: String?
      var originalBytes: Int64?
      var isCloudOnly = false

      if asset.mediaType == .image {
        let local = await localImageInspection(for: asset, resources: resources)
        originalBytes = local.bytes
        isCloudOnly = !local.isOriginalAvailable
      } else if asset.mediaType == .video {
        let local = await localVideoInspection(for: asset, resources: resources)
        originalBytes = local.bytes
        isCloudOnly = !local.isOriginalAvailable
        codec = local.codec
        if local.isHDR { reasons.insert(.hdr) }
        if local.codec == "H.264" {
          format = .h264
          reasons.remove(.codecUnverified)
        } else if local.codec == "HEVC (hvc1)" {
          format = .hevc
          reasons.remove(.efficientCodec)
          reasons.remove(.codecUnverified)
        } else if local.codec == "HEVC" {
          format = .hevc
          reasons.insert(.efficientCodec)
          reasons.remove(.codecUnverified)
        } else if !local.isOriginalAvailable {
          reasons.insert(.codecUnverified)
        } else if local.isOriginalAvailable {
          format = .other
          reasons.insert(.unsupported)
        }
      }

      let estimatedOutputBytes = originalBytes.map {
        MediaPlanning.estimatedOutputBytes(
          inputBytes: $0,
          kind: asset.mediaType == .video ? .video : .photo,
          settings: settings,
          duration: asset.duration
        )
      }
      if let originalBytes, let estimatedOutputBytes, originalBytes > 0,
        Double(originalBytes - estimatedOutputBytes) / Double(originalBytes)
          < settings.minimumSavingsRatio
      {
        reasons.insert(.lowSavings)
      }

      let collections = PHAssetCollection.fetchAssetCollectionsContaining(
        asset,
        with: .album,
        options: nil
      )
      var albumIdentifiers: [String] = []
      collections.enumerateObjects { collection, _, _ in
        if collection.canPerform(PHCollectionEditOperation.addContent) {
          albumIdentifiers.append(collection.localIdentifier)
        }
      }

      let location = asset.location
      scanned.append(
        MediaAsset(
          id: asset.localIdentifier,
          kind: asset.mediaType == .video ? .video : .photo,
          format: format,
          filename: filename,
          uniformTypeIdentifier: primary?.uniformTypeIdentifier ?? "",
          creationDate: asset.creationDate,
          modificationTimestamp: asset.modificationDate?.timeIntervalSince1970,
          pixelWidth: asset.pixelWidth,
          pixelHeight: asset.pixelHeight,
          duration: asset.duration,
          isFavorite: asset.isFavorite,
          isHidden: asset.isHidden,
          isCloudOnly: isCloudOnly,
          locationLatitude: location?.coordinate.latitude,
          locationLongitude: location?.coordinate.longitude,
          locationAltitude: location?.altitude,
          originalBytes: originalBytes,
          estimatedOutputBytes: estimatedOutputBytes,
          codec: codec,
          albumIdentifiers: albumIdentifiers,
          exclusionReasons: reasons
        ))
    }

    progress(result.count, result.count, "扫描完成")
    return scanned
  }

  private func metadataDiffScan(
    cachedAssets: [MediaAsset],
    settings: CompressionSettings,
    processedIdentifiers: Set<String>,
    progress: @escaping @Sendable (_ completed: Int, _ total: Int, _ filename: String) -> Void
  ) async throws -> LibraryScanResult {
    let changeTokenData = try? Self.archiveChangeToken(
      PHPhotoLibrary.shared().currentChangeToken
    )
    let result = PHAsset.fetchAssets(with: nil)
    var snapshots: [LibraryAssetSnapshot] = []
    snapshots.reserveCapacity(result.count)
    for index in 0..<result.count {
      if index.isMultiple(of: 512) { try Task.checkCancellation() }
      let asset = result.object(at: index)
      snapshots.append(
        LibraryAssetSnapshot(
          identifier: asset.localIdentifier,
          modificationTimestamp: asset.modificationDate?.timeIntervalSince1970
        )
      )
    }

    let diff = LibraryIndexDiff.compare(cached: cachedAssets, current: snapshots)
    return try await scanChangedAssets(
      cachedAssets: cachedAssets,
      changedIdentifiers: diff.changedIdentifiers,
      deletedIdentifiers: diff.deletedIdentifiers,
      changeTokenData: changeTokenData,
      settings: settings,
      processedIdentifiers: processedIdentifiers,
      mode: .metadataDiff,
      progress: progress
    )
  }

  private func scanChangedAssets(
    cachedAssets: [MediaAsset],
    changedIdentifiers: Set<String>,
    deletedIdentifiers: Set<String>,
    changeTokenData: Data?,
    settings: CompressionSettings,
    processedIdentifiers: Set<String>,
    mode: LibraryScanMode,
    progress: @escaping @Sendable (_ completed: Int, _ total: Int, _ filename: String) -> Void
  ) async throws -> LibraryScanResult {
    let identifiers = changedIdentifiers.subtracting(deletedIdentifiers)
    let changedAssets = try await inspectAssets(
      identifiers: identifiers,
      settings: settings,
      processedIdentifiers: processedIdentifiers,
      progress: progress
    )

    var assetsByIdentifier: [String: MediaAsset] = [:]
    for asset in cachedAssets where assetsByIdentifier[asset.id] == nil {
      assetsByIdentifier[asset.id] = asset
    }
    for identifier in deletedIdentifiers {
      assetsByIdentifier.removeValue(forKey: identifier)
    }

    let fetchedIdentifiers = Set(changedAssets.map(\.id))
    for identifier in identifiers.subtracting(fetchedIdentifiers) {
      assetsByIdentifier.removeValue(forKey: identifier)
    }
    for asset in changedAssets {
      var refreshedAsset = asset
      // Pinning is a browser preference, not PhotoKit metadata. Keep it when
      // an asset is rescanned after a library change.
      refreshedAsset.isPinned = assetsByIdentifier[asset.id]?.isPinned ?? false
      assetsByIdentifier[asset.id] = refreshedAsset
    }

    let status =
      changedAssets.isEmpty && deletedIdentifiers.isEmpty
      ? "图库没有变更"
      : "增量扫描完成"
    progress(changedAssets.count, changedAssets.count, status)
    return LibraryScanResult(
      assets: Self.sortAssets(Array(assetsByIdentifier.values)),
      changeTokenData: changeTokenData,
      inspectedAssetCount: changedAssets.count,
      removedAssetCount: deletedIdentifiers.count,
      mode: mode
    )
  }

  private func refreshed(
    _ asset: MediaAsset,
    settings: CompressionSettings,
    processedIdentifiers: Set<String>
  ) -> MediaAsset {
    var result = asset
    result.refreshPlanning(
      settings: settings,
      processedIdentifiers: processedIdentifiers
    )
    return result
  }

  private struct PersistentAssetChanges {
    let changedIdentifiers: Set<String>
    let deletedIdentifiers: Set<String>
    let changeTokenData: Data?
  }

  private func persistentAssetChanges(since data: Data) throws -> PersistentAssetChanges {
    guard
      let token = try NSKeyedUnarchiver.unarchivedObject(
        ofClass: PHPersistentChangeToken.self,
        from: data
      )
    else {
      throw PhotoLibraryError.photoKit("无法读取照片图库增量扫描标记。")
    }

    let fetchResult = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
    var changedIdentifiers = Set<String>()
    var deletedIdentifiers = Set<String>()
    var latestToken = token
    var detailsError: Error?

    fetchResult.__enumerateChanges { change, _ in
      latestToken = change.changeToken
      do {
        let details = try change.changeDetails(for: PHObjectType.asset)
        changedIdentifiers.formUnion(details.insertedLocalIdentifiers)
        changedIdentifiers.formUnion(details.updatedLocalIdentifiers)
        deletedIdentifiers.formUnion(details.deletedLocalIdentifiers)
      } catch {
        detailsError = error
      }
    }
    if let detailsError { throw detailsError }

    return PersistentAssetChanges(
      changedIdentifiers: changedIdentifiers,
      deletedIdentifiers: deletedIdentifiers,
      changeTokenData: try Self.archiveChangeToken(latestToken)
    )
  }

  private static func archiveChangeToken(_ token: PHPersistentChangeToken) throws -> Data {
    try NSKeyedArchiver.archivedData(
      withRootObject: token,
      requiringSecureCoding: true
    )
  }

  private static func sortAssets(_ assets: [MediaAsset]) -> [MediaAsset] {
    assets.sorted {
      let leftDate = $0.creationDate ?? .distantPast
      let rightDate = $1.creationDate ?? .distantPast
      if leftDate == rightDate { return $0.id < $1.id }
      return leftDate > rightDate
    }
  }

  func requestImageOriginal(
    identifier: String,
    networkAllowed: Bool,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> ImageOriginal {
    let asset = try fetchAsset(identifier: identifier)
    let options = PHImageRequestOptions()
    options.version = .original
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = networkAllowed
    options.progressHandler = { value, _, _, _ in progress?(value) }

    let cancellation = PhotoRequestCancellation()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        cancellation.set(imageManager.requestImageDataAndOrientation(
          for: asset,
          options: options
        ) { data, uti, orientation, info in
          if let error = info?[PHImageErrorKey] as? Error {
            continuation.resume(throwing: error)
          } else if let data {
            continuation.resume(
              returning: ImageOriginal(
                data: data,
                uniformTypeIdentifier: uti ?? "",
                orientation: orientation
              ))
          } else {
            continuation.resume(
              throwing: PhotoLibraryError.originalUnavailable(
                PHAssetResource.assetResources(for: asset).first?.originalFilename ?? identifier
              ))
          }
        })
      }
    }, onCancel: {
      cancellation.cancel(using: imageManager)
    })
  }

  func requestPreviewImage(
    identifier: String,
    kind: MediaKind,
    targetSize: CGSize,
    networkAllowed: Bool
  ) async -> NSImage? {
    guard let asset = try? fetchAsset(identifier: identifier) else { return nil }
    if kind == .photo {
      let options = PHImageRequestOptions()
      options.version = .original
      options.deliveryMode = .highQualityFormat
      options.resizeMode = .fast
      options.isNetworkAccessAllowed = networkAllowed
      return await withCheckedContinuation { continuation in
        imageManager.requestImage(
          for: asset,
          targetSize: targetSize,
          contentMode: .aspectFit,
          options: options
        ) { image, _ in
          continuation.resume(returning: image)
        }
      }
    }

    guard let video = try? await requestVideoAsset(
      identifier: identifier,
      networkAllowed: networkAllowed
    ) else { return nil }
    let generator = AVAssetImageGenerator(asset: video)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = targetSize
    return await withCheckedContinuation { continuation in
      let time = NSValue(time: .zero)
      generator.generateCGImagesAsynchronously(forTimes: [time]) {
        _, image, _, _, _ in
        if let image {
          continuation.resume(returning: NSImage(cgImage: image, size: .zero))
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  func requestVideoAsset(
    identifier: String,
    networkAllowed: Bool,
    progress: (@Sendable (Double) -> Void)? = nil
  ) async throws -> AVAsset {
    let asset = try fetchAsset(identifier: identifier)
    let options = PHVideoRequestOptions()
    options.version = .original
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = networkAllowed
    options.progressHandler = { value, _, _, _ in progress?(value) }

    let cancellation = PhotoRequestCancellation()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        cancellation.set(imageManager.requestAVAsset(forVideo: asset, options: options) {
          avAsset, _, info in
          if let error = info?[PHImageErrorKey] as? Error {
            continuation.resume(throwing: error)
          } else if let avAsset {
            continuation.resume(returning: avAsset)
          } else {
            continuation.resume(
              throwing: PhotoLibraryError.originalUnavailable(
                PHAssetResource.assetResources(for: asset).first?.originalFilename ?? identifier
              ))
          }
        })
      }
    }, onCancel: {
      cancellation.cancel(using: imageManager)
    })
  }

  /// Returns the byte count reported by Photos for the original resource when
  /// the current system has made it available. On older systems, or before
  /// iCloud finishes resolving a resource, Photos may return nil.
  func knownOriginalResourceBytes(identifier: String) -> Int64? {
    guard let asset = try? fetchAsset(identifier: identifier) else { return nil }
    let resources = PHAssetResource.assetResources(for: asset)
    return knownOriginalResourceBytes(for: asset, resources: resources)
  }

  func importCompressedAsset(
    fileURL: URL,
    originalFilename: String,
    source: MediaAsset
  ) async throws -> String {
    guard authorizationState.canRead else { throw PhotoLibraryError.accessDenied }
    var placeholderIdentifier: String?

    try await performChanges {
      let request = PHAssetCreationRequest.forAsset()
      request.creationDate = source.creationDate
      request.isFavorite = source.isFavorite
      request.isHidden = source.isHidden
      if let latitude = source.locationLatitude, let longitude = source.locationLongitude {
        request.location = CLLocation(
          coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
          altitude: source.locationAltitude ?? 0,
          horizontalAccuracy: -1,
          verticalAccuracy: -1,
          timestamp: source.creationDate ?? Date()
        )
      }

      let resourceOptions = PHAssetResourceCreationOptions()
      resourceOptions.originalFilename = originalFilename
      resourceOptions.shouldMoveFile = false
      request.addResource(
        with: source.kind == .photo ? .photo : .video,
        fileURL: fileURL,
        options: resourceOptions
      )
      guard let placeholder = request.placeholderForCreatedAsset else { return }
      placeholderIdentifier = placeholder.localIdentifier

      let collections = PHAssetCollection.fetchAssetCollections(
        withLocalIdentifiers: source.albumIdentifiers,
        options: nil
      )
      collections.enumerateObjects { collection, _, _ in
        PHAssetCollectionChangeRequest(for: collection)?.addAssets([placeholder] as NSArray)
      }
    }

    guard let placeholderIdentifier else {
      throw PhotoLibraryError.photoKit("照片图库没有返回新资产标识。")
    }
    return placeholderIdentifier
  }

  func verifyImportedAsset(
    identifier: String,
    source: MediaAsset,
    expectedFileURL: URL
  ) async throws -> ImportedAssetVerification {
    let created = try fetchAsset(identifier: identifier)
    guard created.mediaType == (source.kind == .photo ? .image : .video) else {
      throw PhotoLibraryError.verificationFailed("媒体类型不一致")
    }
    let dimensionsMatch =
      source.kind == .video
      ? MediaDimensionMatcher.matches(
        outputWidth: created.pixelWidth,
        outputHeight: created.pixelHeight,
        sourceWidth: source.pixelWidth,
        sourceHeight: source.pixelHeight
      )
      : created.pixelWidth == source.pixelWidth && created.pixelHeight == source.pixelHeight
    guard dimensionsMatch else {
      throw PhotoLibraryError.verificationFailed("像素尺寸不一致")
    }
    if source.kind == .video,
      abs(created.duration - source.duration) > max(0.15, source.duration * 0.001)
    {
      throw PhotoLibraryError.verificationFailed("视频时长不一致")
    }
    if let sourceDate = source.creationDate, let createdDate = created.creationDate,
      abs(createdDate.timeIntervalSince(sourceDate)) > 1
    {
      throw PhotoLibraryError.verificationFailed("拍摄日期不一致")
    }
    guard created.isFavorite == source.isFavorite, created.isHidden == source.isHidden else {
      throw PhotoLibraryError.verificationFailed("收藏或隐藏状态不一致")
    }
    if let latitude = source.locationLatitude, let longitude = source.locationLongitude {
      guard let location = created.location,
        abs(location.coordinate.latitude - latitude) < 0.000_001,
        abs(location.coordinate.longitude - longitude) < 0.000_001
      else {
        throw PhotoLibraryError.verificationFailed("位置信息不一致")
      }
      if let altitude = source.locationAltitude, abs(location.altitude - altitude) > 1 {
        throw PhotoLibraryError.verificationFailed("位置高度不一致")
      }
    }
    if !source.albumIdentifiers.isEmpty {
      let collections = PHAssetCollection.fetchAssetCollectionsContaining(
        created,
        with: .album,
        options: nil
      )
      var createdAlbumIdentifiers = Set<String>()
      collections.enumerateObjects { collection, _, _ in
        createdAlbumIdentifiers.insert(collection.localIdentifier)
      }
      let missing = Set(source.albumIdentifiers).subtracting(createdAlbumIdentifiers)
      guard missing.isEmpty else {
        throw PhotoLibraryError.verificationFailed("普通相簿关系未完整复制")
      }
    }

    let bytes = Int64((try expectedFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    guard bytes > 0 else { throw PhotoLibraryError.verificationFailed("输出文件为空") }
    return ImportedAssetVerification(identifier: identifier, bytes: bytes)
  }

  func deleteAssets(identifiers: [String]) async throws {
    guard !identifiers.isEmpty else { return }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
    guard assets.count > 0 else { return }
    try await performChanges {
      PHAssetChangeRequest.deleteAssets(assets)
    }
  }

  func findCreatedAsset(
    originalFilename: String,
    marker: String,
    source: MediaAsset
  ) async -> String? {
    guard !originalFilename.isEmpty else { return nil }
    let result = PHAsset.fetchAssets(with: nil)
    var candidates: [String] = []
    let dimensionsMatch: (Int, Int) -> Bool = { width, height in
      if source.kind == .video {
        return MediaDimensionMatcher.matches(
          outputWidth: width,
          outputHeight: height,
          sourceWidth: source.pixelWidth,
          sourceHeight: source.pixelHeight
        )
      }
      return width == source.pixelWidth && height == source.pixelHeight
    }
    result.enumerateObjects { asset, _, _ in
      guard asset.localIdentifier != source.id,
        asset.mediaType == (source.kind == .photo ? .image : .video),
        dimensionsMatch(asset.pixelWidth, asset.pixelHeight),
        PHAssetResource.assetResources(for: asset).contains(where: {
          $0.originalFilename == originalFilename
        })
      else { return }
      if let sourceDate = source.creationDate, let candidateDate = asset.creationDate,
        abs(sourceDate.timeIntervalSince(candidateDate)) > 1
      {
        return
      }
      candidates.append(asset.localIdentifier)
    }

    for identifier in candidates {
      if source.kind == .photo {
        guard
          let original = try? await requestImageOriginal(
            identifier: identifier,
            networkAllowed: false
          ),
          let imageSource = CGImageSourceCreateWithData(original.data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any],
          let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
          let comment = exif[kCGImagePropertyExifUserComment] as? String
        else { continue }
        if comment.contains(marker) { return identifier }
      } else {
        guard
          let avAsset = try? await requestVideoAsset(
            identifier: identifier,
            networkAllowed: false
          ), let metadata = try? await avAsset.load(.metadata)
        else { continue }
        for item in metadata {
          if let value = try? await item.load(.stringValue), value.contains(marker) {
            return identifier
          }
        }
      }
    }
    return nil
  }

  func fetchAsset(identifier: String) throws -> PHAsset {
    guard
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    else {
      throw PhotoLibraryError.assetNotFound(identifier)
    }
    return asset
  }

  private func performChanges(_ changes: @escaping () -> Void) async throws {
    try await withCheckedThrowingContinuation { continuation in
      PHPhotoLibrary.shared().performChanges(changes) { success, error in
        if success {
          continuation.resume(returning: ())
        } else {
          continuation.resume(throwing: error ?? PhotoLibraryError.photoKit("照片图库操作失败。"))
        }
      }
    }
  }

  private func localImageInspection(
    for asset: PHAsset,
    resources: [PHAssetResource]
  ) async -> (
    bytes: Int64?, isOriginalAvailable: Bool
  ) {
    let knownBytes = knownOriginalResourceBytes(for: asset, resources: resources)
    let options = PHImageRequestOptions()
    options.version = .original
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = false

    return await withCheckedContinuation { continuation in
      imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
        continuation.resume(
          returning: (data.map { Int64($0.count) } ?? knownBytes, data != nil)
        )
      }
    }
  }

  private func localVideoInspection(
    for asset: PHAsset,
    resources: [PHAssetResource]
  ) async -> (
    bytes: Int64?, isOriginalAvailable: Bool, codec: String?, isHDR: Bool
  ) {
    let knownBytes = knownOriginalResourceBytes(for: asset, resources: resources)
    let options = PHVideoRequestOptions()
    options.version = .original
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = false

    let avAsset: AVAsset? = await withCheckedContinuation { continuation in
      imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
        continuation.resume(returning: avAsset)
      }
    }
    guard let avAsset else { return (knownBytes, false, nil, false) }
    let inspection = await inspectVideoStreams(in: avAsset)
    let codec = VideoCodecClassifier.displayName(for: inspection.subtypes)
    let hdr = inspection.isHDR
    let size: Int64?
    let measuredSizes = inspection.sourceURLs.compactMap { url -> Int64? in
      guard url.isFileURL,
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        value > 0
      else { return nil }
      return Int64(value)
    }
    if let knownBytes {
      size = knownBytes
    } else if measuredSizes.isEmpty {
      size = nil
    } else {
      size = measuredSizes.reduce(0) { total, value in
        total > Int64.max - value ? Int64.max : total + value
      }
    }
    return (size, true, codec, hdr)
  }

  private func inspectVideoStreams(in avAsset: AVAsset) async -> (
    subtypes: [FourCharCode], isHDR: Bool, sourceURLs: [URL]
  ) {
    var subtypes: [FourCharCode] = []
    var isHDR = false
    var sourceURLs: Set<URL> = []

    if let urlAsset = avAsset as? AVURLAsset {
      sourceURLs.insert(urlAsset.url)
    }

    let tracks = (try? await avAsset.loadTracks(withMediaType: .video)) ?? []
    for track in tracks {
      let descriptions = (try? await track.load(.formatDescriptions)) ?? []
      subtypes.append(contentsOf: descriptions.map(CMFormatDescriptionGetMediaSubType))
      if descriptions.contains(where: Self.formatDescriptionIsHDR) { isHDR = true }

      if let compositionTrack = track as? AVCompositionTrack {
        for segment in compositionTrack.segments where !segment.isEmpty {
          if let sourceURL = segment.sourceURL { sourceURLs.insert(sourceURL) }
        }
      }
    }

    // PhotoKit can vend an AVComposition. Its top-level track may not expose source
    // format descriptions, so inspect each unique local segment URL as well.
    for sourceURL in sourceURLs {
      let sourceAsset = AVURLAsset(url: sourceURL)
      let sourceTracks = (try? await sourceAsset.loadTracks(withMediaType: .video)) ?? []
      for track in sourceTracks {
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        subtypes.append(contentsOf: descriptions.map(CMFormatDescriptionGetMediaSubType))
        if descriptions.contains(where: Self.formatDescriptionIsHDR) { isHDR = true }
      }
    }

    return (subtypes, isHDR, Array(sourceURLs))
  }

  private func primaryResource(for asset: PHAsset, resources: [PHAssetResource]) -> PHAssetResource?
  {
    let preferred: [PHAssetResourceType] =
      asset.mediaType == .video
      ? [.fullSizeVideo, .video]
      : [.fullSizePhoto, .photo]
    return preferred.compactMap { type in resources.first(where: { $0.type == type }) }.first
      ?? resources.first
  }

  private func knownOriginalResourceBytes(
    for asset: PHAsset,
    resources: [PHAssetResource]
  ) -> Int64? {
    guard #available(macOS 27.0, *) else { return nil }
    guard let primary = primaryResource(for: asset, resources: resources),
      let size = primary.value(forKey: "dataSize") as? NSNumber,
      size.int64Value > 0
    else { return nil }
    return size.int64Value
  }

  private func staticExclusionReasons(
    for asset: PHAsset,
    resources: [PHAssetResource],
    primary: PHAssetResource?
  ) -> Set<ExclusionReason> {
    var reasons: Set<ExclusionReason> = []
    let subtype = asset.mediaSubtypes
    let uti = primary?.uniformTypeIdentifier
    let type = uti.flatMap(UTType.init)

    if resources.contains(where: { $0.type == .adjustmentData }) { reasons.insert(.edited) }
    if type?.conforms(to: .rawImage) == true { reasons.insert(.raw) }
    if subtype.contains(.photoLive) { reasons.insert(.livePhoto) }
    if subtype.contains(.photoHDR) { reasons.insert(.hdr) }
    if subtype.contains(.videoHighFrameRate) { reasons.insert(.highFrameRate) }
    if subtype.contains(.videoCinematic) { reasons.insert(.cinematic) }
    if subtype.contains(.spatialMedia) { reasons.insert(.spatial) }
    if subtype.contains(.videoScreenRecording) { reasons.insert(.screenRecording) }
    if asset.isHidden { reasons.insert(.hidden) }

    let format = formatGroup(for: asset, uti: uti)
    if format == .heic || format == .hevc { reasons.insert(.efficientCodec) }
    if format == .png || type?.conforms(to: .gif) == true {
      reasons.insert(.transparencyOrAnimation)
    }
    if asset.mediaType == .image, format != .jpeg, format != .heic, format != .raw, format != .png {
      reasons.insert(.unsupported)
    }
    return reasons
  }

  private func formatGroup(for asset: PHAsset, uti: String?) -> MediaFormatGroup {
    guard let uti, let type = UTType(uti) else {
      return asset.mediaType == .video ? .unknown : .unknown
    }
    if type.conforms(to: .jpeg) { return .jpeg }
    if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
    if type.conforms(to: .png) { return .png }
    if type.conforms(to: .rawImage) { return .raw }
    return asset.mediaType == .video ? .unknown : .other
  }

  private static func mapAuthorization(_ status: PHAuthorizationStatus) -> LibraryAccessState {
    switch status {
    case .authorized: return .authorized
    case .limited: return .limited
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notDetermined
    @unknown default: return .restricted
    }
  }

  private static func formatDescriptionIsHDR(_ description: CMFormatDescription) -> Bool {
    guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] else {
      return false
    }
    let text = String(describing: extensions).lowercased()
    return text.contains("2084") || text.contains("hlg") || text.contains("smpte_st_2084")
  }
}

@MainActor
final class ThumbnailLoader: ObservableObject {
  @Published var image: NSImage?
  private var requestID: PHImageRequestID = PHInvalidImageRequestID

  func load(identifier: String, targetSize: CGSize) {
    cancel()
    guard
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    else {
      return
    }
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = false
    requestID = PHImageManager.default().requestImage(
      for: asset,
      targetSize: targetSize,
      contentMode: .aspectFit,
      options: options
    ) { [weak self] image, _ in
      guard let image else { return }
      Task { @MainActor in self?.image = image }
    }
  }

  func cancel() {
    if requestID != PHInvalidImageRequestID {
      PHImageManager.default().cancelImageRequest(requestID)
      requestID = PHInvalidImageRequestID
    }
  }

  deinit {
    if requestID != PHInvalidImageRequestID {
      PHImageManager.default().cancelImageRequest(requestID)
    }
  }
}
