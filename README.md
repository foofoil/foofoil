# foofoil 浮箔

**Anything, right where you need it.**  
**给你的桌面降维。**

[简体中文](README.zh-CN.md)

foofoil is a lightweight floating workspace for macOS. Keep documents, images, web pages, audio, video, and terminals in independent, minimal windows called **foils**. Open, search, pin, and switch between them to keep what you need close at hand.

The name **foofoil** combines *foo* — the familiar placeholder for anything or arbitrary content — with *foil*, a thin sheet that carries whatever you put on it. It reflects a simple idea: whatever the content is, keep it lightweight and right where you need it.

Built with SwiftUI and AppKit, foofoil favors native macOS capabilities and light, natural interaction. The interface supports English and Simplified Chinese.

## One Place to Open and Search

Type in an empty foil, or press **⌘P** for Quick Open. Find history, local files, and directories; enter a web address or an existing file path; then press Return to open. Type `/` to choose an entry point such as clipboard, history, files, directories, URLs, terminals, or the camera. With Apple Music enabled, you can also search library albums, playlists, and songs.

- **Open the clipboard.** ⇧⌘V turns copied files, folders, images, URLs, or text into foils, recognizing Markdown and HTML automatically. An ordinary empty foil is reused when available.
- **Find something you have seen.** Search history by title and indexed content, including on-device OCR of images and text extracted from PDFs and web pages. Favorite useful items to keep them when clearing history.
- **Use familiar macOS workflows.** Drag in files, directories, or text; send multiple Finder selections through Services; or open content from the system Share menu in supported apps.

Local file search uses Spotlight and is enabled by default. Clipboard search offers the current clipboard, and can search clipboard history saved by system Spotlight after Full Disk Access is granted.

## Overview: Your Way Back to Content

**Press ⌃⇧Esc from any app to open Foil Overview (Exposé).** It brings open foils, history, and search together so you can find content, switch tasks, and return to your work.

- **Find the foils you are using.** See open content in one place, switch to a foil, or reveal a hidden window. Hide foils when you need room on the desktop, then find them again in Overview.
- **Reopen history and favorites.** Find something you viewed earlier, or press ⇧⌘D to filter favorites and keep useful references close at hand.
- **Search and open directly.** Search history and local files, enter a URL or an existing file path, or press ⇧⌘V to open clipboard content without leaving Overview.
- **Stay on the keyboard.** Select with arrow keys, open with Return, or choose directly with Control + an item label. Type to search as soon as Overview opens; `/` chooses a search scope. Esc cancels scope selection, or otherwise dismisses Overview.

Quick Open helps you find a particular item. Overview also shows the foils already in your workspace, making it the main place to switch between content and pick up where you left off.

## Put Every Foil Where You Need It

Pin each foil independently, adjust its opacity, and toggle borders where supported. Keep a reference image beside a design, a document next to your code, or a small player in the corner of your desktop.

| Control | What it does |
| --- | --- |
| ⌘ + drag | Move the whole foil, including a terminal, without finding a title bar |
| Three-finger trackpad drag | Move a foil with the pointer over its content or sidebar |
| ⌘ + scroll, two-finger pinch | Zoom images or content, or resize the window, depending on content type |
| ⇧⌘+ / ⇧⌘− | Enlarge or shrink the window |
| ⌃⌥ + Q W E / A S D / Z X C | Position the foil in a 3×3 screen grid matching three keyboard rows |
| ⌃⌥Tab | Move the foil to the next display |
| ⌘H / ⇧⌘H | Hide the current foil / all foils to make room temporarily |

Window movement and resizing gestures mainly apply outside full screen; zoom behavior depends on content type and border state. Use ⌘ + scroll over a visible sidebar to adjust its width. If three-finger gestures conflict with macOS, assign Mission Control and desktop switching to four fingers and turn off the system Three Finger Drag option.

Hiding keeps content open, audio playing, and terminal tasks running. Window layouts and content state can be restored after relaunch; terminals follow the restoration rules below.

### Shortcuts First

Shortcuts cover opening, searching, switching, positioning, reading, and playback. Select a foil in Overview, then adjust its position, size, or playback state while keeping your hands on the keyboard.

These are selected defaults. Except for global Overview, use them while foofoil is active; some actions depend on content type.

| Action | Default shortcut |
| --- | --- |
| Quick Open | ⌘P |
| Foil Overview (global) | ⌃⇧Esc |
| Open clipboard / open clipboard incognito | ⇧⌘V / ⌥⌘V |
| New incognito foil / toggle current foil’s incognito mode | ⇧⌘N / ⌥Esc |
| Toggle always on top / border (supported content) | ⌘T / ⌘B |
| Increase / decrease opacity | ⇧⌘↑ / ⇧⌘↓ |
| Zoom content in / out; actual size | ⌘+ / ⌘−; ⌘0 |
| Fit window to image / image to window width (visible border required) | ⌘[ / ⌘] |
| Find in current content / next, previous match | ⌘F / ⌘G, ⇧⌘G |
| Previous / next EPUB chapter | ← / → |
| Play / pause; seek backward / forward (audio and video) | Space; ← / → |
| Document or subtitle style (supported content) | ⌘I |
| Reload a local file or web page | ⌘R |
| Favorite current foil | ⌘D |
| Extract image text (raster images) | ⌘E |
| Save content image / Save As | ⌘S / ⇧⌘S |
| Reset to blank foil | ⇧⌘K |

In **Settings → Keyboard Shortcuts**, search commands by name, scope, or key combination, change bindings, or restore defaults. Menus show the current bindings. Global clipboard commands have no defaults; assign them if needed. Configurable opening shortcuts automatically gain an incognito variant with Option, so their ordinary bindings cannot include Option; ⌥⌘V is reserved for incognito clipboard opening. Standard menu commands such as New and Hide are outside this configuration list.

For the complete guide, use Keyboard Shortcuts in the Help menu or read the [shortcut documentation](foofoil/Resources/en.lproj/KeyboardShortcuts.md). The in-app guide includes your current bindings.

## Music and Video, in a Foil

From an album cover in a desktop corner to a subtitled video beside your work, foofoil brings useful playback features into the same window controls. Audio and video share playback controls and navigation conventions; starting another foil pauses the previous output.

### Hi-Fi: Lossless Albums, DSD, and SACD

Alongside common formats such as MP3, AAC, ALAC, FLAC, WAV, and AIFF, foofoil brings **DSF, DFF, SACD ISO, and APE/CUE** into one native macOS playback experience:

- **DSD over DoP.** Send DSF and raw DFF to a compatible DAC through DoP, with DSD64, DSD128, and DSD256 verified.
- **Play SACD ISO directly.** Browse tracks, switch songs, and seek within the uncompressed stereo area without first converting the image to DSF.
- **APE and CUE tracks.** Decode Monkey’s Audio and navigate album tracks through CUE sheets. APE uses exclusive PCM output through CoreAudio.
- **Automatic sample-rate matching.** During exclusive PCM playback, the output device automatically switches to the source sample rate, without manual adjustments between tracks. The device must support that rate.
- **Choose an output device.** Select audio hardware from the player, with coordinated device release when switching exclusive playback. Format handling, track lists, and output controls stay together in the foil.

DSD requires a DoP-capable output device; there is no DSD-to-PCM fallback. DST compression and SACD multichannel are not supported yet. Keep CUE sheets with their companion audio files. Available sample rates depend on the source and hardware.

### Everyday Video and Apple Music

Play MP4, MOV, and M4V, plus MKV and AVI through the video module shipped with the app. Support includes H.264, HEVC, and Xvid video, common audio tracks such as DTS and TrueHD, and track and subtitle selection. Compatibility depends on the container, codec, and their combination.

Load external SRT, ASS/SSA, and WebVTT subtitles through automatic filename matching, manual selection, or drag and drop. Subtitle file associations are saved in history. Customize text subtitle fonts, size, colors, background, shadow, position, and delay; PGS subtitles retain their graphic appearance with position and delay adjustments. Use ⌘S to save a video frame, optionally including subtitles.

Apple Music supports library browsing and search, and opens shared song, album, and public playlist links as music foils without requiring them to be added to your library first. It is off by default; enable it in **Settings → Types → Audio & Video**. Access requires authorization; playback depends on account eligibility and regional availability.

## CLI and Agent Collaboration

The bundled native **`foil` CLI** lets scripts and agents put references directly on your desktop: show a Markdown plan, an image, or an SVG diagram, then explicitly update it while preserving window layout and keyboard focus. Use incognito mode for temporary references.

With foofoil installed in Applications, install the CLI:

```sh
/Applications/foofoil.app/Contents/MacOS/foil install
~/.local/bin/foil --version
```

After adding `~/.local/bin` to PATH:

```sh
# Create read-only presentations for an agent
foil show ./plan.md --title 'Work plan' --caller 'My Agent' --json
foil show ./diagram.svg --incognito --json

# Present temporary Markdown from a pipeline
printf '# Progress\nChecking the implementation.\n' | foil open --stdin --type markdown

# List all foils, or create an interactive terminal
foil list --scope all --json
foil terminal create --title Dev --cwd ~/project --command 'git status'
```

Use the `board_id` returned by `show` with `foil update BOARD_ID ./plan.md` and subsequent close operations. `show` / `update` operate on the current agent’s owned read-only presentations, supporting local UTF-8 text, code, Markdown, raster images, and SVG. Markdown does not load linked images. Keep source files available and explicitly update after changing them. General `open`, `reveal`, `hide`, `inspect`, `set`, and `terminal create` commands handle ordinary opening, window control, and terminal creation; listing or closing general windows requires explicit `--scope all`.

The [bundled Skill](skills/foofoil/SKILL.md) can be supplied to agents that support its format. See the [Agent presentation and CLI guide](docs/agent-terminal-usage.en.md) for installation, scope, and error handling, and [Terminal Foils and General Control](docs/terminal-foil-usage.zh-CN.md) (Chinese) for general commands. Developer ID, notarization, and CLI distribution checks on a clean machine remain pending.

### Interactive Terminal Foils

Choose **File → Open Terminal…** to create an interactive zsh / bash terminal with a working directory, environment variables, and a trusted startup script. Run SSH, Vim, or other terminal programs with the same pinning, opacity, positioning shortcuts, and document style controls as other foils.

Hiding keeps tasks running; closing active tasks requires confirmation. Reopening from history creates a new session and executes its saved optional script. Automatic app restoration waits for user startup and does not execute scripts. Ordinary terminals retain up to 500 lines / 128 KiB of read-only previous output; incognito terminals do not persist these records. See the [usage guide](docs/terminal-foil-usage.zh-CN.md) (Chinese) for details.

## Read, Preview, and Save

| Content | Main capabilities |
| --- | --- |
| Images and SVG | Zoom and fit; extract text or subjects from raster images, adjust SVG colors |
| Text, code, and Markdown | Read-only viewing, offline syntax highlighting, code line numbers, Markdown heading navigation, custom fonts and reading styles |
| PDF and EPUB | Pages, chapters or contents navigation, reading-position restore; EPUB supports whole-book search, without DRM support |
| CSV | Browse data in rows and columns |
| Web pages, HTML, and web archives | WebKit browsing, content search, web archive saving |
| Office and other documents | Selectable read-only previews or system Quick Look, depending on format and system capabilities |
| Directories and archives | File trees, nested archives, previews of contained files, export of selected files or directories |
| Camera | Live view and snapshots |

Browse ZIP, TAR and common compressed variants, 7z, RAR, comic archives, APK, JAR, KRA, and ISO 9660 images as file trees. Inner archives load when expanded; contained files are previewed read-only without automatically extracting related resources. Office ZIP containers and EPUB retain their normal previews and offer Open Package Contents. Encrypted 7z/RAR, split ZIP, and some algorithm combinations are unsupported. See the [archive verification report](docs/archive-preview-verification.zh-CN.md) (Chinese) for tested formats and limits.

**⌘S saves an image of the visible content**, using HEIC by default with PNG and JPG choices. Documents save their content viewport; audio saves available cover artwork. **⇧⌘S saves the source file or complete text**; web pages save as `.webarchive`, and Markdown can export to HTML. Camera, CUE, SACD ISO, and Apple Music do not offer Save As. In terminals, this command exports retained output instead.

For complete format coverage and limitations, use **Help → Supported Content** or read the [content guide](foofoil/Resources/en.lproj/SupportedContent.md).

## Quick Start

1. Launch foofoil and type a keyword, URL, or file path in an empty foil. You can also use ⌘O for files, ⇧⌘O for directories, or drag content in.
2. Copy some text or an image, then press ⇧⌘V. Right-click for actions relevant to the current content.
3. Press ⌘T to pin the foil, move it with ⌘ + drag, or position it with the ⌃⌥ grid shortcuts.
4. Press ⌃⇧Esc to open Overview and switch between foils, history, and search results.

To open from Finder, move foofoil to Applications and launch it once. Select files or folders, then choose **Finder → Services → Open in foofoil**. Enable it and assign a shortcut in **System Settings → Keyboard → Keyboard Shortcuts → Services**. If it has not appeared, log out of macOS and back in, then check again. Use **Settings → General → Share Menu** to open system settings and enable the Share entry.

## History, Files, and Incognito Mode

History, favorites, managed content, and caches are stored locally. OCR and content indexing run on the device. Web pages, remote resources, and Apple Music require network access.

Local files are referenced directly, with bookmarks tracking renames and moves where possible. History does not back up their contents, and deleting history never deletes originals. Clipboard text, Markdown, HTML, and image data are saved automatically for history restoration. Copied files still reference originals; URLs and image addresses open as URLs without automatic downloading. Temporary attachments received through Share are saved locally for restoration.

Automatic cleanup of history for missing files is enabled by default. It removes only unfavorited records whose sources are confirmed missing; offline volumes, authorization issues, and temporary failures are retained. Managed content is excluded from ordinary cache eviction. Deleting its history leaves open windows usable, and the content is removed after its last user releases it.

**Incognito foils stay out of foofoil history and are not restored after quitting.** Create one, toggle a foil’s mode, or use incognito opening shortcuts and Share entries. Incognito mode does not prevent web downloads from being saved to disk or change the shell’s own command-history settings.

## Build from Source

### Requirements

- macOS 26.5 or later.
- Xcode supporting the configured macOS SDK for source builds.

Use this sibling checkout layout for the complete development environment:

```text
workspace/
├── foofoil/        # App, windows, content presentation, search, and CLI
├── extension-kit/  # Required internal contracts Swift package
├── hifi/           # Hi-Fi audio
├── ebook/          # EPUB parsing and reading
└── video/          # Enhanced video playback
```

From the `foofoil` repository, run:

```sh
./run
```

The script builds the Debug app, builds and embeds Hi-Fi, EPUB, and video modules, then restarts foofoil. A module is skipped if its `build-plugin` script is missing, leaving its capabilities unavailable. Video is included by default; use `./run --without-video` to omit it.

With video included, the first build requires internet access to download a pinned FFmpeg source release (about 11 MB) from `ffmpeg.org`, verify its SHA-256 checksum, and compile it locally. No manual FFmpeg installation is needed. Downloads and build products are cached in `video/.build/` for subsequent builds; corrupt download caches are automatically downloaded again. The first run or packaging build may therefore take longer. If a download fails, retry the same command.

For editing across modules in Xcode, open `foofoil.xcworkspace`, select the `foofoil` scheme and **My Mac**, and configure a development signing team if requested. Xcode ⌘R does not build and embed sibling modules; use `./run` to verify the complete content experience.

To build only the app target:

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

### Modules and Packaging

Hi-Fi, EPUB, and video ship with the app. Users do not install, enable, or update plugins. Extensions/plugins in the source are an internal development mechanism; see the [module guide](docs/extension-support.zh-CN.md) (Chinese) for the ABI, manifests, and retained management implementation.

`./package-dmg` builds the Release app, embeds these modules, and creates a DMG. Complete default packaging requires all five repositories above. Use `--without-video` to omit video, `--no-sign` for a local validation package, or `--sign` for Developer ID signing and notarization with the required credentials. After packaging, an interactive terminal offers to install the app into `/Applications`. See the script header for setup.

## Lightweight by Design, Open to Contributions

foofoil favors system capabilities including SwiftUI, AppKit, WebKit, PDFKit, Vision, AVFoundation, CoreAudio, ImageIO, and SQLite3. Lightweight is an ongoing implementation principle: keep dependencies focused, reuse native capabilities, and avoid carrying infrastructure the system already provides. Markdown uses cmark, source highlighting uses offline highlight.js, and interactive terminals use SwiftTerm. See [third-party notices](THIRD_PARTY_NOTICES.md) for dependencies and licenses.

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md), keep changes focused, and preserve responsiveness, native interaction, accessibility, localization, and user file safety.

## License

foofoil source code is licensed under the [MIT License](LICENSE), copyright © 2026 Beijing Memory Vision Technology Co., Ltd. Bundled third-party components retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
