# foofoil 浮箔

**Anything, right where you need it.**
**给你的桌面降维。**

[简体中文](README.zh-CN.md)

foofoil is a lightweight reference app for macOS that keeps images, videos, audio, documents, notes, and web content visible in minimal floating windows — called foils — while you work.

The name **foofoil** combines *foo* — the familiar placeholder for anything or arbitrary content — with *foil*, a thin sheet that carries whatever you put on it. It reflects a simple idea: whatever the content is, keep it lightweight and right where you need it.

Built with SwiftUI and AppKit, foofoil favors native macOS capabilities, fast interaction, and a small dependency footprint.

## Features

- Open multiple independent floating windows.
- Pin a window above other apps, adjust its opacity, and show or hide its border.
- Drag, resize, zoom, and position windows across multiple displays.
- Open images, videos, audio, Hi-Fi audio, EPUB e-books, PDFs, plain text, Markdown, CSV, HTML, and web URLs.
- Paste or open an image directly from the clipboard.
- Preview Markdown, browse CSV data as a table, and navigate PDF pages.
- Zoom images and web content, fit images to a window, and customize SVG colors or the document look: background, text color, font, line spacing and paragraph spacing for plain text, Markdown and EPUB foils, following light/dark appearance changes.
- Save, copy, share, or capture displayed content using native macOS workflows.
- Restore window state and keep a local content history.
- Search history by title and content, including on-device OCR for images and extracted text from PDFs and web pages.
- Use ⌘P to search history alongside Spotlight filename results from authorized folders.
- Customize keyboard shortcuts in Settings and use English or Simplified Chinese throughout the interface.

Hi-Fi currently supports DSF, raw DFF, uncompressed stereo SACD ISO, and APE/CUE. DSD playback requires a DoP-capable output device, with no DSD-to-PCM fallback; DST and SACD multichannel are not supported yet. EPUB supports table-of-contents navigation and reading-position restore; DRM-protected books are unsupported.

## Lightweight by Design

foofoil keeps its footprint small by using macOS system frameworks wherever they already provide the capability well, rather than bundling another browser engine, language runtime, or large general-purpose media stack. Lightweight is an implementation principle: keep dependencies focused, reuse native capabilities, and avoid carrying infrastructure the system already provides.

## Quick Start

Launch foofoil and then use any of these methods:

- Drag a supported file, image, or text onto a foofoil window.
- Choose **File > Open** (<kbd>⌘ O</kbd>) to open a local file.
- Choose **File > Open URL** (<kbd>⌘ L</kbd>) to display a web page.
- Choose **File > Open Clipboard Image** (<kbd>⇧ ⌘ V</kbd>) to create a reference from the clipboard.
- Start typing in an empty window to use it as a note.

Right-click a window to access the most relevant actions for its current content.

## Useful Keyboard Shortcuts

| Action | Shortcut |
| --- | --- |
| New foofoil window | <kbd>⌘ N</kbd> |
| Open a file | <kbd>⌘ O</kbd> |
| Open a URL | <kbd>⌘ L</kbd> |
| Open clipboard image | <kbd>⇧ ⌘ V</kbd> |
| Search history and files | <kbd>⌘ P</kbd> |
| Toggle always on top | <kbd>⌘ T</kbd> |
| Toggle border | <kbd>⌘ B</kbd> |
| Zoom content in/out | <kbd>⌘ +</kbd> / <kbd>⌘ −</kbd> |
| Zoom window in/out | <kbd>⇧ ⌘ +</kbd> / <kbd>⇧ ⌘ −</kbd> |
| Open Settings | <kbd>⌘ ,</kbd> |
| Reset content size | <kbd>⌘ 0</kbd> |
| Reset the current window | <kbd>⌘ K</kbd> |
| Close the current window | <kbd>⌘ W</kbd> |
| Increase/decrease opacity | <kbd>⇧ ⌘ ↑</kbd> / <kbd>⇧ ⌘ ↓</kbd> |

These are the default shortcuts and can be customized in Settings. Additional content-specific and window-position shortcuts are available from the macOS menu bar.

## Open from Finder with a Keyboard Shortcut

Move foofoil to Applications and launch it once. Select files or folders in Finder, then choose **Finder → Services → Open in foofoil** to open them in new foils. Multiple selections are supported; folders use the same scanning and grouping behavior as drag and drop.

In **System Settings → Keyboard → Keyboard Shortcuts → Services**, enable **Open in foofoil** and assign a shortcut that Finder does not already use. Select items and press that shortcut to open them. If the service does not appear after installation, log out of macOS and log back in, then check again.

## Requirements

- macOS 26.5 or later, matching the current project deployment target
- Xcode with support for the configured macOS SDK

## Build from Source

Use the following sibling checkout layout for the complete development environment. `extension-kit` is a required local Swift package; `hifi` and `ebook` provide the audio and EPUB capabilities delivered with the app.

```text
workspace/
├── foofoil/        # App, windows, content presentation, and search
├── extension-kit/  # Internal module contracts and tests
├── hifi/           # Hi-Fi audio implementation
└── ebook/          # EPUB parsing and reading
```

From the `foofoil` repository, the recommended way to run is:

```sh
./run
```

The script builds the Debug app, builds and embeds the sibling Hi-Fi and EPUB modules, then restarts foofoil. If a module's `build-plugin` script is missing, that module is skipped and its content capabilities are unavailable.

1. Open `foofoil.xcworkspace` in Xcode to edit the app and sibling modules together.
2. Select the `foofoil` scheme and the **My Mac** destination.
3. Configure a development signing team if Xcode requests one.
4. Use `./run` to verify the complete content experience; Xcode ⌘R does not build and embed the sibling modules.

To build only the app target (without embedding sibling modules):

```sh
xcodebuild build \
  -project foofoil.xcodeproj \
  -scheme foofoil \
  -configuration Debug \
  -destination 'platform=macOS'
```

To run the test suite:

```sh
xcodebuild test \
  -project foofoil.xcodeproj \
  -scheme foofoil \
  -destination 'platform=macOS'
```

## Development Modules and Distribution

Extensions/plugins are only a development mechanism for separating, integrating, and testing capabilities. The final product has no extension concept: Hi-Fi and EPUB are foofoil content capabilities, with no separate plugin installation, activation, or updates for users.

The source still contains internal names such as `ExtensionSupport`, the C ABI, manifests, and `.foofoilextension`, and the retained management implementation. A single internal product policy hides management UI, disables startup update checks, and suppresses installation prompts; loading and management code remain available for future reuse. See the [development guide](docs/extension-support.zh-CN.md) (Chinese) for ownership and the scope of historical plans.

`./package-dmg` builds the Release app, embeds both Hi-Fi and EPUB modules, and creates a DMG. Complete packaging requires all four repositories above. Use `./package-dmg --no-sign` for a local validation package; `./package-dmg --sign` requires Developer ID signing and notarytool credentials (documented in the script header).

## Technology

foofoil is implemented primarily with SwiftUI and uses AppKit for native floating-window, menu, text-control, and visual-effect behavior. Its content and search features use Apple frameworks including WebKit, PDFKit, Vision, AVFoundation, CoreAudio, ImageIO, Uniform Type Identifiers, and SQLite3. Markdown rendering uses the existing vendored cmark library.

History and cached content are stored locally in the user's Application Support directory. OCR and indexing run on the device; loading web pages and their remote resources requires network access.

## Development Principles

- Keep the app lightweight and responsive.
- Prefer macOS system frameworks and established project components.
- Avoid heavyweight or unnecessary third-party dependencies.
- Preserve native macOS behavior, accessibility, and localization.
- Preserve current-version window restoration and session rebuilding, and protect user-owned files; unreleased development data has no cross-version compatibility promise.

See [AGENTS.md](AGENTS.md) for the full contribution and implementation guidelines.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change.

## License

foofoil is licensed under the [MIT License](LICENSE), copyright © 2026 Beijing Memory Vision Technology Co., Ltd.

The bundled cmark library is distributed under its own permissive licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the required notices.
