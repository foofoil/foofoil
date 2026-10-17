# Agent read-only terminal

The app ships a native command at `foofoil.app/Contents/MacOS/foil`. Local development support is implemented; Developer ID, notarization, and clean-machine distribution checks remain pending.

Install to `~/.local/bin` (adjust the app path if needed):

```sh
/Applications/foofoil.app/Contents/MacOS/foil install
~/.local/bin/foil --version
```

Use the absolute command path if your shell does not search that directory. Installation does not modify PATH or replace a third-party command. After upgrading, run install from the new app again. The installed native copy discovers moved apps through LaunchServices. `foil uninstall` removes the matching installed tool and receipt, leaving the app and documents intact.

```sh
foil show ./architecture.svg --title 'Architecture' --caller 'My Agent' --request-id diagram-1 --json
foil show ./report.md --incognito --request-id report-1 --json
foil update BOARD_ID ./report.md --expected-revision 1 --request-id report-2 --json
foil list --json
foil close BOARD_ID --json
```

show always creates a new board. update retains layout and hidden state; changing a file at the same path requires an explicit update. Keep original files available: success does not archive them. Ordinary windows save references in history; incognito windows do not enter history or restart recovery. Restored ordinary windows belong to the user and have no previous control identity.

Inputs are UTF-8 text/code/Markdown, PNG/JPEG/HEIC/TIFF/GIF/WebP/BMP images (first frame), and SVG. Markdown images are replaced with an unavailable marker and a MARKDOWN_RESOURCES_BLOCKED warning. Present required images separately. The interface does not accept raw text bodies, editing, file writes, PDF, HTML, websites, media, directories, or archives.

stdout is JSON; failures exit nonzero with an error code on stderr. Save board_id and revision. TIMEOUT may have committed: retry identical arguments with the same request_id within 600 seconds. Never blindly recreate a board after the interval, or bypass BOARD_NOT_FOUND, CONTROL_PAUSED, or PERMISSION_DENIED using show or new credentials.

General settings provides Pause Agent Control and Revoke Agent Sessions. Pausing allows authorized queries and blocks new or pending writes. Foil Information shows the caller label. Replacing content in the GUI relinquishes control; moving, resizing, or pinning does not. Control identities, revocation, and pause state last for the current app run.

CLI calls share `~/.local/state/foofoil/session.json` by default. Use separate private `--session FILE` paths for separate callers. `--caller` is only a label. Do not disclose credential files. Development builds can be selected using `--app /absolute/foofoil.app` or FOIL_APP; FOIL_SESSION selects a credential file.

The bundled Skill at `foofoil.app/Contents/Resources/AgentSkills/foofoil/SKILL.md` ([source](../skills/foofoil/SKILL.md)) can be copied to an agent's supported skill directory. Only the native CLI is verified here; installation compatibility with other agents is not promised. See the [protocol](agent-terminal-protocol-v1.zh-CN.md) for limits, readiness, and pending distribution checks.
