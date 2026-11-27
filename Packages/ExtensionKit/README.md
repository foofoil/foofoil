# foofoil extension-kit

Internal development-module contracts for [foofoil](https://github.com/foofoil/foofoil).

This package is the internal source for Extension API v1: the stable C ABI, Manifest schema, capability identifiers, content-request and session value types, navigator and media contracts, compatibility fixtures, and contract tests. It supports the app's capability modules and their integration tests. Extension/plugin terminology describes development internals only; the final product exposes these capabilities as part of foofoil, without separate plugin installation or updates.

Loading and UI stay in the host app. Hi-Fi, EPUB, and Video implementations live under `Packages/` in the same repository and are embedded by the app build/distribution scripts. Existing installation and Registry code is legacy infrastructure, not the product distribution strategy.

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

Add the package from the repository's `Packages/` directory (for example, from `Packages/HiFi`):

```swift
dependencies: [
    .package(path: "../ExtensionKit")
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

## Related Modules

| Module | Role |
| --- | --- |
| [foofoil](../../README.md) | macOS app, module integration, and distribution |
| [Hi-Fi](../HiFi/README.md) | Hi-Fi audio module for foofoil |
| [EBook](../EBook/README.md) | EPUB parsing and reading |
| [Video](../Video/README.md) | Enhanced video playback |

[简体中文](README.zh-CN.md)

## License

extension-kit is licensed under the [MIT License](LICENSE), copyright © 2026 Beijing Memory Vision Technology Co., Ltd.
