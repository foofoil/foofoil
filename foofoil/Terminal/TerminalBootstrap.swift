import Foundation

/// 使用 Shell 原生启动入口，在同一个交互式 Shell 内运行初始化，避免提示符识别与输入注入竞争。
nonisolated struct TerminalBootstrap {
    let directory: URL
    let shell: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String

    init(configuration: TerminalLaunchConfiguration, terminalID: String) throws {
        let user = getpwuid(getuid())?.pointee
        shell = configuration.shellPath.map { NSString(string: $0).expandingTildeInPath } ?? user?.pw_shell.map { String(cString: $0) } ?? "/bin/zsh"
        guard ["zsh", "bash"].contains(URL(fileURLWithPath: shell).lastPathComponent),
              shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell),
              configuration.startupCommands.utf8.count <= 32_768,
              !configuration.startupCommands.contains("\0"), configuration.environment.count <= 128,
              configuration.environment.allSatisfy({ key, value in
                  key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
                    && !key.hasPrefix("FOOFOIL_") && !value.contains("\0") && value.utf8.count <= 8192
              }) else { throw AgentFailure("INVALID_ARGUMENTS") }
        workingDirectory = configuration.resolvedWorkingDirectory
        var isDirectory: ObjCBool = false
        guard workingDirectory.hasPrefix("/"), FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: workingDirectory) else { throw AgentFailure("WORKING_DIRECTORY_UNAVAILABLE") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-shell-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var env = ProcessInfo.processInfo.environment
        env.merge(configuration.environment) { _, explicit in explicit }
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["LC_CTYPE"] == nil { env["LC_CTYPE"] = "UTF-8" }
        env["HOME"] = configuration.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["SHELL"] = shell
        env["FOOFOIL_TERMINAL_ID"] = terminalID
        if let tools = Bundle.main.executableURL?.deletingLastPathComponent().path {
            env["PATH"] = tools + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        }
        let script = directory.appendingPathComponent("startup")
        do {
            try Self.write(configuration.startupCommands + "\n", to: script)
            let tools = Bundle.main.executableURL?.deletingLastPathComponent().path ?? "/usr/bin"
            let sourceScript = "\nreadonly FOOFOIL_TERMINAL_ID=\(Self.quote(terminalID))\nexport FOOFOIL_TERMINAL_ID\nexport PATH=\(Self.quote(tools)):\"$PATH\"\nbuiltin source \(Self.quote(script.path))\n"
            if URL(fileURLWithPath: shell).lastPathComponent == "zsh" {
                // .zshenv 和 .zshrc 仍读取用户自己的文件；临时 ZDOTDIR 只负责选择启动钩子。
                let original = env["ZDOTDIR"] ?? env["HOME"]!
                try Self.write("ZDOTDIR=\(Self.quote(original))\n[[ -r \"$ZDOTDIR/.zshenv\" ]] && builtin source \"$ZDOTDIR/.zshenv\"\nFOOFOIL_USER_ZDOTDIR=$ZDOTDIR\nZDOTDIR=\(Self.quote(directory.path))\n", to: directory.appendingPathComponent(".zshenv"))
                try Self.write("ZDOTDIR=$FOOFOIL_USER_ZDOTDIR\nunset FOOFOIL_USER_ZDOTDIR\n[[ -r \"$ZDOTDIR/.zshrc\" ]] && builtin source \"$ZDOTDIR/.zshrc\"\n" + sourceScript, to: directory.appendingPathComponent(".zshrc"))
                env["ZDOTDIR"] = directory.path
                arguments = ["-i"]
            } else {
                let rc = directory.appendingPathComponent("bashrc")
                try Self.write("[[ -r \"$HOME/.bashrc\" ]] && builtin source \"$HOME/.bashrc\"\n" + sourceScript, to: rc)
                arguments = ["--noprofile", "--rcfile", rc.path, "-i"]
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        environment = env
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func write(_ value: String, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else { throw AgentFailure("CLI_IO_ERROR") }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
