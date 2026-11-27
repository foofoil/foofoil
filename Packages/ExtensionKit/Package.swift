// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "extension-kit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FoofoilExtensionKit", targets: ["FoofoilExtensionKit"]),
        .library(name: "FoofoilExtensionABI", targets: ["FoofoilExtensionABI"])
    ],
    targets: [
        .target(
            name: "FoofoilExtensionABI",
            publicHeadersPath: "include"
        ),
        .target(
            name: "FoofoilExtensionKit",
            dependencies: ["FoofoilExtensionABI"],
            resources: [
                .copy("Resources/ExtensionManifest.schema.json"),
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "FoofoilExtensionKitTests",
            dependencies: ["FoofoilExtensionKit", "FoofoilExtensionABI"]
        )
    ]
)
