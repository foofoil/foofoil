# Supported Content

Local files are referenced directly, with bookmarks tracking renames and moves when possible. History keeps no body copy of an original file, and deleting history never deletes that original. Clipboard text, Markdown, HTML, and image data are saved automatically and can be restored from history, marked “From Clipboard,” without Save As. Copied files still reference their originals; copied URLs and image addresses open as URLs without automatic downloading.

Settings → General → Automatically remove history for missing files is on by default. Only confirmed missing sources are removed; offline volumes, authorization problems, and temporary errors are retained. Turn it off to keep unavailable entries and receive feedback when opening them. Deleting managed history leaves open windows usable; its body is removed after the last user releases it. Saved bodies are excluded from ordinary cache eviction. Incognito bodies last only for the session.

Incognito foils never enter history and are not restored after quitting. Use File → New Incognito Foil{{newIncognitoShortcut}} or Open Clipboard Incognito{{openClipboardIncognitoShortcut}}; the system Share menu also offers Incognito Foil. Content dropped into an incognito foil stays out of history, including any additional foils created for separate file groups.
Ordinary opening actions only reuse ordinary blank foils; incognito opening creates a new foil. While an incognito foil is active, Open Clipboard Content also opens an incognito foil. An empty incognito foil shows a footprints-with-slash icon and offers no history cards or recent-history number shortcuts.

## URLs, Cameras, and Clipboard Content

| Content | How to open it | What you can do |
| --- | --- | --- |
| URLs | File → Open URL…{{openURLShortcut}} | Browse a web page in a foil |
| Cameras | File → Open Camera{{openCameraShortcut}} | View a live camera feed |
| Clipboard images | Copy an image, then choose Open Clipboard Content{{openClipboardShortcut}} | Open the image in a foil |
| Clipboard text | Copy a passage, then choose Open Clipboard Content{{openClipboardShortcut}} | Read or edit text; Markdown and HTML are automatically recognized and previewed |
| Clipboard URLs, files, or folders | Copy them, then choose Open Clipboard Content{{openClipboardShortcut}} | Open the corresponding web page or local content |

You can also type directly into a blank foil to write a note.

## Images

| Type | Common formats | What you can do |
| --- | --- | --- |
| Images | PNG, JPEG, GIF, TIFF, HEIC, WebP, etc. | Zoom in, extract text, or lift a subject from an image |
| SVG images | SVG | Zoom in and adjust colors |

## Documents and Web Content

| Type | Common formats | What you can do |
| --- | --- | --- |
| PDF | .pdf | Read, turn pages, and jump to a page |
| Markdown | .md, .markdown | Read formatted content, jump to headings from the Outline in the navigator, and adjust reading styles |
| Tables | .csv | Browse data in rows and columns |
| Text and code | {{textExtensions}}, etc. | Read text and adjust fonts, colors, and spacing; recognized source code is shown with syntax highlighting |
| Web pages and archives | .html, .htm, .xhtml, .webarchive | Browse web content; you can also enter a URL directly |
| Books | .epub | Read by chapter and resume where you left off; encrypted books are not supported |

Source files with a recognized extension or file name, such as .swift, .kt, .zig, .toml, Dockerfile, or Makefile, are highlighted offline. Highlighting is read-only: copying returns only the source text, and View → Show Line Numbers toggles line numbers for the current foil. Code larger than 512 KB, and files whose language is not recognized, are shown as plain text. Markdown, HTML, and SVG keep their own display.

## Audio and Video

| Type | Common formats | Notes |
| --- | --- | --- |
| Audio | MP3, M4A, AAC, WAV, AIFF, FLAC, etc. | Play music and recordings |
| Video | MP4, MOV, M4V; MKV and AVI in builds with additional video support | MKV/AVI support includes H.264, HEVC and Xvid video, common audio tracks including DTS and TrueHD, and audio/subtitle selection. Text subtitles use globally configurable styles; PGS uses bitmap subtitles. |
| Fragmented MP4 segments | .m4s | Opened as audio or video according to the track in the file's initialization data; segments without it (such as those lacking the moov box) cannot be played |
| Hi-Fi audio | DSF, DFF, APE | DSF and DFF require a DoP-capable audio device; DST-compressed DFF is not supported |
| SACD images | .iso | Play uncompressed stereo tracks |
| Track lists | .cue | Play an album by track; keep the accompanying audio files |

Audio foils show the embedded or same-folder cover as a background. Copy Cover (⌘C, also in the Edit menu and context menu) copies the cover currently shown; it is unavailable when no cover is shown. Video foils do not offer it.

## Other Documents

Preview Word, Excel, PowerPoint, rich text, and other documents with macOS Quick Look.

Choose File → Open Directory…{{openDirectoryShortcut}} to open a folder with the same handling as dragging it into a foil. You can also drag in several files to browse them as a list.

## Apple Music Library

Choose File → Open Apple Music Library to authorize music access and browse albums, songs, and playlists. Click an album or song to open it directly in a music foil. Library window searches are limited to the selected category: albums, songs, or playlists. Quick Open and the overview’s `/` search search your library after authorization. Apple Music search can be enabled or disabled in Settings → General → Search. Playback requires account eligibility and uses MusicKit; the top-right device menu switches the system output device and lets you choose a supported device sample rate. These settings affect other audio using the system output or that device; they do not select the Apple Music source quality. Audio quality switching is not offered. Opened music is saved to history with a locally cached cover thumbnail and restored on restart. Music foils open borderless by default; the View menu, context menu, and border shortcut toggle borders, and history preserves your choice. Copy Cover (⌘C, also in the Edit menu and context menu) copies the cover currently shown in the foil. Search results show user files first, then Apple Music groups for albums, playlists, and songs. In the overview search, user files and each Apple Music group initially show 18 results; More Files, More Albums, More Playlists, or More Songs adds 18 results at a time. Each group shows at most 60 results, with no combined limit across groups. A notice appears in the overview search when additional matches are known to exist.

Apple Music uses the same audio playback bar and side navigation list. The list supports track selection, previous/next item commands, and search when it contains more than 12 items. The playback mode button cycles through sequential, repeat queue, shuffle, and repeat one.

All audio and video foils share one playback slot. Starting another foil pauses the previous output and waits for any exclusive device lease to be released.

Only the current playback quality reported by MusicKit is shown. The quality badge is hidden when that information is unavailable; supported formats are not displayed. Numeric source sample rate, bit depth, and bitrate are not exposed and are not inferred from quality labels.

Quick Open shows all sources without category tabs. Each group initially shows 12 results; More adds 18 at a time, up to 60 results across the view. The overview search retains its category filters and initial limits.

Paste an Apple Music song, album, or public playlist sharing link into Quick Open to preview it and press Return to open a music foil. Open Clipboard Content also opens these links directly as music. Explicit links work when Apple Music library search is disabled; music access authorization and content availability in your region still apply. Shared content does not need to be added to your library and can be restored from history.

Share menus in compatible macOS apps can open URLs, text, images, documents, audio, video, and folders in foofoil. Multiple attachments are passed together to the existing opening flow; temporary exported content is saved locally for history restoration. Apple Music links open music foils. The source app controls which content is supplied and macOS controls which share extensions are shown; enable foofoil in the system sharing extension settings if needed. The share extension accepts up to 100 attachments per invocation.

You can open the system sharing settings directly from Settings > General > Share Menu and enable foofoil.

The Share menu filters attachments with a known content type. Apps that supply only a generic file URL may still show foofoil. A mixed selection containing a known unsupported type hides the entry; ISO disc images remain available for SACD audio and ISO 9660 file browsing.

Files that cannot be opened from drag and drop, the clipboard, or sharing appear in a separate bordered feedback foil with their system icons, filenames, and reason. Existing foils are preserved, even if blank. Feedback foils are excluded from history and restart restoration; failures from the same batch are collected together. Known Quick Look documents retain their preview; unknown formats are previewed only when the system can generate a content thumbnail.

Apple Music Library is disabled by default. Enable it in Settings → Types → Audio and Video to reveal its library entry, search options, and sharing guidance. Turning it off hides music history and search results without deleting saved history; Apple Music links open as ordinary web pages.

All video foils can load external SRT, ASS/SSA, and WebVTT subtitles using the subtitle menu, the context menu, the View menu, or drag and drop. Matching same-folder filenames are discovered automatically after folder access is available. Loaded files are saved with video history; subtitle visibility is temporary. Fonts, colors, background, shadow, bottom position and delay are global settings. ASS uses the global text style; PGS supports position and delay but keeps its bitmap appearance.

Choose Load Subtitle File from the video foil’s context menu or the system View menu to open external subtitles.

After subtitles load successfully, Show Subtitles is available in the video context menu and View menu. Subtitles are shown each time a video opens; visibility is not saved in history.

Videos support Save Content Image from the context menu or File menu (⌘S). This opens the Save Content Image dialog to save the current picture as an image (HEIC by default, with PNG and JPG choices), without playback controls; subtitles are included only when Show Subtitles is enabled at capture time. Save As (⇧⌘S) saves a copy of the current video file. Videos do not offer Extract Text or Extract Image Subject.

New videos share an initial display area of up to 720×480, preserving aspect ratio. Opening from history restores the saved window size.

Video history thumbnails use the midpoint of the video to avoid opening black or white screens. Reopening a video refreshes older thumbnails without changing its starting or restored playback position.

## Saving content

⌘S opens “Save Content Image” to save an image of the current visible content (HEIC by default, with PNG and JPG choices). Documents (including text, Markdown, PDF, EPUB, and Quick Look previews) save the visible viewport, with its current scroll position, zoom, and background, excluding window borders and navigation controls. Videos, camera, and websites retain their existing capture behavior. Audio saves the displayed cover image; unavailable when there is no cover.

⇧⌘S saves the source file, or the complete current text/Markdown source including edits. EPUB saves the original EPUB file; websites save a `.webarchive`. Camera, CUE tracks, SACD ISO, and Apple Music do not provide Save As. Both commands are disabled for blank foils.

## Archives

APK, JAR/WAR/EAR, CBZ/CBR/CB7/CBT comic archives, and KRA projects open as packages using the same archive tree and previews. Compiled resources (such as Android binary XML and DEX) are not decompiled. Comic archives show their files rather than a dedicated comic reader.

Office ZIP containers (.docx/.docm/.dotx/.dotm, .xlsx/.xlsm/.xlsb/.xltx/.xltm, .pptx/.pptm/.potx/.potm/.ppsx/.ppsm and OpenDocument formats) and EPUB keep their normal document preview. Choose File → Open Package Contents, or the corresponding context-menu command, to browse their internal files in a new foil. Preview and package browsing keep separate history records; reopening either record restores its own mode. Legacy .doc/.xls/.ppt files are not ZIP containers and do not offer this command.

Ordinary ISO 9660 images, including common Joliet/Rock Ridge extensions, can be browsed without mounting. SACD images are detected by the audio reader and retain track playback. UDF-only images and DMG are unsupported. Nested ISO files are extracted on selection to distinguish audio from file images, or on expansion; their directory is read only when expanded, and their extracted source is cached for the session.

Open ZIP/ZIP64, TAR/PAX, TGZ/TAR.GZ, TAR.BZ2, TAR.XZ, GZ/BZ2/XZ streams, 7z, and RAR/RAR5 using the file picker, drag and drop, clipboard, or Share menu. The archive tree owns the navigator; select a file to preview it. Nothing opens automatically. Text is read-only. EPUB chapter commands remain available while its table of contents is hidden. Markdown outlines are also hidden in archive foils. Nested archives expand in the same tree: only expanding a node extracts that archive and reads its directory. Loaded directories are cached for the session; collapsing a node cancels unfinished loads below it. Unopened nested archives are never scanned. Search covers only directories already loaded. History keeps only the original archive reference and a fixed icon; reopening starts with no selection.

Save As saves the selected original file, directory, or archive root. Directories include empty folders. Choose a new directory name; existing directories are never merged. Name collisions stop the save; save colliding files individually under different names. Links, special files, and executable permissions are not restored. Saving uses temporary output and commits only after completion; cancelled or failed operations leave the existing destination intact.

Verified on macOS 27.0.1 with system libarchive 3.7.4: ZIP Store/Deflate/BZip2/LZMA and traditional encryption/AES-128/AES-256; 7z LZMA/LZMA2/BZip2/PPMd; unencrypted RAR and RAR5, including tested solid archives. 7z split streams and tested RAR/RAR5 volume groups are supported; opening a volume asks for its folder. ZIP split archives and encrypted 7z/RAR are unsupported. This is a tested subset, not a promise of every algorithm or combination.

Limits: 100,000 tree nodes, 128 path components, 32 MiB of path metadata, and 8 GiB per source volume. Preview extraction and export output are capped at 20 GiB per operation. Cached nested archives share a 20 GiB budget; loaded tree nodes, path metadata, and total tree depth share the limits above. Sequential work is limited to four times the output budget, with a 512 MiB floor and 20 GiB ceiling. Scans allow 120 seconds; preview and export extraction 300 seconds, checked between native reader calls. The system reader has no configurable dictionary memory cap; large dictionary formats may use more memory than the output budget.

Files inside archives use the same file opening, themes, controls, and border options as ordinary foils, including text/source files, media, ISO, and nested archives. Only the selected file is extracted; related resources, subtitles, and covers are not extracted automatically. Formats such as CUE that need sibling files require saving the directory first. Preview content is read-only; unsupported files and extraction limits offer Save As guidance. Passwords stay in the current session and are requested again after reopening. A directory containing different passwords must be saved in separate selections; one failed entry aborts the directory save.
