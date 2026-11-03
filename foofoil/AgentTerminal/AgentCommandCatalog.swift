import Foundation

/// CLI 帮助、schema 与参数白名单共用的离线契约；不表示当前窗口具备这些能力。
nonisolated enum AgentCommandCatalog {
    struct Definition: Codable, Sendable {
        var usage: String
        var minimum_arguments: Int
        var maximum_arguments: Int
        var options: [String]
        var status: String = "ready"
    }
    static let common = ["json", "request-id", "caller", "session", "app"]
    static let valued = Set(["title", "expected-revision", "scope", "cwd", "shell", "command", "env", "type", "offset", "limit", "content-version", "source", "target", "page", "line", "progress", "tail", "operation", "timeout", "until", "url", "directory", "format", "output", "screen", "x", "y", "width", "height", "to", "by", "item", "section", "agent", "path", "request-id", "caller", "session", "app"])
    static let commands: [String: Definition] = [
        "show": .init(usage: "show FILE [--title TITLE] [--incognito]", minimum_arguments: 1, maximum_arguments: 1, options: ["title", "incognito"]),
        "update": .init(usage: "update BOARD FILE [--expected-revision N]", minimum_arguments: 2, maximum_arguments: 2, options: ["expected-revision"]),
        "list": .init(usage: "list [--scope all] [--incognito] [--offset N] [--limit N] [--content-version VERSION]", minimum_arguments: 0, maximum_arguments: 0, options: ["scope", "incognito", "offset", "limit", "content-version"]),
        "close": .init(usage: "close ID [--scope all] [--force] [--expected-revision N]", minimum_arguments: 1, maximum_arguments: 1, options: ["scope", "force", "expected-revision"]),
        "open": .init(usage: "open FILE | --url URL | --directory DIR | --clipboard | --stdin --type markdown [--incognito]", minimum_arguments: 0, maximum_arguments: 1, options: ["url", "directory", "clipboard", "stdin", "type", "incognito", "title"], status: "accepted"),
        "inspect": .init(usage: "inspect WINDOW", minimum_arguments: 1, maximum_arguments: 1, options: []),
        "reveal": .init(usage: "reveal WINDOW", minimum_arguments: 1, maximum_arguments: 1, options: []),
        "focus": .init(usage: "focus WINDOW", minimum_arguments: 1, maximum_arguments: 1, options: []),
        "hide": .init(usage: "hide WINDOW", minimum_arguments: 1, maximum_arguments: 1, options: []),
        "capabilities": .init(usage: "capabilities [WINDOW]", minimum_arguments: 0, maximum_arguments: 1, options: []),
        "read": .init(usage: "read WINDOW [--source original|rendered|ocr|terminal] [--page N] [--tail N] [--offset N] [--limit N] [--content-version VERSION]", minimum_arguments: 1, maximum_arguments: 1, options: ["source", "page", "tail", "offset", "limit", "content-version"]),
        "outline": .init(usage: "outline WINDOW [--offset N] [--limit N] [--content-version VERSION]", minimum_arguments: 1, maximum_arguments: 1, options: ["offset", "limit", "content-version"]),
        "items": .init(usage: "items WINDOW [--offset N] [--limit N] [--content-version VERSION]", minimum_arguments: 1, maximum_arguments: 1, options: ["offset", "limit", "content-version"]),
        "search": .init(usage: "search WINDOW QUERY [--source SOURCE] [--page N] [--offset N] [--limit N] [--content-version VERSION]", minimum_arguments: 2, maximum_arguments: 2, options: ["source", "page", "offset", "limit", "content-version"]),
        "navigate": .init(usage: "navigate WINDOW --target ID | --page N | --line N | --progress RATIO --content-version VERSION", minimum_arguments: 1, maximum_arguments: 1, options: ["target", "page", "line", "progress", "content-version"], status: "accepted"),
        "items.select": .init(usage: "items select WINDOW --item ID --content-version VERSION", minimum_arguments: 1, maximum_arguments: 1, options: ["item", "content-version"], status: "accepted"),
        "wait": .init(usage: "wait WINDOW [--until ready] | --operation ID [--timeout SECONDS]", minimum_arguments: 0, maximum_arguments: 1, options: ["until", "operation", "timeout"]),
        "set": .init(usage: "set WINDOW opacity|incognito|pinned|border|title|zoom|navigator VALUE", minimum_arguments: 3, maximum_arguments: 3, options: []),
        "screens": .init(usage: "screens", minimum_arguments: 0, maximum_arguments: 0, options: []),
        "window.frame": .init(usage: "window frame WINDOW --screen ID --x X --y Y --width W --height H", minimum_arguments: 1, maximum_arguments: 1, options: ["screen", "x", "y", "width", "height"]),
        "terminal.create": .init(usage: "terminal create [--title TITLE] [--cwd DIR] [--shell PATH] [--command SCRIPT] [--env KEY=VALUE] [--incognito]", minimum_arguments: 0, maximum_arguments: 0, options: ["title", "cwd", "shell", "command", "env", "incognito"]),
        "media.status": .init(usage: "media status WINDOW", minimum_arguments: 1, maximum_arguments: 1, options: []),
        "media.play": .init(usage: "media play WINDOW", minimum_arguments: 1, maximum_arguments: 1, options: [], status: "accepted"),
        "media.pause": .init(usage: "media pause WINDOW", minimum_arguments: 1, maximum_arguments: 1, options: [], status: "accepted"),
        "media.seek": .init(usage: "media seek WINDOW --to SECONDS | --by SECONDS", minimum_arguments: 1, maximum_arguments: 1, options: ["to", "by"], status: "accepted"),
        "media.next": .init(usage: "media next WINDOW", minimum_arguments: 1, maximum_arguments: 1, options: [], status: "accepted"),
        "media.previous": .init(usage: "media previous WINDOW", minimum_arguments: 1, maximum_arguments: 1, options: [], status: "accepted"),
        "media.volume": .init(usage: "media volume WINDOW VALUE", minimum_arguments: 2, maximum_arguments: 2, options: []),
        "media.mute": .init(usage: "media mute WINDOW true|false", minimum_arguments: 2, maximum_arguments: 2, options: []),
        "media.mode": .init(usage: "media mode WINDOW sequential|sequentialLoop|shuffle|singleLoop", minimum_arguments: 2, maximum_arguments: 2, options: []),
        "media.select": .init(usage: "media select WINDOW --item ID --content-version VERSION", minimum_arguments: 1, maximum_arguments: 1, options: ["item", "content-version"], status: "accepted"),
        "config.list": .init(usage: "config list", minimum_arguments: 0, maximum_arguments: 0, options: []),
        "config.get": .init(usage: "config get KEY", minimum_arguments: 1, maximum_arguments: 1, options: []),
        "config.set": .init(usage: "config set KEY VALUE", minimum_arguments: 2, maximum_arguments: 2, options: []),
        "permissions.status": .init(usage: "permissions status", minimum_arguments: 0, maximum_arguments: 0, options: []),
        "settings.open": .init(usage: "settings open --section general|types|keyboardShortcuts|agent", minimum_arguments: 0, maximum_arguments: 0, options: ["section"]),
        "history.search": .init(usage: "history search QUERY [--limit N]", minimum_arguments: 1, maximum_arguments: 1, options: ["limit"]),
        "history.open": .init(usage: "history open HISTORY_ID [--incognito]", minimum_arguments: 1, maximum_arguments: 1, options: ["incognito"], status: "accepted"),
        "export": .init(usage: "export WINDOW --format original|png --output /absolute/path [--overwrite]", minimum_arguments: 1, maximum_arguments: 1, options: ["format", "output", "overwrite"]),
        "install": .init(usage: "install [--directory DIR]", minimum_arguments: 0, maximum_arguments: 0, options: ["directory"]),
        "uninstall": .init(usage: "uninstall [--directory DIR]", minimum_arguments: 0, maximum_arguments: 0, options: ["directory"]),
        "agent.setup": .init(usage: "agent setup --agent AGENT | --detected | --path /skills/foofoil", minimum_arguments: 0, maximum_arguments: 0, options: ["agent", "detected", "path"]),
        "agent.status": .init(usage: "agent status", minimum_arguments: 0, maximum_arguments: 0, options: []),
        "skill.install": .init(usage: "skill install --agent " + AgentIntegration.adapters.map(\.id).joined(separator: "|") + " | --detected | --path /skills/foofoil", minimum_arguments: 0, maximum_arguments: 0, options: ["agent", "detected", "path"]),
        "skill.check": .init(usage: "skill check", minimum_arguments: 0, maximum_arguments: 0, options: []),
        "skill.update": .init(usage: "skill update [--agent AGENT | --path PATH | --detected]", minimum_arguments: 0, maximum_arguments: 0, options: ["agent", "detected", "path"]),
        "skill.uninstall": .init(usage: "skill uninstall [--agent AGENT | --path PATH]", minimum_arguments: 0, maximum_arguments: 0, options: ["agent", "path"]),
        "doctor": .init(usage: "doctor", minimum_arguments: 0, maximum_arguments: 0, options: [])
    ]
    static let generalActions = Set(commands.keys).subtracting(["show", "update", "list", "close", "install", "uninstall", "doctor", "agent.setup", "agent.status", "skill.install", "skill.check", "skill.update", "skill.uninstall"])
    static let readOnly = Set(["list", "inspect", "capabilities", "read", "outline", "items", "search", "wait", "media.status", "config.list", "config.get", "permissions.status", "history.search", "screens"])
    static let guides: [String: String] = [
        "start": """
        foofoil displays and controls local reference content. To open known content: foil open /absolute/path/file, then foil wait --operation ID from the response; confirm and stop. File type is automatic; --type markdown is only for --stdin. For folders use foil open --directory /absolute/path/folder. No preliminary capabilities/list/inspect is needed for this fast path.
        For existing content, use foil list --scope all when the target is unknown and foil capabilities WINDOW before content-dependent operations.
        Run foil help COMMAND or foil schema COMMAND for the local contract. Static schema is not runtime availability.
        Topics: presentation, reading, windows, media, privacy, config, terminal, integration, troubleshooting.
        After open, retain operation.id and use foil wait --operation ID. accepted is not completed. Query the result after mutations.
        """,
        "presentation": "Use show FILE for a new owned board; retain board_id and revision. Update with update BOARD FILE --expected-revision N. Keep source files available. Markdown external resources are blocked. Never recreate a user-closed board.",
        "reading": "Query capabilities WINDOW. read uses Unicode scalar offsets (limit 1..3000); nonzero offsets require --content-version. PDF read requires --page (1 based); rendered reads current loaded WebKit/EPUB text. OCR only reads an existing result. terminal --tail reads bounded retained output. outline and items have limit 1..20 and version-bound offsets. search returns scalar offsets and lines without moving the viewport. navigate requires --content-version and exactly one locator. Requery on STALE_CONTENT or STALE_TARGET. Extraction can return TEXT_NOT_EXTRACTED, NO_TEXT, or CAPABILITY_UNAVAILABLE.",
        "windows": "Use list --scope all, inspect WINDOW, capabilities WINDOW. Window handles expire on app restart. reveal shows without activating the app; focus explicitly activates. screens reports visible screen bounds; window frame uses that screen's top-left logical-point origin and clamps to its visible area. zoom ranges depend on content. Navigator values: visible, hidden, auto.",
        "media": "Use media status WINDOW and runtime capabilities. Times are seconds, volume 0..1. Query status after accepted play/pause/seek; an operation receipt is not proof of playback. Backend capability and device availability apply; all operations use existing playback coordination. items and media select use version-bound opaque targets.",
        "privacy": "All open sources, show, terminal create, and history open accept --incognito. Incognito history opens an independent copy without touching the original. set WINDOW incognito true|false is idempotent; favorites refuse conversion. Inspect privacy results. Derived foils inherit privacy. Incognito does not erase exports, downloads, or Agent records. Never disclose credentials.",
        "config": "config list describes the explicit whitelist, defaults, ranges, and dependencies. config set does not enable prerequisites automatically. permissions status never requests permission or presents a dialog. settings open explicitly opens the selected settings pane. history search returns bounded metadata/snippets; export requires an absolute output and refuses overwrite unless --overwrite.",
        "terminal": "terminal create starts a shell and optional --command immediately; only use when authorized by the user. Command and environment can persist: never include secrets. No existing-terminal input injection. read --source terminal reads retained output. Busy close requires authorized --force.",
        "integration": "skill install requires --agent, --detected, or --path. Supported agents: codex, claude, cursor, opencode (v1/v2; aliases opencode-v1/opencode-v2), pi, omp, workbuddy, qoder, qoder-cn, kimi, zcode, zed, shared. Shared-compatible agents use ~/.agents/skills; OpenCode uses ~/.config/opencode/skills; WorkBuddy ~/.workbuddy/skills; Qoder ~/.qoder/skills; Qoder CN ~/.qoder-cn/skills; Claude Code ~/.claude/skills. Agent application/configuration detection is separate from foofoil Skill installation. agent setup also installs the CLI to ~/.local/bin. Update/uninstall only managed, unmodified files. Files installed does not prove discovery: start a new Agent session and perform a real call. No permissions or global instructions are modified.",
        "troubleshooting": "Run foil doctor --json. Check PATH and absolute CLI paths separately; GUI Agent PATH may differ. Choose --app /absolute/foofoil.app to avoid an outdated app. On TIMEOUT retry identical arguments and request ID within 600 seconds. wait timeout does not cancel an operation. Do not bypass CONTROL_PAUSED, PERMISSION_DENIED, or user closure. Unrecognized commands fail; explore foil --help, foil guide, or foil schema."
    ]
}

extension AgentCommandCatalog {
    static func valid(_ r: AgentRequest) -> Bool {
        let action = r.action
        func allowed(_ present: Bool, _ actions: [String]) -> Bool { !present || actions.contains(action) }
        return allowed(r.path != nil, ["open", "show", "update"])
            && allowed(r.incognito != nil, ["open", "show", "list", "terminal.create", "history.open"])
            && allowed(r.expected_revision != nil, ["update", "close"])
            && (r.expected_revision == nil || r.scope == nil)
            && allowed(r.force != nil, ["close"]) && (r.force == nil || r.scope == "all")
            && allowed(r.title != nil, ["show", "set", "terminal.create"])
            && allowed(r.terminal != nil, ["terminal.create"])
            && allowed(r.property != nil, ["set", "config.get", "config.set", "media.seek"])
            && allowed(r.value != nil, ["set", "media.seek"])
            && allowed(r.boolean_value != nil, ["set"])
            && allowed(r.offset != nil, ["read", "outline", "items", "search", "list"])
            && allowed(r.limit != nil, ["read", "outline", "items", "search", "history.search", "list"])
            && allowed(r.content_version != nil, ["read", "outline", "items", "search", "navigate", "items.select", "media.select", "list"])
            && allowed(r.target_id != nil, ["navigate", "items.select", "media.select", "history.open"])
            && allowed(r.source != nil, ["read", "search"])
            && (r.source == nil || ["original", "rendered", "ocr", "terminal"].contains(r.source!))
            && allowed(r.query != nil, ["search", "history.search"])
            && allowed(r.operation_id != nil, ["wait"])
            && allowed(r.page != nil, ["read", "search", "navigate"])
            && allowed(r.line != nil || r.progress != nil, ["navigate"])
            && allowed(r.tail != nil, ["read"]) && (r.tail == nil || r.source == "terminal")
            && allowed(r.url != nil || r.clipboard != nil, ["open"])
            && allowed(r.output != nil || r.format != nil || r.overwrite != nil, ["export"])
            && allowed(r.text_value != nil, ["set", "config.set", "settings.open", "media.volume", "media.mute", "media.mode"])
            && allowed(r.screen_id != nil || r.frame != nil, ["window.frame"])
    }
}

nonisolated struct AgentSchema: Codable {
    var agent_targets = AgentIntegration.adapters.map(\.id)
    var schema_version = 2
    var protocol_version = AgentLimits.protocolVersion
    var commands: [String: AgentCommandCatalog.Definition]
    var offset_unit = "unicode_scalar"
    var read_limit = 3000
    var item_limit = 20
    var page_and_line_base = 1
    var opacity_minimum = 0.3
    var opacity_maximum = 1.0
    var time_unit = "seconds"
    var volume_range = [0.0, 1.0]
    var content_version_required_for_nonzero_offset = true
    var error_recovery = "foil guide troubleshooting"
}
