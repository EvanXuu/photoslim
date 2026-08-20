import SwiftUI
#if SWIFT_PACKAGE
import PhotoSlimiOSClient
#endif

@main
struct PhotoSlimiOSApp: App {
    var body: some Scene {
        WindowGroup {
            #if PHOTOSLIM_UNIFIED_APP
            PhotoSlimiOSUnifiedRootView()
            #else
            PhotoSlimiOSRootView()
            #endif
        }
    }
}
