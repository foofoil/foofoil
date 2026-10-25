# foil Command Reference

`foil` ships with foofoil and opens files, controls foils, and creates interactive terminals. It is already on PATH inside terminal foils. To use it from another terminal, install it into `~/.local/bin`:

```sh
/Applications/foofoil.app/Contents/MacOS/foil install
~/.local/bin/foil --help
```

Replace the app path if installed elsewhere. Add `~/.local/bin` to PATH or use the full path. Reinstall after upgrading the app. Installation does not overwrite another tool with the same name.

## Opening files and controlling windows

| Command | Usage |
| --- | --- |
| `foil open FILE` | Open through the ordinary file pipeline. accepted does not mean loading finished. Directories are unsupported. |
| `foil open --stdin --type markdown` | Display stdin as read-only incognito Markdown. |
| `foil list --scope all` | List controllable windows and obtain `windows[].id`. |
| `foil reveal ID` | Show a window. |
| `foil hide ID` | Hide a window; terminal jobs keep running. |
| `foil inspect ID` | Read metadata such as type, visibility, opacity, and terminal state, without terminal contents. |
| `foil set ID opacity VALUE` | Supports 0.3–1.0, rounded to the window’s 10% steps; the response gives the actual value. |
| `foil close ID --scope all` | Close a window; active terminals return CONFIRMATION_REQUIRED. |
| `foil close ID --scope all --force` | Terminate managed terminal jobs and close the window. |

```sh
foil open "$HOME/Documents/reference.md"
foil list --scope all --json
foil inspect WINDOW_ID
foil set WINDOW_ID opacity 0.8
foil hide WINDOW_ID
foil reveal WINDOW_ID
printf '# Temporary reference\n\nBody\n' | foil open --stdin --type markdown
```

Replace `WINDOW_ID` with an ID from the response. Window IDs expire when the window closes or the app restarts. `content_id` identifies history content and `terminal_id` identifies a session; these IDs are not interchangeable.

## Creating interactive terminals

```sh
foil terminal create --title Dev --cwd "$HOME/projects" --shell /bin/zsh
foil terminal create --title Build --cwd /path/to/project --command 'pwd; swift build' --env MODE=debug
foil terminal create --incognito --shell /bin/bash
```

Supported shells are `/bin/zsh` and `/bin/bash`. `--cwd DIR` sets the working directory. `--command SCRIPT` runs a trusted startup script in the same shell. Repeat `--env KEY=VALUE` for environment overrides. `--title TITLE` sets the title; `--incognito` creates an incognito terminal. Ordinary history stores configuration and scripts, so do not put credentials in them. ready means the session object exists, not that the script finished; inspect reports its state.

## Read-only Agent presentation

| Command | Usage |
| --- | --- |
| `foil show FILE [--title TITLE] [--incognito]` | Create a read-only presentation foil. |
| `foil update BOARD FILE [--expected-revision N]` | Update an Agent foil, preserving layout and hidden state. |
| `foil list` | List only Agent foils owned by the current credential. |
| `foil close BOARD [--expected-revision N]` | Close only an Agent foil owned by the current credential. |

Supports local UTF-8 text, code, Markdown, raster images (first frame), and SVG. PDF, HTML, websites, media, directories, and archives are unsupported. Keep source files available and explicitly update after changes. Markdown images are blocked; show images separately. Ordinary foils enter history; incognito foils do not enter history or restart recovery. show always creates a window; do not replace a failed update with repeated show calls.

```sh
foil show ./report.md --title Report --json
foil update BOARD_ID ./report.md --expected-revision 1
foil close BOARD_ID
```

## Common options and installation

| Option or command | Meaning |
| --- | --- |
| `--json` | Response format option; current success responses already use JSON. Failures exit nonzero and print an error code to stderr. |
| `--request-id ID` | Deduplication ID. A timeout may have committed; retry with the same ID and arguments within 600 seconds. |
| `--caller NAME` | Display name, not an authorization credential. |
| `--session FILE` | Separate session credential file; also `FOIL_SESSION`. |
| `--app APP` | Explicit app path; also `FOIL_APP`. |
| `foil install [--directory DIR]` | Install CLI; defaults to `~/.local/bin`. |
| `foil uninstall [--directory DIR]` | Remove installed CLI and receipt, preserving the app and documents. |
| `foil --help` / `foil help` | Show command summary. |
| `foil --version` | Show protocol version. |

Default credentials live at `~/.local/state/foofoil/session.json`; do not share that file. General settings can pause Agent control or revoke sessions. Quote paths containing spaces. Commands control local foofoil windows; they cannot inject input into existing terminals.
