import SwiftUI
import Foundation
import Combine

/// 开关直接反映文件状态；后台操作完成后统一刷新，共享目录不会出现互相矛盾的开关。
@MainActor
final class AgentIntegrationSettingsModel: ObservableObject {
    @Published private(set) var targets: [AgentIntegration.Target] = []
    @Published private(set) var isChecking = true
    @Published private(set) var pendingAgent: String?
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var cliInstallation: AgentIntegration.CLIInstallation?
    @Published private(set) var isInstallingCLI = false
    @Published private(set) var cliError: String?
    @Published private(set) var cliFeedbackKey: String?
    private var pendingPath: String?
    private var pendingValue = false
    private var refreshing = false
    private var generation: UInt64 = 0
    private var feedbackGeneration: UInt64 = 0
    private let integration: AgentIntegration
    private let cliSource: URL

    init(integration: AgentIntegration = AgentIntegration(), cliSource: URL? = nil) {
        self.integration = integration
        self.cliSource = cliSource ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/foil")
    }

    /// 共用同一安装路径的 Agent 只呈现一个“通用”开关，成员从实际目录规则生成。
    var displayedTargets: [AgentIntegration.Target] {
        guard let common = targets.first(where: \.shared_target) else { return targets }
        return targets.filter { $0.shared_target || $0.path != common.path }
    }

    var commonAgentNames: String {
        guard let common = targets.first(where: \.shared_target) else { return "" }
        return ListFormatter.localizedString(byJoining: targets.filter { !$0.shared_target && $0.agent != "omp" && $0.path == common.path }.map(\.display_name))
    }

    var canChangeSkills: Bool { cliInstallation?.canUse == true && !isChecking && !isInstallingCLI && pendingAgent == nil }

    var cliStatusKey: String {
        switch cliInstallation?.state {
        case "installed", "unregistered": "Agent CLI Status Installed"
        case "external": "Agent CLI Status External"
        case "outdated": "Agent CLI Status Outdated"
        case "not_executable": "Agent CLI Status Not Executable"
        case "modified": "Agent CLI Status Conflict"
        case "unreadable": "Agent CLI Status Unreadable"
        case "missing": "Agent CLI Status Missing"
        default: "Agent CLI Status Checking"
        }
    }

    /// 安装反馈仅属于本次设置窗口会话；重开后，旧任务也不能恢复成功提示。
    func clearInstallationFeedback() {
        feedbackGeneration &+= 1
        cliFeedbackKey = nil
    }

    func installCLI() async {
        guard !isInstallingCLI, pendingAgent == nil else { return }
        generation &+= 1
        isInstallingCLI = true
        cliError = nil
        cliFeedbackKey = nil
        let expectedFeedbackGeneration = feedbackGeneration
        let reinstalling = cliInstallation?.fileExists == true || cliInstallation?.canUse == true
        let integration = integration
        let source = cliSource
        let snapshot = await Task.detached(priority: .utility) {
            var failure: String?
            var skillFailure: String?
            do { skillFailure = try integration.installCLIForSettings(source: source) }
            catch { failure = (error as? IntegrationError)?.code ?? "INSTALL_FAILED" }
            return (integration.targets(), integration.cliInstallation(source: source), failure, skillFailure)
        }.value
        targets = snapshot.0
        cliInstallation = snapshot.1
        cliError = snapshot.2 ?? (snapshot.1.canUse ? nil : "CLI_UNAVAILABLE")
        if let skillFailure = snapshot.3 { errors["shared"] = skillFailure }
        if cliError == nil, feedbackGeneration == expectedFeedbackGeneration { cliFeedbackKey = reinstalling ? "Agent CLI Reinstalled" : "Agent CLI Installed Successfully" }
        isInstallingCLI = false
        isChecking = false
    }

    func isEnabled(_ target: AgentIntegration.Target) -> Bool {
        if target.path == pendingPath { return pendingValue }
        return ["installed", "update_available", "modified"].contains(target.skill_state)
    }

    func refresh() async {
        guard !refreshing, pendingAgent == nil, !isInstallingCLI else { return }
        refreshing = true
        let expected = generation
        let integration = integration
        let source = cliSource
        let snapshot = await Task.detached(priority: .utility) { (integration.targets(), integration.cliInstallation(source: source)) }.value
        // 用户在检查期间操作开关时，旧快照不能覆盖刚写入的结果。
        if generation == expected {
            for target in snapshot.0 where targets.first(where: { $0.agent == target.agent })?.skill_state != target.skill_state {
                errors[target.agent] = nil
            }
            targets = snapshot.0
            cliInstallation = snapshot.1
        }
        refreshing = false
        isChecking = false
    }

    func setEnabled(_ enabled: Bool, agent: String) async {
        guard canChangeSkills, let target = targets.first(where: { $0.agent == agent }) else { return }
        generation &+= 1
        pendingPath = target.path
        pendingValue = enabled
        pendingAgent = agent
        errors[agent] = nil
        let integration = integration
        let cliSource = cliSource
        let snapshot = await Task.detached(priority: .utility) {
            var code: String?
            do { try integration.setSkillEnabled(enabled, agent: agent, cliSource: cliSource, requireInstalledCLI: true) }
            catch { code = (error as? IntegrationError)?.code ?? "INSTALL_FAILED" }
            return (integration.targets(), code, integration.cliInstallation(source: cliSource))
        }.value
        targets = snapshot.0
        errors[agent] = snapshot.1
        cliInstallation = snapshot.2
        pendingPath = nil
        pendingAgent = nil
    }

    func errorKey(for target: AgentIntegration.Target) -> String? {
        if let code = errors[target.agent] {
            return code == "INSTALL_CONFLICT" ? "Agent Toggle Conflict" : "Agent Toggle Failed"
        }
        switch target.skill_state {
        case "conflict", "modified": return "Agent Toggle Conflict"
        case "unreadable": return "Agent Toggle Unreadable"
        default: return nil
        }
    }
}

struct AgentIntegrationSettingsView: View {
    @ObservedObject var model: AgentIntegrationSettingsModel

    private var cliSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("foil").font(.headline)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NSLocalizedString(model.cliStatusKey, comment: "")).foregroundStyle(.secondary)
                        Button("Agent CLI Commands Link") {
                            (NSApp.delegate as? AppDelegate)?.showFoilCommandsOverviewAction()
                        }
                        .buttonStyle(.link)
                    }
                    .font(.caption)
                }
                Spacer()
                Button {
                    Task { await model.installCLI() }
                } label: {
                    Text(NSLocalizedString(model.cliInstallation?.fileExists == true || model.cliInstallation?.canUse == true ? "Agent CLI Reinstall Button" : "Agent CLI Install Button", comment: ""))
                }
                .disabled(model.isChecking || model.isInstallingCLI || model.pendingAgent != nil)
                if model.isInstallingCLI { ProgressView().controlSize(.small) }
            }
            if let cli = model.cliInstallation {
                Text(String(format: NSLocalizedString("Agent CLI Install Location Format", comment: ""), cli.state == "external" ? (cli.commandPath ?? cli.path) : cli.path))
                    .font(.caption).textSelection(.enabled)
                if !cli.isOnPath {
                    if let command = cli.commandPath {
                        Text(String(format: NSLocalizedString("Agent CLI Shadowed Format", comment: ""), command)).font(.caption)
                    } else if cli.canUse { Text("Agent CLI Not On PATH").font(.caption) }
                }
            }
            if let error = model.cliError {
                Text(NSLocalizedString(error == "INSTALL_CONFLICT" ? "Agent CLI Install Conflict" : "Agent CLI Install Failed", comment: "")).font(.caption)
            } else if let key = model.cliFeedbackKey { Text(NSLocalizedString(key, comment: "")).font(.caption) }
        } header: { Text("Agent CLI Section") }
    }

    var body: some View {
        Form {
            cliSection
            if !model.isChecking, model.cliInstallation?.canUse != true {
                Text("Agent CLI Required For Skills").font(.callout)
            }
            Text("Agent Toggle Introduction").font(.callout)
            if model.targets.isEmpty, model.isChecking { ProgressView() }
            ForEach(model.displayedTargets, id: \.agent) { target in
                HStack {
                    Toggle(isOn: Binding(
                        get: { model.isEnabled(target) },
                        set: { enabled in Task { await model.setEnabled(enabled, agent: target.agent) } }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.shared_target ? NSLocalizedString("Agent Common Group", comment: "") : target.display_name)
                            if target.shared_target {
                                Text(String(format: NSLocalizedString("Agent Common Includes Format", comment: ""), model.commonAgentNames))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let key = model.errorKey(for: target) {
                                Text(NSLocalizedString(key, comment: ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!model.canChangeSkills)
                    .accessibilityLabel(Text(target.shared_target ? NSLocalizedString("Agent Common Group", comment: "") : target.display_name))
                    .help(target.path)
                    if model.pendingAgent == target.agent { ProgressView().controlSize(.small) }
                }
            }
            Text("Agent Toggle Reload Note").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        // 初始检查时列表尚为空；固定面板视口，避免异步载入改变 Form 的初始滚动布局。
        .frame(width: SettingsWindowMetrics.width, height: SettingsWindowMetrics.maxHeight, alignment: .top)
        .task {
            // 页面可见期间自动检查外部安装、删除与修改；离开页面即取消轮询。
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}
