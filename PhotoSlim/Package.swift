// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoSlim",
    // The desktop UI remains macOS-only. The shared media capability target
    // is intentionally available from iOS 15 onward so a future PhotoKit iOS
    // client does not need to support obsolete HEVC stacks.
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        .executable(name: "PhotoSlim", targets: ["PhotoSlim"]),
        .library(name: "PhotoSlimMediaCore", targets: ["PhotoSlimMediaCore"])
    ],
    targets: [
        .target(
            name: "PhotoSlimMediaCore",
            path: "Sources/PhotoSlimMediaCore",
            linkerSettings: [.linkedFramework("VideoToolbox")]
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
