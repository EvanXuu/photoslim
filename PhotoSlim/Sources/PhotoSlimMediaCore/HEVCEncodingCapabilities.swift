import VideoToolbox

/// Small platform-neutral media capability surface shared by future PhotoKit
/// clients. The macOS SwiftUI application consumes the same check today.
public enum PhotoSlimMediaCore {
  public static let minimumSupportedIOSVersion = "15.0"

  public static var supportsHardwareHEVCEncoding: Bool {
    // The explicit “require hardware” encoder specification became public on
    // iOS 17.4/macOS 10.9. On earlier supported iOS releases HEVC encode is a
    // device capability of the Apple hardware; the real compression session
    // remains the final authority and reports failure if it cannot be created.
    if #available(iOS 17.4, macOS 10.9, *) {
      var session: VTCompressionSession?
      let specification: [String: Any] = [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
      ]
      let status = VTCompressionSessionCreate(
        allocator: nil,
        width: 16,
        height: 16,
        codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: specification as CFDictionary,
        imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &session
      )
      if let session { VTCompressionSessionInvalidate(session) }
      return status == noErr
    }
    return true
  }
}
