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
- Favorite history records for long-term access, preserve them when clearing history, and filter them in Exposé. Toggle the current foil’s favorite status with ⌘D by default; a brief toast confirms the result. In Exposé, ⇧⌘D filters favorites; highlighted history items support Backspace to delete, ⌘E to rename, ⌘D to favorite, and ⌘I for information.
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
| Previous / next EPUB chapter | <kbd>←</kbd> / <kbd>→</kbd> |
| Foil Overview (Exposé, global) | <kbd>⌃ ⇧ Esc</kbd> |
| Open clipboard content | <kbd>⇧ ⌘ V</kbd> |
| New incognito foil | <kbd>⇧ ⌘ N</kbd> |
| Open clipboard incognito | <kbd>⌥ ⌘ V</kbd> |
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

Incognito foils stay out of history and are not restored after quitting. The system Share menu also offers Incognito Foil. An slashed-footprints badge marks incognito foils in Exposé.

The overview shortcut also works while another app is active. Within the overview, ⇧⌘V still opens clipboard content. The first 36 items have fixed labels 1–9, 0, A–Z in list order; scrolling does not renumber them. Use Control + a label for direct selection; ⌃P / ⌃N / ⌃F / ⌃B retain navigation priority.

In the overview, use arrow keys to select a foil, Return to switch to it, `/` to search, and Esc to leave search or dismiss the overview. The positioning keys follow three keyboard rows: Q/W/E for the top, A/S/D for the middle, and Z/X/C for the bottom of the screen. ⌘H hides only the active foil; select it in the overview to show it again. ⇧⌘H hides the entire app; switch back to foofoil to restore it. Hiding keeps content open and audio playing.

Visit **Settings → Keyboard Shortcuts** for all configurable commands: search by name, scope, or key combination, change a shortcut, or restore its default. The global **Open Clipboard Content** command has no default shortcut; assign one there if needed. Opening shortcuts automatically gain an incognito variant with Option; Option is reserved for this purpose. ⌥⌘V always opens clipboard content incognito. Standard menu shortcuts such as Hide and New are outside this configuration list. The menu bar shows the shortcuts currently in effect.

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

Video capabilities live in the sibling `video` repository. `./run` and `./package-dmg` include it by default; pass `--without-video` to omit it or `--with-video` to include it explicitly. No user installation or enablement is required.

Videos support external SRT, ASS/SSA and WebVTT subtitles through automatic filename matching, manual loading and drag and drop, with history restoration. The default ⌘I shortcut opens video subtitle styles; font, size, colors, background, shadow, bottom position and delay are saved globally.

⌘S opens Save Content Image to save the visible content as HEIC by default, with PNG and JPG choices; audio saves its cover when available. ⇧⌘S saves the source file or complete current text; websites save a web archive. Camera, CUE, SACD ISO, and Apple Music do not provide Save As. Both commands are disabled for blank foils. Videos keep their current frame capture behavior and also support saving a copy of the video with ⇧⌘S.

### Archive preview

Browse nested archives in one tree, loading and caching inner directories only when expanded, and preview selected files read-only using the same type detection, default themes, border options, and playback controls as ordinary foils. Related resources are not extracted automatically. Save As exports the selected original file, directory, or root. History records the original archive only. APK, JAR/WAR/EAR, comic archives, KRA, and ISO 9660 images use this view; SACD retains audio playback. Office ZIP containers and EPUB keep their original preview and offer Open Package Contents in a new foil, with separate history for each mode. Supported format subsets, encryption, volume handling, and limits are documented in the bundled Supported Content overview and [verification report](docs/archive-preview-verification.zh-CN.md). Encrypted 7z/RAR and split ZIP need another archive backend.

Local files are referenced directly, with bookmarks tracking renames and moves when possible. History keeps no body copy of an original file, and deleting history never deletes that original. Clipboard text, Markdown, HTML, and image data are saved automatically and can be restored from history, marked “From Clipboard,” without Save As. Copied files still reference their originals; copied URLs and image addresses open as URLs without automatic downloading.

Settings → General → Automatically remove history for missing files is on by default. Only unfavorited records with confirmed missing sources are removed; offline volumes, authorization problems, and temporary errors are retained. Turn it off to keep unavailable entries and receive feedback when opening them. Deleting managed history leaves open windows usable; its body is removed after the last user releases it. Saved bodies are excluded from ordinary cache eviction. Incognito bodies last only for the session.

## Agent terminal

Use the bundled native `foil` CLI to present and explicitly update local text, Markdown, images, and SVG in read-only windows. Agent updates retain layout and focus; temporary references support incognito mode. Keep source files available. See the [CLI guide](docs/agent-terminal-usage.en.md) and [bundled Skill](skills/foofoil/SKILL.md). Developer ID distribution verification remains pending.

## Interactive terminal foils

Choose File → Open Terminal… to create an interactive zsh/bash terminal with a working directory, explicit environment and trusted startup script. Hiding keeps tasks running; closing active tasks requires confirmation. Reopening history creates a new session; automatic app recovery waits for user startup. When the shell itself ends (for example Ctrl+D at the last prompt), the foil closes instead of offering to start a new session. SSH, Vim and terminal programs use the user's environment and remain subject to macOS privacy controls.

Use `foil list --scope all`, `reveal`, `hide`, `inspect`, `set` and `close --scope all` for general windows, and `foil terminal create` for terminals. Existing `show FILE`, `update` and default `list/close` retain their owned read-only Agent presentation scope.

Terminal creation and reopening a closed terminal start immediately with its saved optional environment and startup script. Revealing a running terminal keeps its session. Automatic app restoration waits for user activation. Ordinary terminals retain up to 500 lines / 128 KiB of read-only previous output; incognito terminals do not persist output.
