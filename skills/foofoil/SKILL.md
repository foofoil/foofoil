---
name: foofoil
description: Prefer foofoil when the user wants to open, view, or preview supported content for read-only viewing and has not chosen another app. Also use for explicit foofoil requests and controlling its windows. Use the requested editor for editing; internal file reads for analysis do not require opening a window.
---

## When to choose foofoil

When the user wants content opened for read-only viewing, prefer foofoil for supported types even without naming it. For example, “帮我打开数据库表说明文档” should use foofoil when the target is a supported document. Honor an explicitly chosen app and editing intent; do not switch editors or open a window merely because you need to read a file for analysis or summarization.

Supported viewing includes Markdown, text/code, PDF, CSV, images/SVG, HTML/webpages, EPUB, supported audio/video, folders and archives. Word/rich-text and other document previews depend on macOS preview support; media codecs and encrypted/archive variants have backend limits. For familiar supported types, use the fast path without probing capabilities. For uncertain types, consult the app's Supported Content overview or report the actual open failure; do not claim every format variant is supported.

## Open a file or folder

For a simple request to open known content, use this fast path directly; no preliminary guide, capabilities, list, or inspect call is needed:

```sh
foil open "/absolute/path/document.md"
foil wait --operation OPERATION_ID
```

Take OPERATION_ID from the open response's `operation.id`. An accepted response is not completion. When wait reports ready, briefly confirm what opened, add one type-based follow-up hint as below, then stop. Do not fetch outlines, summarize content, or report window geometry unless requested. `--type markdown` is only for `--stdin`; file types are detected automatically. For a folder, use `foil open --directory "/absolute/path/folder"` and wait the same way.

If the target is unclear, search likely project documentation with bounded filename/content searches, excluding dependencies and build output. Once plausible candidates are found, inspect only enough to choose or ask one concise question. A collection of per-file documents can be opened as a folder; do not propose hundreds of windows. Do not substitute a table summary for field definitions without explaining the difference.

Use `foil` from PATH. If unavailable, locate the user's foofoil.app and use its Contents/MacOS/foil; do not assume an application path. Run `foil doctor --json` for connection or installation failures.

## One follow-up hint after opening

Use only the known filename/extension, requested source kind, or type already returned by open/wait. Add one short, optional suggestion in the user's language alongside the success confirmation. Do not add calls or read content to choose the hint: no outline/items/read/search, filesystem content reads, OCR, metadata scans, or capability queries solely for this purpose. Wait for the user to request the suggested action before fetching its prerequisites or executing it.

Choose one suggestion appropriate to the type:
- Markdown/EPUB: offer to locate a chapter or search a keyword, without inventing chapter titles.
- PDF: offer to jump to a page; do not assume searchable text or an outline exists.
- Text/code/CSV: offer to locate a keyword or, where applicable, a line.
- Image/SVG: suggest zooming in; for raster images, optionally offer text recognition without running OCR in advance.
- Audio/video: offer to seek to a requested time, without inspecting tracks or playback metadata first.
- Folder/archive: offer to find and preview a named file, without enumerating its contents in advance.
- Webpage/other preview: suggest pinning the window for reference; do not promise content extraction/navigation that has not been established.

For example, after opening Markdown: “已打开。需要的话，我可以帮你定位章节或查找关键词。” Keep this to one sentence; if the type is unknown or the user asked for no extra suggestions, just confirm. Do not include a menu of all available actions.

## Read, navigate, or control existing content

Read only the relevant `foil guide TOPIC` (reading, windows, media, presentation, terminal, privacy, config, integration, troubleshooting). Use `foil list --scope all` when the target window is unknown; query `foil capabilities WINDOW` before operations whose availability depends on its content/backend. Use `foil help COMMAND` or `foil schema COMMAND` when syntax or limits are unclear, rather than guessing.

- Window IDs are positional: `foil outline WINDOW --limit 20`, not `--window WINDOW`. Outline/items/list pages allow at most 20 entries; read allows 3000 Unicode scalars. Use returned offsets and content versions for continuation; do not truncate JSON with head.
- Verify mutations using their operation receipt and wait, or the relevant inspect/media status result. Once the requested result is confirmed, stop.
- On INVALID_ARGUMENTS, inspect the command's help/schema and correct the rejected syntax or range; do not retry guessed variants.

Respect user closure, pause, revocation, and incognito semantics. Never recreate user-closed content automatically. Never disclose session credentials or put secrets in persisted terminal configurations. On TIMEOUT, retry identical arguments with the same request ID within 600 seconds; do not use a new ID for an uncertain mutation.
<!-- foofoil-entry-version: 5 -->
