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
- Use ⇧⌘V to open clipboard files, folders, images, URLs, or text, with automatic Markdown and HTML recognition.
- Use the global ⌃⇧Esc shortcut to open Foil Overview (Exposé), view your open foils, and switch between them.
- Preview other local documents with embedded macOS Quick Look, including Office and rich text files; available previews depend on the system and installed Quick Look providers.
- Preview Markdown, browse CSV data as a table, and navigate PDF pages.
- Zoom images and web content, fit images to a window, and customize SVG colors or the document look: background, text color, font, line spacing and paragraph spacing for plain text, Markdown and EPUB foils, following light/dark appearance changes.
- Save, copy, share, or capture displayed content using native macOS workflows.
- Restore window state and keep a local content history.
- Search history by title and content, including on-device OCR for images and extracted text from PDFs and web pages.
- Use ⌘P for Quick Open: find and open history content or local files from authorized folders, or enter a URL.
- Customize keyboard shortcuts in Settings and use English or Simplified Chinese throughout the interface.

Hi-Fi currently supports DSF, raw DFF, uncompressed stereo SACD ISO, and APE/CUE. DSD playback requires a DoP-capable output device, with no DSD-to-PCM fallback; DST and SACD multichannel are not supported yet. EPUB supports table-of-contents navigation and reading-position restore; DRM-protected books are unsupported.

## Lightweight by Design

foofoil keeps its footprint small by using macOS system frameworks wherever they already provide the capability well, rather than bundling another browser engine, language runtime, or large general-purpose media stack. Lightweight is an implementation principle: keep dependencies focused, reuse native capabilities, and avoid carrying infrastructure the system already provides.

## Quick Start

Launch foofoil and then use any of these methods:

- Drag a supported file, image, or text onto a foofoil window.
- Choose **File > Open** (<kbd>⌘ O</kbd>) to open a local file.
- Choose **File > Open URL** (<kbd>⌘ L</kbd>) to display a web page.
- Choose **File > Open Clipboard Content** (<kbd>⇧ ⌘ V</kbd>) to open copied files, folders, images, URLs, or text as foils; an empty foil is reused when available, otherwise a new window is created.
- Start typing in an empty window to use it as a note.

Right-click a window to access the most relevant actions for its current content.

## Useful Keyboard Shortcuts

These default shortcuts cover distinctive features and everyday actions. Except for the global overview shortcut, use them while foofoil is active; some actions depend on the current content type.

| Action | Default shortcut |
| --- | --- |
| Foil Overview (Exposé, global) | <kbd>⌃ ⇧ Esc</kbd> |
| Open clipboard content | <kbd>⇧ ⌘ V</kbd> |
| Quick Open | <kbd>⌘ P</kbd> |
| Hide the active foil | <kbd>⌘ H</kbd> |
| Hide all foils to clear your workspace temporarily | <kbd>⇧ ⌘ H</kbd> |
| Extract image text (raster images) | <kbd>⌘ E</kbd> |
| Always show navigator (foils with a navigator) | <kbd>⇧ ⌘ L</kbd> |
| Toggle always on top | <kbd>⌘ T</kbd> |
| Toggle border (images and web pages outside full screen) | <kbd>⌘ B</kbd> |
| Zoom content in / out | <kbd>⌘ +</kbd> / <kbd>⌘ −</kbd> |
| Actual content size | <kbd>⌘ 0</kbd> |
| Fit window to image / image to window width (visible border required) | <kbd>⌘ [</kbd> / <kbd>⌘ ]</kbd> |
| Enlarge / shrink window (outside full screen) | <kbd>⇧ ⌘ +</kbd> / <kbd>⇧ ⌘ −</kbd> |
| Increase / decrease opacity | <kbd>⇧ ⌘ ↑</kbd> / <kbd>⇧ ⌘ ↓</kbd> |
| Move foil to the next screen | <kbd>⌃ ⌥ Tab</kbd> |
| Move foil to a position in a 3×3 screen grid | <kbd>⌃ ⌥</kbd> + <kbd>Q W E / A S D / Z X C</kbd> |

The overview shortcut also works while another app is active. Within the overview, ⇧⌘V still opens clipboard content.

In the overview, use arrow keys to select a foil, Return to switch to it, `/` to search, and Esc to leave search or dismiss the overview. The positioning keys follow three keyboard rows: Q/W/E for the top, A/S/D for the middle, and Z/X/C for the bottom of the screen. ⌘H hides only the active foil; select it in the overview to show it again. ⇧⌘H hides the entire app; switch back to foofoil to restore it. Hiding keeps content open and audio playing.

Visit **Settings → Keyboard Shortcuts** for all configurable commands: search by name, scope, or key combination, change a shortcut, or restore its default. The global **Open Clipboard Content** command has no default shortcut; assign one there if needed. Standard menu shortcuts such as Hide, New, and Open File are outside this configuration list. The menu bar shows the shortcuts currently in effect.

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
