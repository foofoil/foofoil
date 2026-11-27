// swift-tools-version: 6.0
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let prefix = root + "/.build/ffmpeg"
let package = Package(
    name: "video", platforms: [.macOS(.v15)],
    products: [.library(name: "VideoExtensionRuntime", type: .dynamic, targets: ["VideoExtensionRuntime"]),
               .executable(name: "video-inspect", targets: ["VideoInspect"])],
    dependencies: [.package(path: "../ExtensionKit")],
    targets: [
        .target(name: "VideoDecoder", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-I" + prefix + "/include", "-fobjc-arc"])],
                linkerSettings: [.unsafeFlags(["-L" + prefix + "/lib"]),
                    .linkedLibrary("avformat"), .linkedLibrary("avcodec"), .linkedLibrary("avutil"),
                    .linkedLibrary("swscale"), .linkedLibrary("swresample"), .linkedLibrary("z"), .linkedLibrary("bz2"), .linkedLibrary("iconv"),
                    .linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox"),
                    .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"),
                    .linkedFramework("CoreVideo"), .linkedFramework("IOSurface"), .linkedFramework("AppKit")]),
        .target(name: "VideoExtensionRuntime", dependencies: ["VideoDecoder", .product(name: "FoofoilExtensionKit", package: "ExtensionKit"), .product(name: "FoofoilExtensionABI", package: "ExtensionKit")]),
        .executableTarget(name: "VideoInspect", dependencies: ["VideoExtensionRuntime", "VideoDecoder"]),
        .testTarget(name: "VideoExtensionTests", dependencies: ["VideoExtensionRuntime", "VideoDecoder"], resources: [.copy("Fixtures")])
    ])
