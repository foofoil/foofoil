# foil Command Reference

`foil` ships with foofoil. It opens and presents content, reads and navigates documents, controls windows and media, creates terminals, and queries configuration, history and Agent access. The syntax below comes from the current CLI; query `foil capabilities WINDOW` for actual runtime availability.

## Installation and first steps

Settings → Agent Access automatically checks the CLI installation and offers installation or reinstallation at `~/.local/bin/foil`. The first app launch installs the General Skill. Installing or reinstalling foil also installs and enables General; ordinary launches preserve your choices. Agent switches are disabled while the CLI is unavailable. To install manually:

```sh
/Applications/foofoil.app/Contents/MacOS/foil install
~/.local/bin/foil guide
~/.local/bin/foil --help
```

Replace the application path when installed elsewhere. Use the full command path if PATH cannot find it. Installation preserves unknown third-party files with the same name. Terminal foils already include `foil` on PATH.

| Offline reference | Contents |
| --- | --- |
| `foil --help` / `foil help` | Command summary |
| `foil help COMMAND` | Command syntax, for example `foil help media seek` |
| `foil guide [TOPIC]` | Getting started and focused workflows |
| `foil schema [COMMAND]` | JSON contract, arguments and ranges; static schema is not runtime availability |
| `foil --version` | CLI, entry, protocol and application build versions |

These reference commands do not launch the app or require credentials. In the syntax, `[]` means optional and `|` separates alternatives or mutually exclusive inputs. Replace FILE, WINDOW, BOARD, VERSION and other placeholders.

{{command_tables}}

## Open, wait and read

```sh
foil open "$HOME/Documents/reference.pdf" --incognito
foil wait --operation OPERATION_ID --timeout 30
foil capabilities WINDOW_ID
foil inspect WINDOW_ID
foil read WINDOW_ID --page 1 --limit 3000
foil read WINDOW_ID --page 1 --offset 3000 --limit 3000 --content-version VERSION
foil outline WINDOW_ID
foil navigate WINDOW_ID --target TARGET_ID --content-version VERSION
foil media status MEDIA_WINDOW_ID
foil media pause MEDIA_WINDOW_ID
```

Use identities and versions from earlier responses. An accepted open is not completed: retain `operation.id` and confirm with wait. Timeout does not cancel the operation. Quick Look returns COMPLETION_UNOBSERVABLE when completion cannot be confirmed. `is_loading: false` alone does not prove every asynchronous operation has completed.

Window IDs expire on application restart. BOARD identifies an owned Agent presentation, content_id identifies content, and terminal_id identifies a terminal session; do not interchange them. list defaults to owned Agent boards; use `--scope all` to list or close ordinary windows.

read uses currently loaded content. PDF requires a page number starting at 1; rendered extracts the current webpage/EPUB view; ocr only reads an existing result; terminal only reads bounded retained output, with tail from 1 to 2000 lines. Nonzero offsets require the previous content_version. Text offsets use Unicode scalars with at most 3000 per page. Outlines, items and window lists allow at most 20 entries per page and also enforce response byte limits. Continue with next_offset and the corresponding version; requery on STALE_CONTENT. Reads do not implicitly run OCR, recursively unpack archives or reread externally changed files.

search returns snippets, offsets and lines without navigating. Navigation requires a version and exactly one locator; confirm asynchronous results with wait and inspect. Media times use seconds and volume ranges from 0 to 1. Unavailable backend actions are rejected. Window frame uses the selected screen's visible top-left origin in logical points and returns the actual clamped frame.

## Presentations, terminals and privacy

```sh
foil show ./report.md --title Report --incognito
foil update BOARD_ID ./report.md --expected-revision 1
printf '# Temporary reference\n\nBody\n' | foil open --stdin --type markdown
foil terminal create --title Dev --cwd "$HOME/projects" --shell /bin/zsh
foil terminal create --title Build --cwd /path/to/project --command 'pwd; swift build' --env MODE=debug
```

show/update support read-only Agent presentations: local UTF-8 text, code, Markdown, raster first frames and SVG. Ordinary open additionally accepts document/media formats supported by the host, directories, archives, URLs and clipboard content. Keep presentation source files available and explicitly update after changes. Markdown external images are blocked. show always creates a new foil; do not use it to bypass user closure or a failed update.

Terminals support `/bin/zsh` and `/bin/bash`. Creation runs the optional startup script immediately. Ordinary history stores configuration and environment, so never include credentials. ready does not mean the script completed. Existing-terminal input injection is unavailable. Closing an active terminal may return CONFIRMATION_REQUIRED; use force only when termination is authorized.

Every open source, show, terminal create and history open accepts incognito. Incognito content does not enter history or restart recovery. Incognito history opening creates an independent copy without touching the original. Favorites refuse conversion; setting an existing target state is idempotent. Incognito does not erase exports, downloads or Agent records.

## Configuration, export and Agent access

config exposes a whitelist with types, defaults, ranges and dependencies; set does not enable prerequisites automatically. permissions status does not request authorization. History search returns bounded metadata. Export follows the host's save restrictions, requires an absolute output path, and refuses overwrite unless explicitly requested. Multi-node archive CLI export is unavailable.

Settings switches immediately install/remove Skills and check automatically. General covers Codex, Cursor, Pi, OMP, Kimi Code, ZCode, Zed Agent and other clients sharing its directory; dedicated directories have separate switches. Existing Agent sessions may need to reload Skills. CLI skill/agent commands remain available for explicit targets and advanced custom paths. Writing files does not prove an Agent session discovered them.

## Common options and recovery

| Option | Meaning |
| --- | --- |
| `--json` | Business responses already use JSON; errors exit nonzero and print a code to stderr |
| `--request-id ID` | Deduplication ID; TIMEOUT may have committed, so retry identical arguments and ID within 600 seconds |
| `--caller NAME` | Display name, not authorization |
| `--session FILE` | Separate credential file; also FOIL_SESSION |
| `--app APP` | Explicit application path; also FOIL_APP |

Default credentials are stored at `~/.local/state/foofoil/session.json`; never share them. Settings can pause Agent control or revoke sessions. Reconfirm state after version conflicts, user closure, pause or revocation instead of blindly recreating content. Quote paths containing spaces. For troubleshooting use `foil doctor --json` or `foil guide troubleshooting`.
