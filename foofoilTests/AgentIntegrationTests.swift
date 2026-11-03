import Foundation
import Testing
@testable import foofoil

struct AgentIntegrationTests {
    @Test func installUpdateConflictAndUninstall() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let integration = AgentIntegration(home: home)
        let destinations = try integration.destinations(agent: "codex", path: nil, detected: false)
        #expect(destinations.count == 1)
        #expect(try integration.manage("install", destinations: destinations).first?.status == "ready")
        let file = URL(fileURLWithPath: destinations[0].0).appendingPathComponent("SKILL.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentIntegration.skill)
        #expect(try integration.manage("update").first?.status == "ready")
        try Data("user content".utf8).write(to: file)
        #expect(try integration.manage("update").first?.error == "INSTALL_CONFLICT")
        #expect(try integration.manage("uninstall").first?.error == "INSTALL_CONFLICT")
        #expect(try String(contentsOf: file, encoding: .utf8) == "user content")
        try Data(AgentIntegration.skill.utf8).write(to: file)
        #expect(try integration.manage("uninstall").first?.status == "ready")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try integration.installations().isEmpty)
    }
    @Test func unmanagedFileAndSymlinkAreProtected() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let integration = AgentIntegration(home: home)
        let root = home.appendingPathComponent("custom/foofoil")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("SKILL.md")
        try Data("user skill".utf8).write(to: file)
        #expect(try integration.manage("install", destinations: [(root.path, "custom")]).first?.error == "INSTALL_CONFLICT")
        let alias = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(try integration.manage("install", destinations: [(alias.path, "custom")]).first?.error == "INSTALL_CONFLICT")
        #expect(throws: IntegrationError.self) { try integration.destinations(agent: nil, path: nil, detected: false) }
        #expect(throws: IntegrationError.self) { try integration.destinations(agent: "codex", path: root.path, detected: false) }
    }
    @Test func sharedPhysicalInstallKeepsOtherReferences() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let integration = AgentIntegration(home: home)
        let codex = try integration.destinations(agent: "codex", path: nil, detected: false)
        let shared = try integration.destinations(agent: "shared", path: nil, detected: false)
        #expect(codex[0].0 == shared[0].0)
        _ = try integration.manage("install", destinations: codex)
        _ = try integration.manage("install", destinations: shared)
        _ = try integration.manage("uninstall", destinations: codex)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: shared[0].0).appendingPathComponent("SKILL.md").path))
        #expect(try integration.installations().first?.agents == ["shared"])
        #expect(try integration.manage("uninstall", destinations: codex).first?.error == "NOT_INSTALLED")
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: shared[0].0).appendingPathComponent("SKILL.md").path))
    }
    @Test func cliLifecycleProtectsForeignCommands() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-install-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = home.appendingPathComponent("source")
        try Data("cli-v2".utf8).write(to: source)
        let integration = AgentIntegration(home: home)
        #expect(integration.cliStatus(source: source) == "missing")
        try integration.installCLI(source: source)
        #expect(integration.cliStatus(source: source) == "installed")
        try Data("cli-v3".utf8).write(to: source)
        #expect(integration.cliStatus(source: source) == "outdated")
        try integration.installCLI(source: source)
        let installed = home.appendingPathComponent(".local/bin/foil")
        try Data("foreign".utf8).write(to: installed)
        #expect(integration.cliStatus(source: source) == "modified")
        #expect(throws: IntegrationError.self) { try integration.installCLI(source: source) }
        #expect(throws: IntegrationError.self) { try integration.installCLI(source: source, removing: true) }
        #expect(try String(contentsOf: installed, encoding: .utf8) == "foreign")
        try Data("cli-v3".utf8).write(to: installed)
        try integration.installCLI(source: source, removing: true)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
    }

    @Test func supportedAdaptersResolveVerifiedDirectoriesAndAliases() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("adapters-\(UUID())")
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        let roots = ["opencode": ".config/opencode/skills", "pi": ".agents/skills", "omp": ".agents/skills", "workbuddy": ".workbuddy/skills", "qoder": ".qoder/skills", "qoder-cn": ".qoder-cn/skills", "kimi": ".agents/skills", "zcode": ".agents/skills", "zed": ".agents/skills"]
        for (agent, root) in roots {
            let destination = try #require(integration.destinations(agent: agent, path: nil, detected: false).first)
            #expect(destination.0 == home.appendingPathComponent(root + "/foofoil").path)
            #expect(destination.1 == agent)
        }
        for alias in ["opencode-v1", "opencode-v2"] {
            let destination = try #require(integration.destinations(agent: alias, path: nil, detected: false).first)
            #expect(destination.1 == "opencode")
            #expect(destination.0 == home.appendingPathComponent(".config/opencode/skills/foofoil").path)
        }
        #expect(integration.targets().first(where: { $0.agent == "opencode" })?.display_name == "OpenCode (v1 / v2)")
    }

    @Test func skillInstallationDoesNotClaimAgentProgramIsInstalled() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        let before = try #require(integration.targets().first { $0.agent == "pi" })
        #expect(!before.detected)
        #expect(before.skill_state == "not_installed")
        #expect(before.detectionLocalizationKey == "Agent Program Not Detected")
        _ = try integration.manage("install", destinations: integration.destinations(agent: "pi", path: nil, detected: false))
        let after = try #require(integration.targets().first { $0.agent == "pi" })
        #expect(after.skill_state == "installed")
        #expect(after.skillStatusLocalizationKey == "Agent Skill Installed")
        #expect(!after.executable_detected && !after.application_detected && !after.configuration_detected)
        #expect(!after.detected)
        #expect(after.detectionLocalizationKey == "Agent Program Not Detected")
        let codex = try #require(integration.targets().first { $0.agent == "codex" })
        #expect(codex.skill_state == "installed")
        #expect(!codex.detected)
    }

    @Test func detectionDistinguishesConfigurationExecutableAndApplication() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-detect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let applications = home.appendingPathComponent("Applications")
        let bin = home.appendingPathComponent("bin")
        try fm.createDirectory(at: applications.appendingPathComponent("WorkBuddy.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = bin.appendingPathComponent("qodercli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: command)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        try fm.createDirectory(at: home.appendingPathComponent(".zcode"), withIntermediateDirectories: true)
        let integration = AgentIntegration(home: home, environment: ["PATH": bin.path], applicationDirectories: [applications])
        let targets = integration.targets()
        let workbuddy = try #require(targets.first { $0.agent == "workbuddy" })
        #expect(workbuddy.application_detected && !workbuddy.configuration_detected)
        #expect(workbuddy.skill_state == "not_installed")
        #expect(workbuddy.detectionLocalizationKey == "Agent Program Detected")
        #expect(targets.first { $0.agent == "qoder" }?.executable_detected == true)
        #expect(targets.first { $0.agent == "zcode" }?.detectionLocalizationKey == "Agent Configuration Only")
        let detected = try integration.destinations(agent: nil, path: nil, detected: true)
        #expect(Set(detected.map { $0.1 }) == ["workbuddy", "qoder", "zcode"])
        #expect(!detected.contains { $0.1 == "shared" })
    }

    @Test func customConfigurationRootsAndSharedReferencesAreRespected() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-roots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let custom = home.appendingPathComponent("custom-opencode")
        let xdg = home.appendingPathComponent("xdg")
        let integration = AgentIntegration(home: home, environment: ["OPENCODE_CONFIG_DIR": custom.path, "XDG_CONFIG_HOME": xdg.path], applicationDirectories: [])
        #expect(try integration.destinations(agent: "opencode-v2", path: nil, detected: false).first?.0 == custom.appendingPathComponent("skills/foofoil").path)
        #expect(try integration.destinations(agent: "zed", path: nil, detected: false).first?.0 == home.appendingPathComponent(".agents/skills/foofoil").path)
        let pi = try integration.destinations(agent: "pi", path: nil, detected: false)
        let zed = try integration.destinations(agent: "zed", path: nil, detected: false)
        _ = try integration.manage("install", destinations: pi + zed)
        #expect(try integration.installations().count == 1)
        _ = try integration.manage("uninstall", destinations: pi)
        #expect(try integration.installations().first?.agents == ["zed"])
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: zed[0].0).appendingPathComponent("SKILL.md").path))
    }

    @Test @MainActor func settingsToggleWritesImmediatelyAndSynchronizesSharedRows() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("toggle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = home.appendingPathComponent("foil-source")
        try Data("test CLI".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        try integration.installCLI(source: source)
        let model = AgentIntegrationSettingsModel(integration: integration, cliSource: source)
        await model.refresh()
        let cursor = try #require(model.targets.first { $0.agent == "cursor" })
        #expect(!model.isEnabled(cursor))
        await model.setEnabled(true, agent: "cursor")
        #expect(model.pendingAgent == nil)
        #expect(model.errors["cursor"] == nil)
        #expect(model.targets.filter { ["cursor", "codex", "zed"].contains($0.agent) }.allSatisfy { model.isEnabled($0) })
        let file = home.appendingPathComponent(".agents/skills/foofoil/SKILL.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentIntegration.skill)
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/bin/foil").path))
        await model.setEnabled(true, agent: "workbuddy")
        await model.setEnabled(false, agent: "codex")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(model.targets.filter { ["cursor", "codex", "zed"].contains($0.agent) }.allSatisfy { !model.isEnabled($0) })
        #expect(model.isEnabled(try #require(model.targets.first { $0.agent == "workbuddy" })))
        #expect(try integration.installations().map(\.agents) == [["workbuddy"]])
    }

    @Test @MainActor func settingsTogglePreservesConflictsAndReturnsToActualState() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("toggle-conflict-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".claude/skills/foofoil")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("SKILL.md")
        try Data("user-owned instructions".utf8).write(to: file)
        let source = home.appendingPathComponent("foil-source")
        try Data("test CLI".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        try integration.installCLI(source: source)
        let model = AgentIntegrationSettingsModel(integration: integration, cliSource: source)
        await model.refresh()
        await model.setEnabled(true, agent: "claude")
        #expect(model.errors["claude"] == "INSTALL_CONFLICT")
        #expect(!model.isEnabled(try #require(model.targets.first { $0.agent == "claude" })))
        #expect(try String(contentsOf: file, encoding: .utf8) == "user-owned instructions")
        try FileManager.default.removeItem(at: file)
        await model.setEnabled(true, agent: "claude")
        try Data("user-modified instructions".utf8).write(to: file)
        await model.refresh()
        await model.setEnabled(false, agent: "claude")
        #expect(model.errors["claude"] == "INSTALL_CONFLICT")
        #expect(model.isEnabled(try #require(model.targets.first { $0.agent == "claude" })))
        #expect(try String(contentsOf: file, encoding: .utf8) == "user-modified instructions")
    }

    @Test @MainActor func settingsRefreshObservesExternalInstallationAndRemoval() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("toggle-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        let model = AgentIntegrationSettingsModel(integration: integration, cliSource: home.appendingPathComponent("unused"))
        await model.refresh()
        let destinations = try integration.destinations(agent: "opencode", path: nil, detected: false)
        _ = try integration.manage("install", destinations: destinations)
        await model.refresh()
        #expect(model.isEnabled(try #require(model.targets.first { $0.agent == "opencode" })))
        _ = try integration.manage("uninstall", destinations: destinations)
        await model.refresh()
        #expect(!model.isEnabled(try #require(model.targets.first { $0.agent == "opencode" })))
        #expect(model.isChecking == false)
    }

    @Test @MainActor func commonGroupContainsSharedAgentsAndControlsOneInstallation() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("common-toggle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = home.appendingPathComponent("foil-source")
        try Data("test CLI".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        try integration.installCLI(source: source)
        let model = AgentIntegrationSettingsModel(integration: integration, cliSource: source)
        await model.refresh()
        #expect(model.displayedTargets.map(\.agent) == ["shared", "claude", "opencode", "workbuddy", "qoder", "qoder-cn"])
        for name in ["Codex", "Cursor", "Pi", "Kimi Code", "ZCode", "Zed Agent"] {
            #expect(model.commonAgentNames.contains(name))
        }
        #expect(!model.commonAgentNames.contains("Claude Code"))
        #expect(!model.commonAgentNames.contains("Oh My Pi"))
        await model.setEnabled(true, agent: "shared")
        #expect(model.isEnabled(try #require(model.displayedTargets.first)))
        #expect(try integration.installations().count == 1)
        await model.setEnabled(false, agent: "shared")
        #expect(!model.isEnabled(try #require(model.displayedTargets.first)))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/foofoil/SKILL.md").path))
    }

    @Test @MainActor func cliInstallAndReinstallEnableGeneral() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-first-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = home.appendingPathComponent("source")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        let model = AgentIntegrationSettingsModel(integration: integration, cliSource: source)
        await model.refresh()
        #expect(model.cliInstallation?.state == "missing")
        #expect(!model.canChangeSkills)
        await model.setEnabled(true, agent: "shared")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/foofoil/SKILL.md").path))
        await model.installCLI()
        #expect(model.cliError == nil)
        #expect(model.cliInstallation?.state == "installed")
        #expect(model.canChangeSkills)
        #expect(model.isEnabled(try #require(model.displayedTargets.first)))
        await model.setEnabled(false, agent: "shared")
        await model.installCLI()
        #expect(model.cliFeedbackKey == "Agent CLI Reinstalled")
        model.clearInstallationFeedback()
        await model.refresh()
        #expect(model.cliFeedbackKey == nil)
        #expect(model.cliInstallation?.state == "installed")
        await model.installCLI()
        #expect(model.cliFeedbackKey == "Agent CLI Reinstalled")
        #expect(model.isEnabled(try #require(model.displayedTargets.first)))
        await model.setEnabled(false, agent: "shared")
        try integration.installCLI(source: source, removing: true)
        await model.refresh()
        #expect(!model.canChangeSkills)
        await model.installCLI()
        #expect(model.isEnabled(try #require(model.displayedTargets.first)))
    }

    @Test func cliDetectionSeparatesPATHShadowingAndExecutableState() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let source = home.appendingPathComponent("source")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let integration = AgentIntegration(home: home, environment: ["PATH": bin.path], applicationDirectories: [])
        try integration.installCLI(source: source)
        #expect(integration.cliInstallation(source: source).isOnPath)
        let other = home.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let foreign = other.appendingPathComponent("foil")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: foreign)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: foreign.path)
        let shadowed = AgentIntegration(home: home, environment: ["PATH": other.path + ":" + bin.path], applicationDirectories: [])
        #expect(shadowed.cliInstallation(source: source).commandPath == foreign.path)
        #expect(!shadowed.cliInstallation(source: source).isOnPath)
        #expect(shadowed.cliInstallation(source: source).canUse)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bin.appendingPathComponent("foil").path)
        #expect(integration.cliInstallation(source: source).state == "not_executable")
        #expect(!integration.cliInstallation(source: source).canUse)
    }

    @Test @MainActor func cliInstallConflictKeepsAgentSwitchesDisabled() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-conflict-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let file = bin.appendingPathComponent("foil")
        try Data("user command".utf8).write(to: file)
        let source = home.appendingPathComponent("source")
        try Data("bundled CLI".utf8).write(to: source)
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        let model = AgentIntegrationSettingsModel(integration: integration, cliSource: source)
        await model.refresh()
        #expect(!model.canChangeSkills)
        await model.installCLI()
        #expect(model.cliError == "INSTALL_CONFLICT")
        #expect(!model.canChangeSkills)
        #expect(try String(contentsOf: file, encoding: .utf8) == "user command")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/foofoil/SKILL.md").path))
    }

    @Test func cliDetectionRecognizesExternalCopiesAndReinstallAdoptsMatchingLinks() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-external-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let manual = home.appendingPathComponent("manual")
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        let source = manual.appendingPathComponent("foil")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        let integration = AgentIntegration(home: home, environment: ["PATH": manual.path], applicationDirectories: [])
        let external = integration.cliInstallation(source: source)
        #expect(external.state == "external")
        #expect(external.canUse && external.isOnPath)
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let installed = bin.appendingPathComponent("foil")
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: source)
        #expect(integration.cliInstallation(source: source).state == "unregistered")
        #expect(try integration.installCLIForSettings(source: source) == nil)
        #expect(integration.cliInstallation(source: source).state == "installed")
        #expect(try FileManager.default.attributesOfItem(atPath: installed.path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOf: source, encoding: .utf8) == "#!/bin/sh\nexit 0\n")
    }

    @Test func firstApplicationLaunchInstallsGeneralWithoutCLIAndPreservesLaterRemoval() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("app-default-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        let file = home.appendingPathComponent(".agents/skills/foofoil/SKILL.md")
        #expect(try integration.initializeDefaultSharedSkill() == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentIntegration.skill)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/bin/foil").path))
        _ = try integration.manage("uninstall", destinations: integration.destinations(agent: "shared", path: nil, detected: false), removeSharedInstallation: true)
        #expect(try integration.initializeDefaultSharedSkill() == nil)
        let source = home.appendingPathComponent("source")
        try Data("cli".utf8).write(to: source)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try integration.installCLIWithDefaults(source: source) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func commandLineInstallInitializesGeneralAndProtectsConflicts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cli-default-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        let file = home.appendingPathComponent(".agents/skills/foofoil/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user skill".utf8).write(to: file)
        #expect(try integration.initializeDefaultSharedSkill() == "INSTALL_CONFLICT")
        #expect(try String(contentsOf: file, encoding: .utf8) == "user skill")
        try FileManager.default.removeItem(at: file)
        let source = home.appendingPathComponent("source")
        try Data("cli".utf8).write(to: source)
        #expect(try integration.installCLIWithDefaults(source: source, directory: home.appendingPathComponent("custom-bin")) == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentIntegration.skill)
    }

    @Test func existingSettingsInitializationPreservesDisabledGeneral() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-default-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let integration = AgentIntegration(home: home, environment: [:], applicationDirectories: [])
        try FileManager.default.createDirectory(at: integration.support, withIntermediateDirectories: true)
        try Data().write(to: integration.support.appendingPathComponent("cli-setup-completed"))
        #expect(try integration.initializeDefaultSharedSkill() == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".agents/skills/foofoil/SKILL.md").path))
    }

    @Test func distributedSkillMatchesBundledInstallerEntry() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let skill = try String(contentsOf: repository.appendingPathComponent("skills/foofoil/SKILL.md"), encoding: .utf8)
        #expect(skill.trimmingCharacters(in: .newlines) == AgentIntegration.skill)
    }

}
