import AVFoundation
import AppKit
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PhotoSlim

private final class VideoWriterHarness: @unchecked Sendable {
  let writer: AVAssetWriter
  let input: AVAssetWriterInput
  let adaptor: AVAssetWriterInputPixelBufferAdaptor

  init(
    writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
  ) {
    self.writer = writer
    self.input = input
    self.adaptor = adaptor
  }
}

final class MediaCompressionTests: XCTestCase {
  func testJPEGCompressesToVerifiedHEIC() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let jpeg = try makeJPEG(width: 160, height: 120)
    let source = mediaAsset(
      id: "image",
      kind: .photo,
      format: .jpeg,
      filename: "sample.jpg",
      width: 160,
      height: 120,
      duration: 0,
      bytes: Int64(jpeg.count)
    )
    var settings = CompressionSettings.recommended
    settings.minimumSavingsRatio = -1

    let output: CompressionOutput
    do {
      output = try await MediaCompressionEngine().compress(
        source: source,
        imageOriginal: ImageOriginal(
          data: jpeg,
          uniformTypeIdentifier: UTType.jpeg.identifier,
          orientation: .up
        ),
        videoAsset: nil,
        directory: directory,
        settings: settings,
        sessionID: UUID(),
        itemID: UUID(),
        progress: { _ in }
      )
    } catch CompressionError.imageEncodingFailed {
      throw XCTSkip("当前测试环境没有可用的 HEIC 图像编码器")
    }

    XCTAssertGreaterThan(output.byteCount, 0)
    XCTAssertEqual(output.originalFilename, "sample.heic")
    let imageSource = CGImageSourceCreateWithURL(output.fileURL as CFURL, nil)
    XCTAssertNotNil(imageSource)
    XCTAssertTrue(
      UTType(CGImageSourceGetType(imageSource!)! as String)?.conforms(to: .heic) == true)
  }

  func testH264CompressesToVerifiedHEVC() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let inputURL = directory.appendingPathComponent("input.mov")
    do {
      try await makeH264Video(at: inputURL, width: 320, height: 240, frameCount: 30)
    } catch {
      let message = error.localizedDescription.lowercased()
      if message.contains("cannot encode") || message.contains("encoder required") {
        throw XCTSkip("当前测试环境没有可用的视频编码器")
      }
      throw error
    }

    let inputAsset = AVURLAsset(url: inputURL)
    let duration = CMTimeGetSeconds(try await inputAsset.load(.duration))
    let bytes = Int64((try inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    let source = mediaAsset(
      id: "video",
      kind: .video,
      format: .h264,
      filename: "sample.mov",
      width: 320,
      height: 240,
      duration: duration,
      bytes: bytes
    )
    var settings = CompressionSettings.recommended
    settings.minimumSavingsRatio = -1

    let output: CompressionOutput
    do {
      output = try await MediaCompressionEngine().compress(
        source: source,
        imageOriginal: nil,
        videoAsset: inputAsset,
        directory: directory,
        settings: settings,
        sessionID: UUID(),
        itemID: UUID(),
        progress: { _ in }
      )
    } catch let error as CompressionError
      where error.localizedDescription.contains("编码器")
        || error.localizedDescription.contains("Cannot Encode")
    {
      throw XCTSkip("当前测试环境没有可用的 HEVC 编码器")
    } catch {
      let message = error.localizedDescription.lowercased()
      if message.contains("cannot encode") || message.contains("encoder required") {
        throw XCTSkip("当前测试环境没有可用的 HEVC 编码器")
      }
      throw error
    }

    let outputAsset = AVURLAsset(url: output.fileURL)
    let videoTrack = try await outputAsset.loadTracks(withMediaType: .video).first
    let description = try await videoTrack?.load(.formatDescriptions).first
    XCTAssertEqual(description.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_HEVC)
    XCTAssertGreaterThan(output.byteCount, 0)
    let outputRate = Double(try await videoTrack?.load(.estimatedDataRate) ?? 0)
    let sourceRate = Double(bytes) * 8 / max(duration, 0.001)
    XCTAssertLessThan(outputRate, max(250_000, sourceRate * 4))

    // Plain hvc1 is deliberately allowed as an explicit HEVC-to-HEVC
    // re-encode. Other HEVC sample entries remain rejected by the route
    // classifier; the generated camera-style output above exercises the
    // supported hvc1 path.
  }

  private func makeJPEG(width: Int, height: Int) throws -> Data {
    guard
      let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSColor(calibratedRed: 0.71, green: 0.30, blue: 0.08, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 36, y: 22, width: 84, height: 76)).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard
      let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    return data
  }

  private func makeH264Video(
    at url: URL,
    width: Int,
    height: Int,
    frameCount: Int
  ) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000],
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
      ]
    )
    guard writer.canAdd(input) else { throw CocoaError(.featureUnsupported) }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    let harness = VideoWriterHarness(writer: writer, input: input, adaptor: adaptor)

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let queue = DispatchQueue(label: "local.photoslim.tests.h264-writer")
      var frameIndex = 0
      var hasFinished = false
      harness.input.requestMediaDataWhenReady(on: queue) {
        guard !hasFinished else { return }
        while harness.input.isReadyForMoreMediaData, frameIndex < frameCount {
          guard let pool = harness.adaptor.pixelBufferPool else {
            hasFinished = true
            continuation.resume(throwing: CocoaError(.fileWriteUnknown))
            return
          }
          var optionalBuffer: CVPixelBuffer?
          guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
            let buffer = optionalBuffer
          else {
            hasFinished = true
            continuation.resume(throwing: CocoaError(.fileWriteUnknown))
            return
          }
          CVPixelBufferLockBaseAddress(buffer, [])
          if let base = CVPixelBufferGetBaseAddress(buffer) {
            let value = UInt8((frameIndex * 7) % 180 + 40)
            memset(base, Int32(value), CVPixelBufferGetDataSize(buffer))
          }
          CVPixelBufferUnlockBaseAddress(buffer, [])
          guard
            harness.adaptor.append(
              buffer, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: 30))
          else {
            hasFinished = true
            continuation.resume(throwing: harness.writer.error ?? CocoaError(.fileWriteUnknown))
            return
          }
          frameIndex += 1
        }
        if frameIndex == frameCount {
          hasFinished = true
          harness.input.markAsFinished()
          harness.writer.finishWriting {
            if harness.writer.status == .completed {
              continuation.resume(returning: ())
            } else {
              continuation.resume(throwing: harness.writer.error ?? CocoaError(.fileWriteUnknown))
            }
          }
        }
      }
    }
  }

  private func mediaAsset(
    id: String,
    kind: MediaKind,
    format: MediaFormatGroup,
    filename: String,
    width: Int,
    height: Int,
    duration: Double,
    bytes: Int64
  ) -> MediaAsset {
    MediaAsset(
      id: id,
      kind: kind,
      format: format,
      filename: filename,
      uniformTypeIdentifier: kind == .photo
        ? UTType.jpeg.identifier : UTType.quickTimeMovie.identifier,
      creationDate: Date(timeIntervalSince1970: 1_600_000_000),
      pixelWidth: width,
      pixelHeight: height,
      duration: duration,
      isFavorite: false,
      isHidden: false,
      isCloudOnly: false,
      originalBytes: bytes,
      codec: kind == .video ? "H.264" : nil,
      albumIdentifiers: [],
      exclusionReasons: []
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PhotoSlimMediaTests-\(UUID().uuidString)", isDirectory: true)
  }
}
