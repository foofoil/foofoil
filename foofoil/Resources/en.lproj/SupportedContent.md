# Supported Content

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
| Text and code | {{textExtensions}}, etc. | Read text and adjust fonts, colors, and spacing |
| Web pages and archives | .html, .htm, .xhtml, .webarchive | Browse web content; you can also enter a URL directly |
| Books | .epub | Read by chapter and resume where you left off; encrypted books are not supported |

## Audio and Video

| Type | Common formats | Notes |
| --- | --- | --- |
| Audio | MP3, M4A, AAC, WAV, AIFF, FLAC, etc. | Play music and recordings |
| Video | MP4, MOV, M4V, etc. | Watch videos; some files may not play because of how they were encoded |
| Hi-Fi audio | DSF, DFF, APE | DSF and DFF require a DoP-capable audio device; DST-compressed DFF is not supported |
| SACD images | .iso | Play uncompressed stereo tracks |
| Track lists | .cue | Play an album by track; keep the accompanying audio files |

## Other Documents

Preview Word, Excel, PowerPoint, rich text, and other documents with macOS Quick Look.

Choose File → Open Directory…{{openDirectoryShortcut}} to open a folder with the same handling as dragging it into a foil. You can also drag in several files to browse them as a list.

## Apple Music Library

Choose File → Open Apple Music Library to authorize music access and browse albums, songs, and playlists. Click an album or song to open it directly in a music foil. Library window searches are limited to the selected category: albums, songs, or playlists. Quick Open and the overview’s `/` search search your library after authorization. Apple Music search can be enabled or disabled in Settings → General → Search. Playback requires account eligibility and uses MusicKit; the top-right device menu switches the system output device and lets you choose a supported device sample rate. These settings affect other audio using the system output or that device; they do not select the Apple Music source quality. Audio quality switching is not offered. Opened music is saved to history with a locally cached cover thumbnail and restored on restart. Music foils open borderless by default; the View menu, context menu, and border shortcut toggle borders, and history preserves your choice. Search results show user files first, then music grouped by albums, songs, and playlists. In the overview search, albums and songs initially show six results each; More Albums or More Songs adds 18 results at a time. The entire search view shows at most 60 results. In the overview search, use All, User Files, Albums, or Songs to narrow the source; a notice appears when additional matches are known to exist.

Apple Music uses the same audio playback bar and side navigation list. The list supports track selection, previous/next item commands, and search when it contains more than 12 items. The playback mode button cycles through sequential, repeat queue, shuffle, and repeat one.

All audio and video foils share one playback slot. Starting another foil pauses the previous output and waits for any exclusive device lease to be released.

Only the current playback quality reported by MusicKit is shown. The quality badge is hidden when that information is unavailable; supported formats are not displayed. Numeric source sample rate, bit depth, and bitrate are not exposed and are not inferred from quality labels.

Quick Open shows all sources without category tabs. Each group initially shows 12 results; More adds 18 at a time, up to 60 results across the view. The overview search retains its category filters and initial limits.

Paste an Apple Music song, album, or public playlist sharing link into Quick Open to preview it and press Return to open a music foil. Open Clipboard Content also opens these links directly as music. Explicit links work when Apple Music library search is disabled; music access authorization and content availability in your region still apply. Shared content does not need to be added to your library and can be restored from history.

Share menus in compatible macOS apps can open URLs, text, images, documents, audio, video, and folders in foofoil. Multiple attachments are passed together to the existing opening flow; temporary exported content is saved locally for history restoration. Apple Music links open music foils. The source app controls which content is supplied and macOS controls which share extensions are shown; enable foofoil in the system sharing extension settings if needed. The share extension accepts up to 100 attachments per invocation.

You can open the system sharing settings directly from Settings > General > Share Menu and enable foofoil.

The Share menu filters attachments with a known content type. Apps that supply only a generic file URL may still show foofoil. A mixed selection containing a known unsupported type hides the entry; ISO disc images remain available for SACD content.

Files that cannot be opened from drag and drop, the clipboard, or sharing appear in a separate bordered feedback foil with their system icons, filenames, and reason. Existing foils are preserved, even if blank. Feedback foils are excluded from history and restart restoration; failures from the same batch are collected together. Known Quick Look documents retain their preview; unknown formats are previewed only when the system can generate a content thumbnail.

Apple Music Library is disabled by default. Enable it in Settings → Types → Audio and Video to reveal its library entry, search options, and sharing guidance. Turning it off hides music history and search results without deleting saved history; Apple Music links open as ordinary web pages.
