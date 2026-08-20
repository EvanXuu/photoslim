import VideoToolbox

/// Platform-neutral media capability surface shared by the macOS and iOS
/// PhotoKit clients.
public enum PhotoSlimMediaCore {
  public static let minimumSupportedIOSVersion = "17.0"

  public static var supportsHardwareHEVCEncoding: Bool {
    // The explicit “require hardware” encoder specification became public on
    // iOS 17.4/macOS 10.9. The iOS 17 deployment floor excludes the older A8/A9
    // devices that cannot provide the hardware HEVC encode path. On iOS 17.0
    // through 17.3, the platform floor is the compatibility guarantee; on
    // newer releases, the compression session remains the final authority.
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
