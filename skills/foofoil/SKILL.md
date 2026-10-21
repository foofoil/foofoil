---
name: foofoil
description: Present and explicitly update local reference files in foofoil floating windows through its foil CLI. Use for diagrams, reports, and persistent references when foofoil is installed.
---

Use `foil --version` and `foil --help` to check availability. The supported protocol is 1. If the command is absent, the installed app ships `/Applications/foofoil.app/Contents/MacOS/foil`; its `install` command copies the native tool to `~/.local/bin`. Respect the user's installation path and execution permissions. Do not overwrite another command named foil. No daemon or language runtime is needed. The host is distributed outside the Mac App Store and does not use App Sandbox; macOS privacy controls still apply.

Write the artifact to a local file before presenting it. Use a stable source path for documents that should remain in history. Keep the source available for as long as foofoil needs to read or restore it: successful presentation does not archive a copy. Use `--incognito` for temporary references; it does not write history or restore after app exit.

```sh
foil show ./report.md --incognito --caller 'My Agent' --request-id report-first --json
foil update BOARD_ID ./report.md --expected-revision 1 --request-id report-second --json
foil list --json
foil close BOARD_ID --json
```

Parse stdout as JSON. `status: ready` means the content was validated and committed, not that pixels have finished drawing. Record `board_id` and `revision`. Updating the same report should reuse its board; use show for distinct references or deliberate comparisons. Application restarts invalidate control identities; restored ordinary windows belong to the user.

Inputs are local UTF-8 text/code/Markdown, raster images, and SVG. Markdown is self-contained: image references are replaced by an unavailable-resource marker, with `MARKDOWN_RESOURCES_BLOCKED` in warnings. Present required images as separate files/windows. Do not request broader directory access. PDF, HTML, websites, media, directories, text-body input, editing, and writing back through foofoil are outside this interface.

The credential file is private and must not be printed, included in artifacts, or shared. `--caller` only labels the source; it does not authorize access. Separate callers may use separate private `--session FILE` paths. Query and update only boards returned for the current credential.

On TIMEOUT, execution may have occurred. Retry with the **same request ID and identical arguments** within 600 seconds; never silently substitute a new ID. After that interval, check state and ask the user before recreating a potentially closed board. Revision conflicts require inspecting the current revision rather than overwriting it blindly.

Respect BOARD_NOT_FOUND, CONTROL_PAUSED, and PERMISSION_DENIED. A user closing, replacing, pausing, or revoking control is not a reason to issue show again or create new credentials to bypass the decision. Fall back to the agent's original interface on failure. Do not manipulate GUI notes, edit content through the app, or change sandbox/signing settings.

## General window control and interactive terminals

Use `foil list --scope all --json` only when the user asks to manage ordinary windows. Use the returned `windows[].id` with `reveal`, `hide`, `inspect`, `set ID opacity VALUE`, or `close ID --scope all`. These IDs differ from owned Agent board IDs and persistent content IDs. Inspect returns metadata, not terminal output. Existing `show FILE` still creates a new presentation.

When explicitly asked to run a new interactive terminal, use `foil terminal create --title TITLE --cwd DIR --command SCRIPT`. Creation starts the new session and runs the optional script immediately; only create it when the user authorizes that execution. Startup scripts and explicit environment values are persisted: do not put secrets in them. Reopening a closed terminal starts a new session with its saved configuration; revealing a running terminal keeps the existing process. Automatic app restoration waits for the user to start it. Normal foils retain a bounded read-only output record; incognito foils do not persist output. There is no public API for injecting input into an existing terminal.

A busy terminal close returns CONFIRMATION_REQUIRED immediately. Use `--force` only when termination is authorized. Do not bypass pause/revocation or recreate user-closed sessions. Hide preserves processes. `open FILE` returns accepted before asynchronous loading completes; terminal creation ready means the session object exists, not that the command completed. `foil open --stdin --type markdown` is ephemeral, read-only and incognito.
