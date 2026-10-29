import Foundation

/// 使用 Shell 原生启动入口，在同一个交互式 Shell 内运行初始化，避免提示符识别与输入注入竞争。
nonisolated struct TerminalBootstrap {
    let directory: URL
    let shell: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String

    init(configuration: TerminalLaunchConfiguration, terminalID: String) throws {
        if let ssh = configuration.ssh {
            guard ssh.host.range(of: "^[A-Za-z0-9_:][A-Za-z0-9_.:-]*$", options: .regularExpression) != nil,
                  ssh.username.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil,
                  (1...65535).contains(ssh.port),
                  configuration.startupCommands.utf8.count <= 32_768,
                  !configuration.startupCommands.contains("\0"), configuration.environment.count <= 128,
                  configuration.environment.allSatisfy({ key, value in
                      key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
                          && !key.hasPrefix("FOOFOIL_") && !value.contains("\0") && value.utf8.count <= 8192
                  }), !(configuration.workingDirectory ?? "").contains("\0") else { throw AgentFailure("INVALID_ARGUMENTS") }
            shell = "/usr/bin/ssh"
            workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-shell-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var commands = [String]()
            if let path = configuration.workingDirectory, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commands.append("cd -- \(Self.quote(path)) || exit 1")
            }
            commands += configuration.environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(Self.quote($0.value))" }
            commands.append(configuration.startupCommands)
            // 只有远端目录和初始化完成后才通知宿主写入历史。
            commands.append("printf '\\033]777;foofoil-ready-\(terminalID)\\007'")
            // 远端登录 shell 执行初始化后，以交互 shell 继承目录和导出的环境。
            commands.append("exec \"${SHELL:-/bin/sh}\" -i")
            arguments = ["-tt", "-p", String(ssh.port), "-l", ssh.username, "--", ssh.host, commands.joined(separator: "\n")]
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            environment = env
            return
        }
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
                // 登录 Shell 负责系统 PATH 初始化；临时 ZDOTDIR 转发用户配置，并在 .zlogin 后执行启动命令。
                let original = env["ZDOTDIR"] ?? env["HOME"]!
                try Self.write("ZDOTDIR=\(Self.quote(original))\n[[ -r \"$ZDOTDIR/.zshenv\" ]] && builtin source \"$ZDOTDIR/.zshenv\"\nFOOFOIL_USER_ZDOTDIR=$ZDOTDIR\nZDOTDIR=\(Self.quote(directory.path))\n", to: directory.appendingPathComponent(".zshenv"))
                for name in [".zprofile", ".zshrc"] {
                    try Self.write("ZDOTDIR=$FOOFOIL_USER_ZDOTDIR\n[[ -r \"$ZDOTDIR/\(name)\" ]] && builtin source \"$ZDOTDIR/\(name)\"\nFOOFOIL_USER_ZDOTDIR=$ZDOTDIR\nZDOTDIR=\(Self.quote(directory.path))\n", to: directory.appendingPathComponent(name))
                }
                try Self.write("ZDOTDIR=$FOOFOIL_USER_ZDOTDIR\nunset FOOFOIL_USER_ZDOTDIR\n[[ -r \"$ZDOTDIR/.zlogin\" ]] && builtin source \"$ZDOTDIR/.zlogin\"\n" + sourceScript, to: directory.appendingPathComponent(".zlogin"))
                env["ZDOTDIR"] = directory.path
                arguments = ["-l", "-i"]
            } else {
                let rc = directory.appendingPathComponent("bashrc")
                // 自定义 --rcfile 不经过 /etc/profile；先加载 macOS 标准命令路径，再交给用户配置。
                try Self.write("if [[ -x /usr/libexec/path_helper ]]; then eval \"$(/usr/libexec/path_helper -s)\"; fi\n[[ -r \"$HOME/.bashrc\" ]] && builtin source \"$HOME/.bashrc\"\n" + sourceScript, to: rc)
                arguments = ["--noprofile", "--rcfile", rc.path, "-i"]
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        environment = env
    }

    static func readyMarker(_ terminalID: String) -> [UInt8] {
        Array("\u{1b}]777;foofoil-ready-\(terminalID)\u{7}".utf8)
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func write(_ value: String, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else { throw AgentFailure("CLI_IO_ERROR") }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
