# Keyboard Shortcuts Overview

Customize bindings in Settings → Keyboard Shortcuts. Except for global shortcuts, foofoil must be active; some actions apply only to specific content.

⌘ Command · ⇧ Shift · ⌥ Option · ⌃ Control · Esc Escape · Space · Tab


Incognito foils never enter history and are not restored after quitting. Use File → New Incognito Foil or Open Clipboard Incognito; the system Share menu also offers Incognito Foil. Content dropped into an incognito foil stays out of history, including any additional foils created for separate file groups.
Ordinary opening actions only reuse ordinary blank foils; incognito opening creates a new foil. While an incognito foil is active, Open Clipboard Content also opens an incognito foil. An empty incognito foil shows a footprints-with-slash icon and offers no history cards or recent-history number shortcuts.

## Global Shortcuts

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{global}}


<!-- Quick Open belongs to content opening and management. -->

## Open and Manage Content

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
| New foil | ⌘N | ⌘N |  |
| Open file | ⌘O | ⌘O |  |
| Save Content Image | ⌘S | ⌘S | Save the visible content as HEIC by default, with PNG and JPG choices; audio saves the cover image when available |
| Save As | ⇧⌘S | ⇧⌘S | Save the source file or complete text; websites save a web archive. Unavailable for camera, CUE, SACD ISO, and Apple Music |
{{file}}

In the Apple Music library window, Esc closes the window, including while the search field is focused. Drag the blank area of the sidebar to move the window.

Open directories with File → Open Directory. The configurable shortcut is listed in this section; directories use the same handling as dragging them into a foil.

Quick Open and the overview’s `/` search also search songs, albums, and playlists in your Apple Music library. Enable or disable Apple Music search in Settings → General → Search; music access authorization is required. Select a result and press Return to play it in a foil. Search results show user files first, then Apple Music groups for albums, playlists, and songs. In the overview search, user files and each Apple Music group initially show 18 results; More Files, More Albums, More Playlists, or More Songs adds 18 results at a time. Each group shows at most 60 results, with no combined limit across groups. A notice appears in the overview search when additional matches are known to exist.



## Navigation

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{go}}

EPUB chapter navigation follows reading order and skips subsections. Use Go → Previous Chapter / Next Chapter; customize these bindings in Settings → Keyboard Shortcuts → Navigation. Chapter navigation stops at the first and last chapters.


Apple Music queues also use the common list navigation shortcuts and list search. Apple Music foils support the common border toggle shortcut. In an audio foil, ⌘C (Edit → Copy Cover, or the context menu) copies the current cover image; it is disabled when the foil has no cover. Video foils keep their existing behavior.


When the sidebar has keyboard focus, ↑ / ↓ navigate visible rows and open the selected file; ← collapses a directory or moves to its parent. → and Return both expand a directory, or enter its first child when already expanded; Return on a file opens it. This applies to archive trees and other navigation sidebars, in both windowed and full-screen foils. Selection uses the accent color while focused and gray when focus moves to the content or another window. Search fields keep their normal text-editing keys.

Navigation lists also support ⌃P / ⌃B for the previous item and ⌃N / ⌃F for the next. When the content has focus, ↑ / ↓ scroll read-only text, Markdown preview, and EPUB; use ← / →, ⌃P / ⌃N, or a custom item shortcut to move between list items.


## Content Display

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{view}}

| Mouse / trackpad gesture | Effect |
| --- | --- |
| ⌘ + mouse wheel | Zoom images; resize the window for web pages, text, Markdown, and similar content |
| Two-finger pinch | Zoom images; resize the window for web pages, text, Markdown, audio, and video |
| Drag a full-screen image | Pan the image when it extends beyond the viewport |

Unless noted, these behaviors apply outside full screen. Borderless PDFs resize the window; bordered PDFs use native content zoom. Full-screen images initially fit the screen and support content zoom with shortcuts, ⌘ + scroll, and pinch. Full-screen and bordered images zoom around the pointer; images smaller than the viewport are centered. Quick Look documents support window resizing outside full screen. Over a visible, unobscured navigator, ⌘ + scroll adjusts the panel width.


## Image Tools

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{image}}


## Web Tools

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{web}}


## Playback

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{playback}}


## Window

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
| Hide current foil | ⌘H | ⌘H | Restore from overview |
| Hide all foils | ⇧⌘H | ⇧⌘H | Switch back to restore |
| Close current window | ⌘W | ⌘W | May prompt to close or hide playing audio |
{{window}}

Default window positioning keys (see the table for custom bindings): Control–Option + Q/W/E selects the top row, A/S/D the middle, and Z/X/C the bottom. These default keys form the leftmost 3×3 grid in the keyboard’s letter area.

## History

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{history}}


## System and Editing

| Action | Shortcut |
| --- | --- |
| Settings | ⌘, |
| Quit | ⌘Q |
| Hide other apps | ⌥⌘H |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| Select all | ⌘A |
| Close Foil Information | Esc |

Editing shortcuts apply to text fields or selectable content, depending on focus and content type. Hiding keeps foils open and audio playing.

## Inside Foil Overview

- Arrow keys select; Return activates the selected foil. Numbers or letters select visible items directly.
- `/` starts search; while searching, Control + number or letter selects directly.
- Esc leaves search; press Esc again to dismiss the overview.
- {{clipboardShortcut}} opens clipboard content.

Paste an Apple Music song, album, or public playlist sharing link into Quick Open to preview it and press Return to open a music foil. Open Clipboard Content also opens these links directly as music. Explicit links work when Apple Music library search is disabled; music access authorization and content availability in your region still apply. Shared content does not need to be added to your library and can be restored from history.

Quick Open shows all sources without category tabs, initially 12 results per group; More adds 18 at a time within the shared 60-result limit.

Apple Music shortcuts and link handling require Enable Apple Music Library in Settings → Types → Audio and Video, which is off by default. When disabled, Quick Open and Open Clipboard Content treat Apple Music sharing links as ordinary websites.

The configurable Document / Subtitle Style command opens subtitle settings for videos and document settings for documents. Subtitle styles and timing are global.

Subtitle and document styles can be saved as custom themes. Choose an existing theme in Save as Theme to overwrite it, or right-click a custom theme to overwrite or delete it. Subtitle themes save all settings; document themes save colors, fonts, size, and spacing.

In archive foils, Save As exports the selected file, directory, or root. The archive navigator uses Up/Down to select, Left to collapse or select the parent, Right to expand or select the first child, and Return/Space to open the selection. When focus is in the content, EPUB chapter and PDF page commands target the preview. Navigator search expands all ancestors of a match. Right also lazily loads unopened nested archives in the same tree; Left cancels unfinished loads when collapsing. Search does not scan unopened archives.
