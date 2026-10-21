import AppKit

@MainActor
enum TerminalConfigurationField: String, CaseIterable {
    case directory = "Terminal Initial Directory"
    case shell = "Terminal Shell"
    case environment = "Terminal Environment"
    case script = "Terminal Trusted Script"

    var isMultiline: Bool { self == .environment || self == .script }

    func value(in configuration: TerminalLaunchConfiguration) -> String {
        switch self {
        case .directory: configuration.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        case .shell: configuration.shellPath ?? getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) } ?? "/bin/zsh"
        case .environment: configuration.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        case .script: configuration.startupCommands
        }
    }

    func updating(_ configuration: TerminalLaunchConfiguration, with text: String) throws -> TerminalLaunchConfiguration {
        var updated = configuration
        switch self {
        case .directory: updated.workingDirectory = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .shell: updated.shellPath = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .environment:
            var values: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                guard let equal = line.firstIndex(of: "=") else { throw AgentFailure("INVALID_ARGUMENTS") }
                let key = String(line[..<equal])
                guard values[key] == nil else { throw AgentFailure("INVALID_ARGUMENTS") }
                values[key] = String(line[line.index(after: equal)...])
            }
            updated.environment = values
        case .script: updated.startupCommands = text
        }
        return updated
    }
}

extension AppState {
    func updateTerminalConfiguration(_ configuration: TerminalLaunchConfiguration) throws {
        guard terminalConfiguration != nil else { return }
        let validation = try TerminalBootstrap(configuration: configuration, terminalID: "validation")
        validation.cleanup()
        // 运行中的 PTY 保持原会话，只更新下一次启动的配置；待启动会话可以直接替换。
        if terminalSession?.state == .waiting {
            prepareTerminal(configuration, start: false)
        } else {
            terminalConfiguration = configuration
            saveState()
        }
    }
}
