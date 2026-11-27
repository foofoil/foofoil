# foofoil extension-kit

Internal development-module contracts for [foofoil](https://github.com/foofoil/foofoil).

This package is the independent source for Extension API v1: the stable C ABI, Manifest schema, capability identifiers, content-request and session value types, navigator and media contracts, compatibility fixtures, and contract tests. It supports independently developed foofoil modules and their integration tests. Extension/plugin terminology describes development internals only; the final product exposes these capabilities as part of foofoil, without separate plugin installation or updates.

Loading and UI stay in foofoil. Hi-Fi and EPUB implementations live in sibling repositories and are embedded by the app build/distribution scripts. Existing installation and Registry code is legacy infrastructure, not the product distribution strategy.

## What This Package Provides

- `FoofoilExtensionABI` — versioned C function-table header (`foofoil_extension_create`)
- `FoofoilExtensionKit` — Swift value types and validators for Manifest, `ContentRequest`, `ContentSession`, capabilities, navigator contributions, and media playback snapshots
- Manifest JSON Schema and compatibility fixtures
- Contract tests for encoding, validation, and API negotiation

The current internal binary boundary is the C ABI and JSON value messages. Swift protocols, SwiftUI views, and in-process objects are not part of the shared module API.

## Requirements

- macOS 15 or later
- Swift 6 / Xcode with the configured macOS SDK

## Use in a Development Module

Add the package as a sibling checkout:

```swift
dependencies: [
    .package(path: "../extension-kit")
]
```

Then declare `FoofoilExtensionKit` and/or `FoofoilExtensionABI` as target dependencies. Extensions may also speak only the C ABI and JSON messages, without importing the Swift module.

A `.foofoilextension` bundle looks like:

```text
Hi-Fi.foofoilextension
└── Contents
    ├── Info.plist
    ├── MacOS/
    │   └── <runtime>
    └── Resources
        └── ExtensionManifest.json
```

See the Manifest schema at `Sources/FoofoilExtensionKit/Resources/ExtensionManifest.schema.json`.

## Build and Test

```sh
swift test
```

## Related Repositories

| Repository | Role |
| --- | --- |
| [foofoil](https://github.com/foofoil/foofoil) | macOS app, module integration, and distribution |
| [hifi](https://github.com/foofoil/hifi) | Hi-Fi audio module for foofoil |

[简体中文](README.zh-CN.md)

## License

extension-kit is licensed under the [MIT License](LICENSE), copyright © 2026 Beijing Memory Vision Technology Co., Ltd.
