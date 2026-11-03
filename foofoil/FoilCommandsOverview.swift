import Foundation

@MainActor
enum FoilCommandsOverview {
    nonisolated static let sourceFingerprint = "foofoil:foil-commands-overview"

    /// 帮助正文保留本地化工作流，命令语法直接取自 CLI 使用的 catalog。
    static func markdown(bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "FoilCommands", withExtension: "md"),
              let template = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let groups: [(String, [String])] = [
            ("Foil CLI Group Opening", ["open", "list", "inspect", "capabilities", "wait"]),
            ("Foil CLI Group Windows", ["reveal", "focus", "hide", "close", "set", "screens", "window.frame"]),
            ("Foil CLI Group Reading", ["read", "outline", "items", "search", "navigate", "items.select"]),
            ("Foil CLI Group Media", ["media.status", "media.play", "media.pause", "media.seek", "media.next", "media.previous", "media.volume", "media.mute", "media.mode", "media.select"]),
            ("Foil CLI Group Presentation", ["show", "update"]),
            ("Foil CLI Group Terminal", ["terminal.create"]),
            ("Foil CLI Group Configuration", ["config.list", "config.get", "config.set", "permissions.status", "settings.open"]),
            ("Foil CLI Group History", ["history.search", "history.open", "export"]),
            ("Foil CLI Group Integration", ["install", "uninstall", "agent.setup", "agent.status", "skill.install", "skill.check", "skill.update", "skill.uninstall", "doctor"])
        ]
        func localized(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
        func table(_ keys: [String]) -> String {
            let rows = keys.compactMap { key -> String? in
                guard let definition = AgentCommandCatalog.commands[key] else { return nil }
                let usage = ("foil " + definition.usage).replacingOccurrences(of: "|", with: "\\|")
                let description = bundle.localizedString(forKey: "Foil CLI Command " + key,
                                                        value: localized("Foil CLI Command More Help"), table: nil)
                return "| `\(usage)` | \(description) |"
            }
            return "| \(localized("Foil CLI Command Column")) | \(localized("Foil CLI Description Column")) |\n| --- | --- |\n" + rows.joined(separator: "\n")
        }
        var sections = groups.map { "## " + localized($0.0) + "\n\n" + table($0.1) }
        let grouped = Set(groups.flatMap { $0.1 })
        let remaining = Set(AgentCommandCatalog.commands.keys).subtracting(grouped).sorted()
        if !remaining.isEmpty { sections.append("## " + localized("Foil CLI Group Other") + "\n\n" + table(remaining)) }
        return template.replacingOccurrences(of: "{{command_tables}}", with: sections.joined(separator: "\n\n"))
    }
}

extension AppState {
    func openFoilCommandsOverview() {
        openText(FoilCommandsOverview.markdown(), isMarkdown: true)
        sourceFingerprint = FoilCommandsOverview.sourceFingerprint
        originalImageName = NSLocalizedString("Foil Commands Overview", comment: "") + ".md"
        saveState()
    }
}
