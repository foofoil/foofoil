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
            var arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.isEmpty || arguments.contains("--help") || arguments == ["help"] {
                let help = """
                foil — read-only file presentation, protocol 1
                foil show FILE [--title TITLE] [--incognito] [--json]
                foil update BOARD FILE [--expected-revision N] [--json]
                foil list [--json]
                foil close BOARD [--expected-revision N] [--json]
                Options: --request-id ID --caller NAME --session FILE --app APP
                A timeout may have committed. Retry with the same request ID and arguments within 600 seconds.
                Keep original files available. Markdown images are not loaded. User-closed boards must not be recreated automatically.
                foil install [--directory DIR] | foil uninstall [--directory DIR]
                foil --version
                """
                print(localized("Agent CLI Help", fallback: help))
                return
            }
            if arguments == ["--version"] { print("foil protocol 1"); return }
            func option(_ key: String) throws -> String? {
                guard let index = arguments.firstIndex(of: key) else { return nil }
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw CLIError(code: "INVALID_ARGUMENTS") }
                let value = arguments[index + 1]
                arguments.removeSubrange(index...index + 1)
                return value
            }
            let appOption = try option("--app") ?? ProcessInfo.processInfo.environment["FOIL_APP"]
            let sessionOption = try option("--session") ?? ProcessInfo.processInfo.environment["FOIL_SESSION"]
            let title = try option("--title")
            let caller = try option("--caller") ?? "CLI"
            let expected = try option("--expected-revision")
            requestID = try option("--request-id") ?? requestID
            let directory = try option("--directory")
            let incognito = arguments.contains("--incognito")
            arguments.removeAll { $0 == "--incognito" || $0 == "--json" }
            guard let action = arguments.first else { throw CLIError(code: "INVALID_ARGUMENTS") }
            if action == "install" || action == "uninstall" {
                guard arguments.count == 1 else { throw CLIError(code: "INVALID_ARGUMENTS") }
                try install(directory: directory, removing: action == "uninstall")
                return
            }
            guard directory == nil, ["show", "update", "list", "close"].contains(action),
                  !incognito || action == "show", title == nil || action == "show",
                  expected == nil || action == "update" || action == "close" else { throw CLIError(code: "INVALID_ARGUMENTS") }
            var request = AgentRequest(request_id: requestID, action: action, caller: caller)
            switch action {
            case "show":
                guard arguments.count == 2 else { throw CLIError(code: "INVALID_ARGUMENTS") }
                request.path = URL(fileURLWithPath: arguments[1]).standardizedFileURL.path
                request.title = title; request.incognito = incognito
            case "update":
                guard arguments.count == 3 else { throw CLIError(code: "INVALID_ARGUMENTS") }
                request.board_id = arguments[1]
                request.path = URL(fileURLWithPath: arguments[2]).standardizedFileURL.path
            case "close":
                guard arguments.count == 2 else { throw CLIError(code: "INVALID_ARGUMENTS") }
                request.board_id = arguments[1]
            default: guard arguments.count == 1 else { throw CLIError(code: "INVALID_ARGUMENTS") }
            }
            if let expected {
                guard let revision = UInt64(expected) else { throw CLIError(code: "INVALID_ARGUMENTS") }
                request.expected_revision = revision
            }
            let app = try application(explicit: appOption)
            let hello = try exchange(AgentRequest(action: "hello"), app: app)
            guard hello.protocol_version == AgentLimits.protocolVersion else { throw CLIError(code: "PROTOCOL_MISMATCH") }
            let credential = try credential(run: hello.run_id, explicit: sessionOption)
            var authorization = AgentRequest(action: "authorize", run_id: hello.run_id, credential: credential.secret)
            authorization.caller = caller
            let authorized = try exchange(authorization, app: app)
            if let error = authorized.error { throw CLIError(code: error) }
            request.run_id = hello.run_id
            request.credential = credential.secret
            let response = try exchange(request, app: app)
            print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
            if let error = response.error { fputs("foil: \(error)\n", stderr); exit(1) }
        } catch {
            let code = (error as? CLIError)?.code ?? "CLI_IO_ERROR"
            var response = AgentResponse(request_id: requestID, run_id: "", status: "failed")
            response.error = code
            if let data = try? JSONEncoder().encode(response) { print(String(decoding: data, as: UTF8.self)) }
            fputs("foil: \(code)\n", stderr)
            exit(1)
        }
    }

    private static func localized(_ key: String, fallback: String) -> String {
        let url = try? application(explicit: ProcessInfo.processInfo.environment["FOIL_APP"])
        let bundle = url.flatMap { Bundle(url: $0) } ?? Bundle.main
        return NSLocalizedString(key, bundle: bundle, value: fallback, comment: "")
    }

    private static func application(explicit: String?) throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = explicit.map { URL(fileURLWithPath: $0) }
            ?? (bundled.pathExtension == "app" ? bundled : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.markonce.foofoil"))
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

    private static func install(directory: String?, removing: Bool) throws {
        let root = directory.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let destination = root.appendingPathComponent("foil")
        let receipt = root.appendingPathComponent(".foofoil-cli.sha256")
        func digest(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let recorded = try? String(contentsOf: receipt, encoding: .utf8), try digest(destination) == recorded else { throw CLIError(code: "INSTALL_CONFLICT") }
        } else if removing { throw CLIError(code: "NOT_INSTALLED") }
        if removing {
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.removeItem(at: receipt)
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let temporary = root.appendingPathComponent(".foil-\(UUID())")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            guard rename(temporary.path, destination.path) == 0 else { throw CLIError(code: "INSTALL_FAILED") }
            try digest(destination).write(to: receipt, atomically: true, encoding: .utf8)
        }
        print("{\"status\":\"ready\"}")
    }
}
