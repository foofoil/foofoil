# Keyboard Shortcuts Overview

In Quick Open and Exposé, the `/` list ends with Terminal and Camera. Selecting Terminal opens its configuration dialog; selecting Camera opens the camera immediately.

Customize bindings in Settings → Keyboard Shortcuts. The table below shows the default and current bindings, including automatically derived incognito opening shortcuts. Except for global shortcuts, foofoil must be active; some actions apply only to specific content.

⌘ Command · ⇧ Shift · ⌥ Option · ⌃ Control · Esc Escape · Space · Tab


Incognito foils never enter history and are not restored after quitting. Use File → New Incognito Foil or Open Clipboard Incognito; the system Share menu also offers Incognito Foil. Content dropped into an incognito foil stays out of history, including any additional foils created for separate file groups. File → Convert to Incognito Foil / Convert to Regular Foil switches the current foil in either direction; converting to incognito deletes its history, while favorited foils cannot become incognito. A toast confirms the result.
Ordinary opening actions only reuse ordinary blank foils; incognito opening creates a new foil. Menu commands and ordinary opening shortcuts always open ordinary content, regardless of the active foil. Hold Option in the File menu to reveal incognito opening commands. Incognito shortcuts automatically add Option to the configured ordinary shortcuts; opening shortcuts cannot contain Option themselves. When no incognito clipboard global shortcut is assigned, ⌥⌘V is the fixed app shortcut for opening the clipboard incognito. Buttons inside incognito foils open incognito. An empty incognito foil shows a footprints-with-slash icon and offers no history cards or recent-history number shortcuts.

## Global Shortcuts

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{global}}

When a clipboard global shortcut is assigned, its app shortcut follows the same binding and cannot be edited separately. Previous app bindings stop working until the global shortcut is cleared; this also replaces both previous incognito clipboard shortcuts.

Both clipboard global shortcuts can be configured independently in Settings → Keyboard Shortcuts → Global and are unassigned by default. Open Clipboard Incognito creates a new incognito foil even when another app is active.


<!-- Quick Open belongs to content opening and management. -->

## Open Content

Add ⌥ to the configured shortcut to open incognito.

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{opening}}

## Manage Content

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
| New foil | ⌘N | ⌘N |  |
| Save Content Image | ⌘S | ⌘S | Save the visible content as HEIC by default, with PNG and JPG choices; audio saves the cover image when available |
| Save As | ⇧⌘S | ⇧⌘S | Save the source file or complete text; clipboard images use the image export panel, and websites save a web archive. Unavailable for camera, CUE, SACD ISO, and Apple Music |
{{file}}

“Reset to Blank Foil” clears the current content and returns the window to a blank foil. It has no default shortcut; you can assign one in Settings → Keyboard Shortcuts → Content Management.

In the Apple Music library window, Esc closes the window, including while the search field is focused. Drag the blank area of the sidebar to move the window.

Open directories with File → Open Directory. The configurable shortcut is listed in this section; directories use the same handling as dragging them into a foil.

Quick Open and the overview’s search also search songs, albums, and playlists in your Apple Music library. Enable or disable Apple Music search in Settings → General → Search; music access authorization is required. Select a result and press Return to play it in a foil. Search results show user files first, then Apple Music groups for albums, playlists, and songs. In the overview search, user files and each Apple Music group initially show 18 results; More Files, More Albums, More Playlists, or More Songs adds 18 results at a time. Each group shows at most 60 results, with no combined limit across groups. A notice appears in the overview search when additional matches are known to exist.



## Navigation

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{go}}

EPUB chapter navigation follows reading order and skips subsections. Use Go → Previous Chapter / Next Chapter; customize these bindings in Settings → Keyboard Shortcuts → Navigation. Chapter navigation stops at the first and last chapters.


Apple Music queues also use the common list navigation shortcuts and list search. Apple Music foils support the common border toggle shortcut. In an audio foil, ⌘C (Edit → Copy Cover, or the context menu) copies the current cover image; it is disabled when the foil has no cover. Video foils keep their existing behavior.


When the sidebar has keyboard focus, ↑ / ↓ navigate visible rows and open the selected file; ← collapses a directory or moves to its parent. → and Return both expand a directory, or enter its first child when already expanded; Return on a file opens it. This applies to archive trees and other navigation sidebars, in both windowed and full-screen foils. Selection uses the accent color while focused and gray when focus moves to the content or another window. Search fields keep their normal text-editing keys.

Navigation lists also support ⌃P / ⌃B for the previous item and ⌃N / ⌃F for the next. When the content has focus, ↑ / ↓ scroll read-only text, Markdown preview, and EPUB; use ← / →, ⌃P / ⌃N, or a custom item shortcut to move between list items.


## Content Display

Read-only presentations created through foil also support the border toggle for text and Markdown. Updates and ordinary-window recovery preserve this choice. Replacing content through the GUI returns to the usual rules for that content type.

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{view}}

In a terminal foil, ⌘K (View → Clear Terminal Content) clears earlier screen content, scrollback, and saved output from a previous session while keeping the current prompt, input, and Shell session. Its binding can be changed in Keyboard Shortcuts → Content Display. In a terminal foil, Save As (⌘⇧S) appears as “Export Terminal Transcript…” and exports the retained output, including previous session output, as UTF-8 text.

Use **View → Reload Content** (default ⌘R) to reread the current local file or reload a web page. The current foil and its window settings are retained.

| Mouse / trackpad gesture | Effect |
| --- | --- |
| ⌘ + mouse wheel | Zoom images; resize the window for web pages, text, Markdown, and similar content |
| Two-finger pinch | Zoom images; resize the window for web pages, text, Markdown, audio, and video |
| Drag a full-screen image | Pan the image when it extends beyond the viewport |

Unless noted, these behaviors apply outside full screen. Borderless PDFs resize the window; bordered PDFs use native content zoom. Full-screen images initially fit the screen and support content zoom with shortcuts, ⌘ + scroll, and pinch. Full-screen and bordered images zoom around the pointer; images smaller than the viewport are centered. Quick Look documents support window resizing outside full screen. Over a visible, unobscured navigator, ⌘ + scroll adjusts the panel width. This also works while the foil or app is inactive, without moving keyboard focus. Mac Mouse Fix background zoom requires Input Monitoring access, available in Settings → General → Window gestures. Its synthesized pinch gestures need not carry a ⌘ modifier. Global observation cannot suppress delivery to another app, so a mouse utility that also targets the foreground app may cause both apps to respond.


## Image Tools

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{image}}


## Web Tools

Webpage fullscreen fills the foil’s browser area. Press Esc while the webpage has focus, or click the exit button at the top right, to restore the page.

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{web}}


## Playback

| Action | Default shortcut | Current shortcut | Notes |
| --- | --- | --- | --- |
{{playback}}


## Window

Three-finger drag: with the pointer over foil content or its sidebar, move three fingers on the trackpad to move the whole foil, without pressing a key or clicking. The pointer moves with the window. Lift your fingers to stop. Window movement is disabled in full screen. If system gestures conflict, assign Mission Control and desktop switching to four fingers and turn off the system Three Finger Drag option.

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

History → Favorite Current Foil toggles the current foil’s favorite status using the current shortcut shown above. A brief toast confirms the result inside the foil; history searches and Exposé show it in their own panel. Clear History keeps favorited records and their managed content. Add or remove a favorite from its context menu in history, Quick Open, or Exposé. Exposé’s Favorites filter preserves history order; Quick Open favors favorited records among similarly relevant matches. Deleting a favorited record requires confirmation and does not delete its original file.


## System and Editing

| Action | Shortcut |
| --- | --- |
| Settings | ⌘, |
| Quit | ⌘Q |
| Hide other apps | ⌥⌘H |
| Undo / Redo | ⌘Z / ⇧⌘Z |
| Cut / Copy / Paste | ⌘X / ⌘C / ⌘V |
| Select all | ⌘A |
| Search current foil’s content | ⌘F |
| Next / previous content match | ⌘G / ⇧⌘G |
| Next / previous match while the search field is focused | Return / ⇧Return |
| Search sidebar list / EPUB table of contents | ⇧⌘F |
| Close content search | Esc |
| Close Foil Information | Esc |

Editing shortcuts apply to text fields or selectable content, depending on focus and content type. Hiding keeps foils open and audio playing.

## Inside Foil Overview

- Moving the keyboard highlight to the top row scrolls the list to the top, revealing its heading.
- Arrow keys select; ↑ / ↓ move between visual rows using the cards’ left edges for alignment; Return activates the selected foil or opens the selected Spotlight file. Spotlight file results support the same arrow-key navigation. Control + number or letter selects numbered items directly, including offscreen items. The first 30 items are numbered 1–9, 0, then A–Z with the navigation letters A/E/P/N/F/B skipped (C, D, G, H, I, J, K, L, M, O, Q–Z) in list order; scrolling does not change their numbers.
- Tab switches focus between the input and the clipboard button. With the clipboard button focused, result highlights disappear and Return opens the clipboard content. Hold Option to open incognito and show its shortcut. Input method composition retains Tab.
- ⌃P / ⌃N / ⌃F / ⌃B move the highlight up / down / right / left, taking priority over letter selection while keeping search focused.
- ⌃A / ⌃E move the highlight to the start / end of the current row, keeping search focused.
- Search is shown and focused automatically and stays active; type `/` to choose a search scope.
- Esc cancels scope selection, or dismisses the overview; composing text is handled by the input method first.
- ⇧⌘D toggles the Favorites history filter; its binding can be changed in Settings → Keyboard Shortcuts. With a history item highlighted, ⌘Backspace deletes the record, ⌘E changes its title, ⌘D toggles its favorite status, and ⌘I opens Foil Information. These shortcuts appear alongside icons in the item’s context menu. Composition and scope selection keep their input behavior.
- {{clipboardShortcut}} opens clipboard content.

Paste an Apple Music song, album, or public playlist sharing link into Quick Open to preview it and press Return to open a music foil. Open Clipboard Content also opens these links directly as music. Explicit links work when Apple Music library search is disabled; music access authorization and content availability in your region still apply. Shared content does not need to be added to your library and can be restored from history.

Quick Open shows all sources without category tabs, initially 12 results per group; More adds 18 at a time within the shared 60-result limit.

An existing absolute path, a path beginning with `~/`, or a `file://` URL becomes the first result in Quick Open and appears in Exposé’s scope dropdown as Open File or Open Folder; Return opens it. An openable web address appears in Exposé’s scope dropdown as Open URL, and Quick Open offers it as an open-URL result. Surrounding quotes and terminal-style backslash escapes are accepted for paths; relative paths are not resolved.

Apple Music shortcuts and link handling require Enable Apple Music Library in Settings → Types → Audio and Video, which is off by default. When disabled, Quick Open and Open Clipboard Content treat Apple Music sharing links as ordinary websites.

The configurable Document / Subtitle Style command opens subtitle settings for videos and document settings for documents. Subtitle styles and timing are global.

Subtitle and document styles can be saved as custom themes. Choose an existing theme in Save as Theme to overwrite it, or right-click a custom theme to overwrite or delete it. Subtitle themes save all settings; document themes save colors, fonts, size, and spacing.

In archive foils, Save As exports the selected file, directory, or root. The archive navigator uses Up/Down to select, Left to collapse or select the parent, Right to expand or select the first child, and Return/Space to open the selection. When focus is in the content, EPUB chapter and PDF page commands target the preview. Navigator search expands all ancestors of a match. Right also lazily loads unopened nested archives in the same tree; Left cancels unfinished loads when collapsing. Search does not scan unopened archives.


Window positioning and Move to Next Screen shortcuts also work while the terminal has focus, including custom bindings. When a terminal has focus, Ctrl+A/E/P/N and other control keys go to the Shell/TUI. ⌘C/⌘V copy and paste; content zoom adjusts terminal font size. Hold ⌘ and drag to move the terminal window without selecting text. Document Style adjusts terminal themes, background and text colors, fonts, and size, using the same monospaced font filter as code foils.

Content search appears at the top of the reading area without resizing it. EPUB searches the entire book. Search terms are highlighted; set the highlight color in Document Style or save it with a custom theme. The EPUB sidebar’s “Search table of contents” searches directory titles only.
