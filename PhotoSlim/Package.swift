// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoSlim",
    // Desktop and iOS UI targets stay separate, while media capability and
    // automatic compression code are shared from iOS 17/macOS 14 onward.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "PhotoSlim", targets: ["PhotoSlim"]),
        .library(name: "PhotoSlimMediaCore", targets: ["PhotoSlimMediaCore"]),
        .library(name: "PhotoSlimiOSClient", targets: ["PhotoSlimiOSClient"]),
        .executable(name: "PhotoSlimiOSApp", targets: ["PhotoSlimiOSApp"])
    ],
    targets: [
        .target(
            name: "PhotoSlimMediaCore",
            path: "Sources/PhotoSlimMediaCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .target(
            name: "PhotoSlimiOSClient",
            dependencies: ["PhotoSlimMediaCore"],
            path: "Sources/PhotoSlimiOSClient",
            linkerSettings: [.linkedFramework("Photos")]
        ),
        .executableTarget(
            name: "PhotoSlimiOSApp",
            dependencies: ["PhotoSlimiOSClient"],
            path: "Sources/PhotoSlimiOSApp"
        ),
        .executableTarget(
            name: "PhotoSlim",
            dependencies: ["PhotoSlimMediaCore"],
            path: "Sources/PhotoSlim",
            linkerSettings: [
                .linkedFramework("Photos"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "PhotoSlimTests",
            dependencies: ["PhotoSlim"],
            path: "Tests/PhotoSlimTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
