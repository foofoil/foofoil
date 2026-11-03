import AppKit
import Carbon
import CryptoKit
import Security

nonisolated private struct CLIError: Error { let code: String }
nonisolated private struct Credential: Codable { var run: String; var secret: String }

@MainActor
private final class LaunchState { var done = false; var error: Error? }

@MainActor
@main
struct FoilCLI {
    static func main() {
        var requestID = UUID().uuidString
        do {
            var tokens = Array(CommandLine.arguments.dropFirst())
            func emit<T: Encodable>(_ value: T) throws { print(String(decoding: try JSONEncoder().encode(value), as: UTF8.self)) }
            if tokens == ["--version"] {
                let app = try? application(explicit: ProcessInfo.processInfo.environment["FOIL_APP"])
                let bundle = app.flatMap(Bundle.init(url:))
                try emit(["cli_version": "2", "protocol_version": String(AgentLimits.protocolVersion), "entry_version": String(AgentIntegration.entryVersion), "app_version": bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown", "app_build": bundle?.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"])
                return
            }
            if tokens.isEmpty || tokens == ["--help"] || tokens == ["help"] {
                print(localized("Agent CLI Overview", fallback: "foil — local reference content and window control") + "\n" + AgentCommandCatalog.commands.sorted { $0.key < $1.key }.map { "foil " + $0.value.usage }.joined(separator: "\n") + "\nExplore: foil guide [TOPIC], foil help COMMAND, foil schema [COMMAND].")
                return
            }
            if ["help", "schema", "guide"].contains(tokens[0]) {
                let kind = tokens.removeFirst()
                guard tokens.count <= 2 else { throw CLIError(code: "INVALID_ARGUMENTS") }
                let key = tokens.joined(separator: ".")
                if kind == "guide" {
                    guard let guide = AgentCommandCatalog.guides[key.isEmpty ? "start" : key] else { throw CLIError(code: "UNKNOWN_TOPIC") }
                    print(localized("Agent Guide " + (key.isEmpty ? "start" : key), fallback: guide))
                } else if key.isEmpty {
                    try emit(AgentSchema(commands: AgentCommandCatalog.commands))
                } else {
                    guard let definition = AgentCommandCatalog.commands[key] else { throw CLIError(code: "UNKNOWN_COMMAND") }
                    if kind == "help" { print("foil " + definition.usage) }
                    else { try emit(AgentSchema(commands: [key: definition])) }
                }
                return
            }
            var action = tokens.removeFirst()
            if ["terminal", "media", "config", "permissions", "settings", "history", "window", "agent", "skill"].contains(action) || (action == "items" && tokens.first == "select") {
                guard let sub = tokens.first else { throw CLIError(code: "UNKNOWN_COMMAND") }
                tokens.removeFirst(); action += "." + sub
            }
            // --help 也使用同一命令描述；不连接宿主或请求凭证。
            guard let definition = AgentCommandCatalog.commands[action] else { throw CLIError(code: "UNKNOWN_COMMAND") }
            if tokens == ["--help"] { print("foil " + definition.usage); return }
            var values: [String: String] = [:]
            var flags = Set<String>()
            var positional: [String] = []
            var environment: [String: String] = [:]
            var literal = false
            while !tokens.isEmpty {
                let token = tokens.removeFirst()
                if token == "--", !literal { literal = true; continue }
                guard !literal && token.hasPrefix("--") else { positional.append(token); continue }
                let key = String(token.dropFirst(2))
                guard (definition.options + AgentCommandCatalog.common).contains(key), values[key] == nil, !flags.contains(key) else { throw CLIError(code: "INVALID_ARGUMENTS") }
                if AgentCommandCatalog.valued.contains(key) {
                    guard let value = tokens.first, !value.hasPrefix("--") else { throw CLIError(code: "INVALID_ARGUMENTS") }
                    tokens.removeFirst()
                    if key == "env" {
                        guard let equal = value.firstIndex(of: "="), equal != value.startIndex else { throw CLIError(code: "INVALID_ARGUMENTS") }
                        let name = String(value[..<equal])
                        guard environment[name] == nil else { throw CLIError(code: "INVALID_ARGUMENTS") }
                        environment[name] = String(value[value.index(after: equal)...])
                    } else { values[key] = value }
                } else { flags.insert(key) }
            }
            guard (definition.minimum_arguments...definition.maximum_arguments).contains(positional.count) else { throw CLIError(code: "INVALID_ARGUMENTS") }
            if let value = values["request-id"] { requestID = value }
            func path(_ value: String) -> String { URL(fileURLWithPath: NSString(string: value).expandingTildeInPath).standardizedFileURL.path }
            func number(_ key: String, _ range: ClosedRange<Double>? = nil) throws -> Double? {
                guard let raw = values[key] else { return nil }
                guard let value = Double(raw), value.isFinite, range?.contains(value) != false else { throw CLIError(code: "INVALID_ARGUMENTS") }
                return value
            }
            func integer(_ key: String, maximum: Int = Int.max) throws -> Int? {
                guard let raw = values[key] else { return nil }
                guard let value = Int(raw), value >= 0, value <= maximum else { throw CLIError(code: "INVALID_ARGUMENTS") }
                return value
            }
            let integration = AgentIntegration()
            if ["agent.status", "skill.check"].contains(action) { try emit(integration.targets()); return }
            if action.hasPrefix("skill.") || action == "agent.setup" {
                let explicit = values["agent"] != nil || values["path"] != nil || flags.contains("detected")
                let destinations = explicit ? try integration.destinations(agent: values["agent"], path: values["path"], detected: flags.contains("detected")) : nil
                guard explicit || ["skill.update", "skill.uninstall"].contains(action) else { throw CLIError(code: "TARGET_REQUIRED") }
                if action == "agent.setup" { try install(directory: nil, removing: false, reporting: false) }
                var results = try integration.manage(action == "agent.setup" ? "install" : String(action.dropFirst(6)), destinations: destinations)
                if action == "agent.setup" { results.insert(AgentIntegration.Result(path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/foil").path, status: "ready"), at: 0) }
                try emit(results)
                if results.contains(where: { $0.status == "failed" }) { exit(1) }
                return
            }
            if action == "install" || action == "uninstall" { try install(directory: values["directory"].map(path), removing: action == "uninstall"); return }
            let appOption = values["app"] ?? ProcessInfo.processInfo.environment["FOIL_APP"]
            if action == "doctor" {
                let app = try? application(explicit: appOption)
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("foil").path }
                let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
                var result = ["cli_path": executable.path, "path_cli": found ?? "not_found", "app_path": app?.path ?? "not_found", "protocol_version": String(AgentLimits.protocolVersion), "agent_discovery": "requires_new_session_and_real_call"]
                if let app {
                    let bundled = app.appendingPathComponent("Contents/MacOS/foil")
                    let current = try? Data(contentsOf: executable)
                    let shipped = try? Data(contentsOf: bundled)
                    result["bundled_cli_matches"] = current != nil && current == shipped ? "true" : "false"
                    result["running"] = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath() == app } ? "true" : "false"
                }
                result["recovery"] = "Use the app's Contents/MacOS/foil install; start a fresh Agent session. doctor never launches the app or reads credentials."
                try emit(result); return
            }
            var request = AgentRequest(request_id: requestID, action: action, caller: values["caller"] ?? "CLI")
            request.scope = values["scope"]
            guard request.scope == nil || request.scope == "all", !flags.contains("force") || request.scope == "all", request.scope == nil || ["list", "close"].contains(action), values["expected-revision"] == nil || request.scope == nil else { throw CLIError(code: "INVALID_ARGUMENTS") }
            request.force = flags.contains("force") ? true : nil
            request.incognito = flags.contains("incognito") ? true : nil
            request.title = values["title"]
            if let expected = values["expected-revision"] {
                guard let revision = UInt64(expected) else { throw CLIError(code: "INVALID_ARGUMENTS") }
                request.expected_revision = revision
            }
            request.content_version = values["content-version"]
            request.source = values["source"]
            request.target_id = values["target"] ?? values["item"]
            request.page = try integer("page"); request.line = try integer("line"); request.tail = try integer("tail", maximum: 2000)
            request.progress = try number("progress", 0...1)
            if request.page == 0 || request.line == 0 { throw CLIError(code: "INVALID_ARGUMENTS") }
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            switch action {
            case "show", "open":
                if action == "show" { request.path = path(positional[0]); break }
                guard [!positional.isEmpty, values["url"] != nil, values["directory"] != nil, flags.contains("clipboard"), flags.contains("stdin")].filter({ $0 }).count == 1 else { throw CLIError(code: "INVALID_ARGUMENTS") }
                if flags.contains("stdin") {
                    guard values["type"] == "markdown" else { throw CLIError(code: "INVALID_ARGUMENTS") }
                    var data = Data()
                    while let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, AgentLimits.textBytes + 1 - data.count)), !chunk.isEmpty {
                        data.append(chunk)
                        guard data.count <= AgentLimits.textBytes else { throw CLIError(code: "INVALID_ARGUMENTS") }
                    }
                    guard String(data: data, encoding: .utf8) != nil else { throw CLIError(code: "INVALID_ARGUMENTS") }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("foil-stdin-\(UUID()).md")
                    guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CLIError(code: "CLI_IO_ERROR") }
                    temporary = url; request.path = url.path; request.action = "show"; request.incognito = true
                } else {
                    guard values["type"] == nil, values["title"] == nil else { throw CLIError(code: "INVALID_ARGUMENTS") }
                    request.path = (positional.first ?? values["directory"]).map(path)
                    request.url = values["url"]; request.clipboard = flags.contains("clipboard") ? true : nil
                }
            case "update": request.board_id = positional[0]; request.path = path(positional[1])
            case "list":
                guard values["offset"] == nil || request.scope == "all", values["limit"] == nil || request.scope == "all", request.content_version == nil || request.scope == "all" else { throw CLIError(code: "INVALID_ARGUMENTS") }
                if request.scope == "all" {
                    request.offset = try integer("offset") ?? 0
                    request.limit = try integer("limit", maximum: 20) ?? 20
                }
            case "read", "outline", "items", "search":
                request.board_id = positional[0]
                request.offset = try integer("offset") ?? 0
                request.limit = try integer("limit", maximum: action == "read" ? 3000 : 20) ?? (action == "read" ? 3000 : 20)
                guard request.limit != 0, request.source == nil || ["original", "rendered", "ocr", "terminal"].contains(request.source!) else { throw CLIError(code: "INVALID_ARGUMENTS") }
                if action == "search" { request.query = positional[1] }
            case "navigate", "items.select", "media.select":
                request.board_id = positional[0]
                guard [request.target_id != nil, request.page != nil, request.line != nil, request.progress != nil].filter({ $0 }).count == 1, request.content_version != nil else { throw CLIError(code: "INVALID_ARGUMENTS") }
            case "wait":
                guard (positional.count == 1) != (values["operation"] != nil), values["until"] == nil || values["until"] == "ready" else { throw CLIError(code: "INVALID_ARGUMENTS") }
                request.board_id = positional.first; request.operation_id = values["operation"]
            case "terminal.create":
                request.terminal = TerminalLaunchConfiguration(shellPath: values["shell"], workingDirectory: values["cwd"].map(path), environment: environment, startupCommands: values["command"] ?? "")
            case "set":
                request.board_id = positional[0]; request.property = positional[1]
                switch positional[1] {
                case "opacity", "zoom":
                    guard let value = Double(positional[2]), value.isFinite, (positional[1] == "opacity" ? 0.3...1 : 0.05...8).contains(value) else { throw CLIError(code: "INVALID_ARGUMENTS") }
                    request.value = value
                case "incognito", "pinned", "border":
                    guard ["true", "false"].contains(positional[2]) else { throw CLIError(code: "INVALID_ARGUMENTS") }
                    request.boolean_value = positional[2] == "true"
                case "title": request.title = positional[2]
                case "navigator": request.text_value = positional[2]
                default: throw CLIError(code: "INVALID_ARGUMENTS")
                }
            case "media.seek":
                guard (values["to"] != nil) != (values["by"] != nil) else { throw CLIError(code: "INVALID_ARGUMENTS") }
                request.board_id = positional[0]; request.value = try number(values["to"] == nil ? "by" : "to"); request.property = values["to"] == nil ? "by" : "to"
            case "media.volume", "media.mute", "media.mode":
                request.board_id = positional[0]; request.text_value = positional[1]
            case "config.get": request.property = positional[0]
            case "config.set": request.property = positional[0]; request.text_value = positional[1]
            case "settings.open": request.text_value = values["section"] ?? "general"
            case "history.search": request.query = positional[0]; request.limit = try integer("limit", maximum: 20) ?? 20
            case "history.open": request.target_id = positional[0]
            case "export":
                request.board_id = positional[0]; request.output = values["output"]; request.format = values["format"]; request.overwrite = flags.contains("overwrite")
                guard request.output?.hasPrefix("/") == true, ["original", "png"].contains(request.format ?? "") else { throw CLIError(code: "INVALID_ARGUMENTS") }
            case "window.frame":
                request.board_id = positional[0]; request.screen_id = values["screen"]
                guard let x = try number("x"), let y = try number("y"), let width = try number("width", 1...100_000), let height = try number("height", 1...100_000), request.screen_id != nil else { throw CLIError(code: "INVALID_ARGUMENTS") }
                request.frame = AgentFrame(x: x, y: y, width: width, height: height)
            default: request.board_id = positional.first
            }
            let waitTimeout = try number("timeout", 0...300) ?? 30
            let app = try application(explicit: appOption)
            let hello = try exchange(AgentRequest(action: "hello"), app: app)
            guard hello.protocol_version == AgentLimits.protocolVersion else { throw CLIError(code: "PROTOCOL_MISMATCH") }
            let general = request.scope == "all" || AgentCommandCatalog.generalActions.contains(request.action)
            guard !general || hello.capabilities?.contains("application-control-v2") == true else { throw CLIError(code: "PROTOCOL_MISMATCH") }
            let credential = try credential(run: hello.run_id, explicit: values["session"] ?? ProcessInfo.processInfo.environment["FOIL_SESSION"])
            var authorization = AgentRequest(action: "authorize", run_id: hello.run_id, credential: credential.secret)
            authorization.caller = request.caller
            let authorized = try controlExchange(authorization, app: app, endpoint: hello.socket_path)
            if let error = authorized.error { throw CLIError(code: error) }
            request.run_id = hello.run_id; request.credential = credential.secret
            var response = try controlExchange(request, app: app, endpoint: hello.socket_path)
            if request.action == "wait" {
                let timeout = waitTimeout
                let deadline = Date().addingTimeInterval(timeout)
                while response.error == nil && response.operation?.status == "pending" && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    // 每次采样是独立只读查询，避免请求去重回放第一次的 pending 快照。
                    request.request_id = UUID().uuidString
                    response = try controlExchange(request, app: app, endpoint: hello.socket_path)
                }
                if response.operation?.status == "pending" { response.status = "pending"; response.error = "WAIT_TIMEOUT"; response.retryable = true; response.recovery = "foil guide troubleshooting" }
                response.request_id = requestID
            }
            try emit(response)
            if let error = response.error { fputs("foil: \(error)\n", stderr); exit(1) }
        } catch {
            let code = (error as? CLIError)?.code ?? (error as? IntegrationError)?.code ?? (error as? AgentTransportFailure)?.code ?? "CLI_IO_ERROR"
            var response = AgentResponse(request_id: requestID, run_id: "", status: "failed")
            response.error = code; response.recovery = "foil guide troubleshooting"; response.retryable = ["TIMEOUT", "QUEUE_FULL", "NOT_READY"].contains(code)
            if let data = try? JSONEncoder().encode(response) { print(String(decoding: data, as: UTF8.self)) }
            fputs("foil: \(code)\n", stderr); exit(1)
        }
    }

    private static func controlExchange(_ request: AgentRequest, app: URL, endpoint: String?) throws -> AgentResponse {
        if let endpoint { return try AgentSocketIO.exchange(request, path: endpoint) }
        return try exchange(request, app: app)
    }

    private static func localized(_ key: String, fallback: String) -> String {
        let url = try? application(explicit: ProcessInfo.processInfo.environment["FOIL_APP"])
        let bundle = url.flatMap { Bundle(url: $0) } ?? Bundle.main
        return NSLocalizedString(key, bundle: bundle, value: fallback, comment: "")
    }

    private static func application(explicit: String?) throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let record = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/foofoil/AgentIntegration/app-path")
        let recorded = (try? String(contentsOf: record, encoding: .utf8)).map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let app = explicit.map { URL(fileURLWithPath: $0) }
            ?? (bundled.pathExtension == "app" ? bundled : recorded ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.markonce.foofoil"))
        guard let app, Bundle(url: app)?.bundleIdentifier == "com.markonce.foofoil" else { throw CLIError(code: "APP_NOT_FOUND") }
        return app.resolvingSymlinksInPath()
    }

    private static func credential(run: String, explicit: String?) throws -> Credential {
        let url = explicit.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/foofoil/session.json")
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // 跨 CLI 进程串行化首次创建／应用重启换证；不把调用方名称当成授权边界。
        let lockURL = parent.appendingPathComponent(".foil-session.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CLIError(code: "CREDENTIAL_UNAVAILABLE") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CLIError(code: "CREDENTIAL_UNAVAILABLE") }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw CLIError(code: "CREDENTIAL_UNAVAILABLE") }
            let data = try Data(contentsOf: url)
            guard data.count <= 4096 else { throw CLIError(code: "CREDENTIAL_UNAVAILABLE") }
            let existing = try JSONDecoder().decode(Credential.self, from: data)
            if existing.run == run { return existing }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CLIError(code: "CREDENTIAL_UNAVAILABLE") }
        let value = Credential(run: run, secret: bytes.map { String(format: "%02x", $0) }.joined())
        let data = try JSONEncoder().encode(value)
        let temporary = parent.appendingPathComponent(".foil-session-\(UUID())")
        FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, url.path) == 0 else { throw CLIError(code: "CREDENTIAL_UNAVAILABLE") }
        return value
    }

    private static func exchange(_ request: AgentRequest, app: URL) throws -> AgentResponse {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("foil-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let envelope = root.appendingPathComponent("request.foilrequest")
        let data = try JSONEncoder().encode(request)
        guard data.count <= AgentLimits.envelopeBytes else { throw CLIError(code: "INVALID_ARGUMENTS") }
        guard FileManager.default.createFile(atPath: envelope.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CLIError(code: "CLI_IO_ERROR") }
        var urls = [envelope]
        if let path = request.path { urls.insert(URL(fileURLWithPath: path), at: 0) }
        let launch = LaunchState()
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.resolvingSymlinksInPath().path == app.path }) {
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                                               targetDescriptor: NSAppleEventDescriptor(processIdentifier: running.processIdentifier),
                                               returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            let list = NSAppleEventDescriptor.list()
            for (index, url) in urls.enumerated() { list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1) }
            event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
            _ = try event.sendEvent(options: [.noReply, .neverInteract], timeout: 5)
            launch.done = true
        } else {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            config.allowsRunningApplicationSubstitution = false
            config.arguments = ["--foil-agent"]
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config) { _, error in
                DispatchQueue.main.async { launch.done = true; launch.error = error }
            }
        }
        let deadline = Date().addingTimeInterval(AgentLimits.timeout + 5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            if launch.done, launch.error != nil { throw CLIError(code: "APP_LAUNCH_FAILED") }
            if let data = try? Data(contentsOf: envelope), data.count <= AgentLimits.envelopeBytes,
               let response = try? JSONDecoder().decode(AgentResponse.self, from: data), response.request_id == request.request_id { return response }
        }
        throw CLIError(code: "TIMEOUT")
    }

    private static func install(directory: String?, removing: Bool, reporting: Bool = true) throws {
        let integration = AgentIntegration()
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let destination = directory.map { URL(fileURLWithPath: $0) }
        if removing { try integration.installCLI(source: source, directory: destination, removing: true) }
        else if let error = try integration.installCLIWithDefaults(source: source, directory: destination) {
            throw IntegrationError(error)
        }
        if reporting { print("{\"status\":\"ready\"}") }
    }
}
