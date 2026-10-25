import AppKit
import Testing
import Darwin
import SwiftTerm
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct TerminalFoilTests {
    private final class MenuTarget: NSObject {
        var invoked = false
        @objc func move(_ sender: Any?) { invoked = true }
    }

    @Test func historyMenuCanRestoreHiddenOutput() {
        let state = AppState(isIncognito: true)
        state.terminalSession = TerminalSession(configuration: .init(), previousOutput: "retained output")
        let controller = FloatingWindowController(appState: state)
        let delegate = AppDelegate()
        delegate.windowControllers = [controller]
        delegate.activeWindowProvider = { controller.window }
        let item = NSMenuItem(title: "", action: #selector(AppDelegate.toggleTerminalHistoryAction), keyEquivalent: "")
        #expect(delegate.validateMenuItem(item))
        delegate.toggleTerminalHistoryAction()
        #expect(state.terminalSession?.isPreviousOutputHidden == true)
        delegate.toggleTerminalHistoryAction()
        #expect(state.terminalSession?.isPreviousOutputHidden == false)
        state.terminalSession?.clearPreviousOutput()
        #expect(!delegate.validateMenuItem(item))
    }

    @Test func menuShortcutsReachMenuWithTerminalFocus() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let state = AppState(isIncognito: true)
        state.prepareTerminal(.init(), start: false)
        let controller = FloatingWindowController(appState: state)
        defer { controller.close() }
        let window = try #require(controller.window)
        let session = try #require(state.terminalSession)
        window.contentView = session.view
        window.makeFirstResponder(session.view)
        #expect(window.firstResponder === session.view)
        let definitions = KeyboardShortcutCatalog.window.filter { $0.id.hasPrefix("window.") }
            + [try #require(KeyboardShortcutCatalog.definition(withID: "terminal.clear"))]
        for definition in definitions {
            let shortcut = try #require(KeyboardShortcutStore.shared.shortcut(for: definition))
            let target = MenuTarget()
            let menu = NSMenu()
            menu.autoenablesItems = false
            let item = NSMenuItem(title: definition.id, action: #selector(MenuTarget.move(_:)), keyEquivalent: shortcut.keyEquivalent)
            item.keyEquivalentModifierMask = shortcut.modifiers
            item.target = target
            menu.addItem(item)
            NSApp.mainMenu = menu
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shortcut.modifiers, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: shortcut.keyEquivalent, charactersIgnoringModifiers: shortcut.keyEquivalent,
                isARepeat: false, keyCode: 0))
            #expect(window.performKeyEquivalent(with: event))
            #expect(target.invoked, "\(definition.id) should reach the window menu")
        }
    }

    @Test func clearContentRemovesScreenScrollbackAndPreviousSessionWithoutReplacingSession() throws {
        let session = TerminalSession(configuration: .init(), previousOutput: "previous session marker")
        let view = session.view
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "terminal.clear"))
        #expect(definition.defaultShortcut == KeyboardShortcut(keyEquivalent: "k", modifiers: [.command]))
        view.feed(text: String(repeating: "scrollback marker\r\n", count: 100) + "old screen marker\r\n\u{1b}[32muser@host % \u{1b}[0mecho 中文\u{1b}[2D")
        #expect(String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).contains("scrollback marker"))
        let cursor = view.getTerminal().getCursorLocation()
        let prompt = try #require(view.getTerminal().getLine(row: cursor.y)).getData()
        view.scroll(toPosition: 0)
        session.clearContent()
        #expect(view.getTerminal().getCursorLocation().x == cursor.x)
        #expect(view.getTerminal().getCursorLocation().y == 0)
        let preserved = try #require(view.getTerminal().getLine(row: 0)).getData()
        #expect(preserved.map(\.debugDescription) == prompt.map(\.debugDescription))
        #expect(preserved.map(\.attribute) == prompt.map(\.attribute))
        #expect(preserved.map(\.width) == prompt.map(\.width))
        #expect(session.view === view)
        #expect(session.state == .waiting)
        #expect(session.previousOutput == nil)
        let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        #expect(!text.contains("scrollback marker"))
        #expect(!text.contains("old screen marker"))
        let inputLine = try #require(view.getTerminal().getLine(row: 0))
            .translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: { view.getTerminal().getCharacter(for: $0) })
        #expect(inputLine == "user@host % echo 中文")
        session.clearContent()
        #expect(try #require(view.getTerminal().getLine(row: 0)).getData().map(\.debugDescription) == prompt.map(\.debugDescription))
        view.feed(text: "new output")
        #expect(String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).contains("new output"))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("export FOIL_RC_LOADED=yes\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        return root
    }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), "Terminal operation did not complete within 5 seconds")
    }

    @Test func documentStyleUpdatesTerminalWithoutReplacingItsBuffer() throws {
        let state = AppState(isIncognito: true)
        state.prepareTerminal(.init(), start: false)
        #expect(state.supportsContentBackgroundColor)
        #expect(state.supportsDocumentTextStyling)
        #expect(state.prefersMonospacedDocumentFonts)
        #expect(!state.supportsDocumentSpacing)
        #expect(state.documentFont(size: 14).isFixedPitch)
        state.documentFontName = "Menlo-Regular"
        state.textFontSize = 18
        state.backgroundColorHex = "#102030"
        state.textColorHex = "#DDEEFF"
        let session = try #require(state.terminalSession)
        session.view.feed(text: "style survivor\r\n")
        session.view.applyDocumentStyle(font: state.documentFont(size: 18),
            foregroundColor: state.documentTextColor, backgroundColor: state.contentBackgroundColor)
        #expect(session.view.font.fontName == "Menlo-Regular")
        #expect(session.view.font.pointSize == 18)
        let expectedBackgroundRed = UInt16(try #require(state.contentBackgroundColor?.usingColorSpace(.deviceRGB)).redComponent * 65535)
        #expect(session.view.getTerminal().backgroundColor.red == expectedBackgroundRed)
        #expect(session.view.nativeForegroundColor == state.documentTextColor)
        session.view.viewDidChangeEffectiveAppearance()
        #expect(session.view.getTerminal().backgroundColor.red == expectedBackgroundRed)
        #expect(String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self).contains("style survivor"))
        let config = try JSONDecoder().decode(WindowConfig.self, from: JSONEncoder().encode(state.toConfig()))
        let restored = AppState(isIncognito: true)
        #expect(restored.loadConfig(config))
        #expect(restored.documentFontName == "Menlo-Regular")
        #expect(restored.textFontSize == 18)
        #expect(restored.contentBackgroundHex == "#102030")
        session.view.applyDocumentStyle(font: state.documentFont(size: 14), foregroundColor: nil, backgroundColor: nil)
        #expect(session.view.nativeForegroundColor == .textColor)
        #expect(session.view.nativeBackgroundColor == .textBackgroundColor)
    }

    @Test func previousOutputIsBoundedReadOnlyAndExcludedFromIncognito() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let launch = TerminalLaunchConfiguration(shellPath: "/bin/zsh", workingDirectory: root.path)
        let text = String(repeating: "旧会话 output\n", count: 800) + "retained marker\0"
        let bounded = TerminalSession.boundedScrollback(text)
        #expect(bounded.split(separator: "\n").count <= 500)
        #expect(!bounded.contains("\0"))
        let unicode = TerminalSession.boundedScrollback(String(repeating: "中文", count: 100_000))
        #expect(unicode.utf8.count <= 128 * 1_024)
        #expect(!unicode.contains("�"))
        let config = WindowConfig(id: UUID(), terminalConfiguration: launch, terminalScrollback: bounded)
        let database = try HistoryDatabase(databaseURL: root.appendingPathComponent("history.sqlite3"))
        try database.upsert(config)
        let stored = try #require(try database.config(id: config.id))
        #expect(stored.terminalScrollback == bounded)
        let restored = AppState()
        #expect(restored.loadConfig(stored))
        #expect(restored.terminalSession?.previousOutput == bounded)
        #expect(restored.toConfig().terminalScrollback == bounded)
        defer { HistoryManager.shared.removeFromHistory(restored.toConfig()) }
        restored.saveState()
        #expect(HistoryRepository.shared.config(id: stored.id)?.terminalScrollback == bounded)
        let view = try #require(restored.terminalSession?.view)
        #expect(!String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self).contains("retained marker"))
        let incognito = AppState(isIncognito: true)
        #expect(incognito.loadConfig(stored))
        #expect(incognito.terminalSession?.previousOutput == nil)
        #expect(incognito.toConfig().terminalScrollback == nil)
    }

    @Test func terminalTracksLightAndDarkAppearance() async throws {
        let session = TerminalSession(configuration: .init())
        let window = NSWindow(contentRect: session.view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        window.orderFront(nil)
        defer { window.close() }
        session.view.feed(text: "浮箔 terminal appearance\r\n\u{1b}[32mgreen \u{1b}[92mbright green \u{1b}[36mcyan \u{1b}[96mbright cyan\u{1b}[0m\r\n")
        for (name, light) in [(NSAppearance.Name.aqua, true), (.darkAqua, false)] {
            window.appearance = NSAppearance(named: name)
            try await Task.sleep(for: .milliseconds(50))
            let color = session.view.getTerminal().backgroundColor
            #expect(light ? color.red > 50_000 : color.red < 25_000)
            let bitmap = try #require(session.view.bitmapImageRepForCachingDisplay(in: session.view.bounds))
            session.view.cacheDisplay(in: session.view.bounds, to: bitmap)
            let image = NSImage(size: session.view.bounds.size)
            image.addRepresentation(bitmap)
            Attachment.record(image, named: light ? "Terminal light" : "Terminal dark", as: .png)
        }
    }

    @Test func nativeStartupPreservesShellStateAndStopsBackgroundJobs() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appendingPathComponent("started")
        let continued = root.appendingPathComponent("continued")
        let childFile = root.appendingPathComponent("child")
        let command = "export FOIL_TEST_EXPORT=ok\nFOIL_TEST_LOCAL=kept\ncd \(TerminalBootstrap.quote(root.path))\nprintf '%s:%s' \"$FOIL_RC_LOADED\" \"$FOIL_TEST_EXPORT\" > \(TerminalBootstrap.quote(started.path))\nsleep 60 &\nprintf '%s' $! > \(TerminalBootstrap.quote(childFile.path))\n"
        let config = TerminalLaunchConfiguration(shellPath: "/bin/zsh", workingDirectory: root.path,
                                                 environment: ["ZDOTDIR": root.path], startupCommands: command)
        let session = TerminalSession(configuration: config)
        defer { session.stop() }
        session.start()
        try await waitFor { FileManager.default.fileExists(atPath: childFile.path) }
        #expect(try String(contentsOf: started, encoding: .utf8) == "yes:ok")
        session.view.process.send(data: Array("printf '%s:%s' \"$FOIL_TEST_LOCAL\" \"$PWD\" > \(TerminalBootstrap.quote(continued.path))\n".utf8)[...])
        try await waitFor { FileManager.default.fileExists(atPath: continued.path) }
        #expect(try String(contentsOf: continued, encoding: .utf8) == "kept:" + root.path)
        #expect(session.needsCloseConfirmation)
        let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)))
        await session.stop().value
        try await waitFor { kill(child, 0) == -1 && errno == ESRCH }
        #expect(session.stateName == "exited")
    }

    @Test func shellExitClosesFoilInsteadOfOfferingNewSession() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let previousDelegate = NSApp.delegate
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        let state = AppState(isIncognito: true)
        let controller = FloatingWindowController(appState: state)
        delegate.windowControllers = [controller]
        defer {
            if delegate.windowControllers.contains(where: { $0 === controller }) { controller.closeWithoutTerminalPrompt() }
            NSApp.delegate = previousDelegate
        }
        // 初始化脚本直接结束 Shell：会话自行结束，箔片应随之关闭，而不是停在已结束界面。
        state.prepareTerminal(TerminalLaunchConfiguration(shellPath: "/bin/zsh", workingDirectory: root.path,
            environment: ["ZDOTDIR": root.path, "HISTFILE": "/dev/null"], startupCommands: "exit 0"), start: true)
        #expect(state.terminalSession?.stateName == "running")
        try await waitFor { !delegate.windowControllers.contains(where: { $0 === controller }) }
        #expect(state.terminalSession?.stateName == "exited")
    }

    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func controlDOnlyClosesFoilAfterOutermostShellExits(shell: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("nested-ready")
        let returned = root.appendingPathComponent("parent-resumed")
        let previousDelegate = NSApp.delegate
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        let state = AppState(isIncognito: true)
        let controller = FloatingWindowController(appState: state)
        delegate.windowControllers = [controller]
        defer {
            if delegate.windowControllers.contains(where: { $0 === controller }) { controller.closeWithoutTerminalPrompt() }
            NSApp.delegate = previousDelegate
        }
        state.prepareTerminal(.init(shellPath: shell, workingDirectory: root.path,
            environment: ["ZDOTDIR": root.path, "HOME": root.path, "HISTFILE": "/dev/null"],
            startupCommands: "/bin/zsh -f\nprintf resumed > \(TerminalBootstrap.quote(returned.path))"), start: true)
        let session = try #require(state.terminalSession)
        // 等内层 Shell 真正处理完输入，再发送 EOF，避免依赖提示符或启动耗时。
        session.view.process.send(data: Array("printf ready > \(TerminalBootstrap.quote(ready.path))\r".utf8)[...])
        try await waitFor { FileManager.default.fileExists(atPath: ready.path) }
        session.view.process.send(data: [4])
        try await waitFor { FileManager.default.fileExists(atPath: returned.path) }
        #expect(session.state == .running)
        #expect(delegate.windowControllers.contains(where: { $0 === controller }))
        session.view.process.send(data: [4])
        try await waitFor { delegate.windowControllers.isEmpty }
        #expect(session.state == .exited(0))
    }

    @Test func explicitStopDoesNotReportShellInitiatedExit() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = TerminalSession(configuration: .init(shellPath: "/bin/zsh", workingDirectory: root.path,
            environment: ["ZDOTDIR": root.path, "HISTFILE": "/dev/null"]))
        var endedCount = 0
        session.onSessionEnded = { endedCount += 1 }
        session.start()
        await session.stop().value
        await session.stop().value
        #expect(session.stateName == "exited")
        #expect(endedCount == 0)
    }

    @Test func vimFullScreenUnicodeResizeAndReturnToShell() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("sample.txt")
        let marker = root.appendingPathComponent("vim-exited")
        try Data("浮箔 terminal sample\nsecond line\n".utf8).write(to: text)
        let configuration = TerminalLaunchConfiguration(shellPath: "/bin/zsh", workingDirectory: root.path,
            environment: ["ZDOTDIR": root.path],
            startupCommands: "/usr/bin/vim -Nu NONE -n \(TerminalBootstrap.quote(text.path))\nprintf done > \(TerminalBootstrap.quote(marker.path))")
        let session = TerminalSession(configuration: configuration)
        defer { session.stop() }
        session.start()
        try await waitFor {
            String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "").contains("浮箔 terminal sample")
        }
        let snapshot = String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
        #expect(snapshot.contains("浮箔 terminal sample"), "Fixture terminal buffer: \(snapshot)")
        #expect(session.needsCloseConfirmation)
        let columns = session.view.getTerminal().cols
        session.view.setFrameSize(NSSize(width: 950, height: 540))
        #expect(session.view.getTerminal().cols > columns)
        session.view.process.send(data: Array("\u{1b}:q!\r".utf8)[...])
        try await waitFor { FileManager.default.fileExists(atPath: marker.path) }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "done")
        await session.stop().value
    }

    @Test func historyKeepsConfigurationAndAutomaticRestoreNeverExecutes() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("should-not-run")
        let launch = TerminalLaunchConfiguration(shellPath: "/bin/zsh", workingDirectory: root.path,
                                                environment: ["ZDOTDIR": root.path], startupCommands: "touch \(TerminalBootstrap.quote(marker.path))")
        let state = AppState(isIncognito: true)
        state.prepareTerminal(launch, start: false)
        state.customTitle = "Development"
        let config = state.toConfig()
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WindowConfig.self, from: encoded)
        #expect(decoded.terminalConfiguration == launch)
        #expect(decoded.contentKind == .terminal)
        let database = try HistoryDatabase(databaseURL: root.appendingPathComponent("history.sqlite3"))
        try database.upsert(decoded)
        let saved = try #require(try database.config(id: state.id))
        #expect(saved.terminalConfiguration == launch)
        var updated = saved
        updated.terminalConfiguration?.startupCommands = "printf updated"
        try database.upsert(updated)
        #expect(try database.config(id: state.id)?.terminalConfiguration?.startupCommands == "printf updated")
        let restored = AppState(isIncognito: true)
        #expect(restored.loadConfig(decoded))
        #expect(restored.terminalSession?.stateName == "waiting")
        #expect(!restored.isBlank)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        restored.startTerminalForExplicitOpen()
        defer { restored.terminalSession?.stop() }
        try await waitFor { FileManager.default.fileExists(atPath: marker.path) }
    }

    @Test func creationStartsImmediatelyAndInvalidConfigurationFailsBeforeCreatingWindow() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = try TerminalBootstrap(configuration: .init(environment: ["HOME": root.path]), terminalID: "test")
        defer { bootstrap.cleanup() }
        #expect(bootstrap.environment["HOME"] == root.path)
        let state = AppState(isIncognito: true)
        state.prepareTerminal(.init(shellPath: "/bin/zsh", workingDirectory: root.path, startupCommands: "exit 0"), start: true)
        defer { state.terminalSession?.stop() }
        #expect(state.terminalSession?.stateName == "running")
        #expect(throws: AgentFailure.self) {
            _ = try TerminalBootstrap(configuration: .init(shellPath: "/bin/zsh", workingDirectory: root.appendingPathComponent("missing").path), terminalID: "test")
        }
        #expect(throws: AgentFailure.self) {
            _ = try TerminalBootstrap(configuration: .init(environment: ["BAD=KEY": "value"]), terminalID: "test")
        }
    }

    @Test func clearingPreviousOutputRemovesPersistedCopiesWithoutStoppingCurrentSession() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = TerminalLaunchConfiguration(shellPath: "/bin/zsh", workingDirectory: root.path,
            environment: ["ZDOTDIR": root.path, "HISTFILE": "/dev/null"])
        let config = WindowConfig(id: UUID(), contentKind: .terminal,
            terminalConfiguration: configuration, terminalScrollback: "old-record-must-disappear")
        let savedWindows = SettingsStore.shared.windowConfigs
        let savedLastOpen = SettingsStore.shared.lastOpenWindowConfigs
        let previousDelegate = NSApp.delegate
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        let state = AppState(config: config)
        let peer = AppState(config: config)
        let controller = FloatingWindowController(appState: state)
        let peerController = FloatingWindowController(appState: peer)
        delegate.windowControllers = [controller, peerController]
        defer {
            state.terminalSession?.onOutputSnapshotChanged = nil
            peer.terminalSession?.onOutputSnapshotChanged = nil
            controller.closeWithoutTerminalPrompt()
            peerController.closeWithoutTerminalPrompt()
            _ = HistoryRepository.shared.remove(ids: [config.id])
            SettingsStore.shared.windowConfigs = savedWindows
            SettingsStore.shared.lastOpenWindowConfigs = savedLastOpen
            NSApp.delegate = previousDelegate
        }
        SettingsStore.shared.windowConfigs = [config]
        SettingsStore.shared.lastOpenWindowConfigs = [config]
        let session = try #require(state.terminalSession)
        session.start()
        session.view.feed(text: "current-session-kept\r\n")
        state.saveState()
        #expect(HistoryRepository.shared.config(id: config.id)?.terminalScrollback?.contains("old-record-must-disappear") == true)
        state.clearPreviousTerminalOutput()
        #expect(state.terminalSession === session)
        #expect(session.state == .running)
        #expect(session.previousOutput == nil)
        #expect(peer.terminalSession?.previousOutput == nil)
        #expect(session.outputSnapshot?.contains("current-session-kept") == true)
        #expect(HistoryRepository.shared.config(id: config.id)?.terminalScrollback?.contains("old-record-must-disappear") != true)
        #expect(SettingsStore.shared.windowConfigs.first?.terminalScrollback?.contains("old-record-must-disappear") != true)
        #expect(SettingsStore.shared.lastOpenWindowConfigs.first?.terminalScrollback?.contains("old-record-must-disappear") != true)
        peer.saveState()
        #expect(HistoryRepository.shared.config(id: config.id)?.terminalScrollback == nil)
        state.saveState()
        let reopened = AppState(config: try #require(HistoryRepository.shared.config(id: config.id)))
        #expect(reopened.terminalSession?.previousOutput?.contains("old-record-must-disappear") != true)
        #expect(reopened.terminalSession?.previousOutput?.contains("current-session-kept") == true)
    }

    @Test func configurationEditingPreservesRunningSessionAndAppliesOnNextStart() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("edited-script-ran")
        let state = AppState()
        defer {
            state.terminalSession?.onOutputSnapshotChanged = nil
            state.terminalSession?.stop()
            _ = HistoryRepository.shared.remove(ids: [state.id])
        }
        let initial = TerminalLaunchConfiguration(shellPath: "/bin/zsh", workingDirectory: root.path,
            environment: ["ZDOTDIR": root.path, "HISTFILE": "/dev/null"])
        state.prepareTerminal(initial, start: true)
        let original = try #require(state.terminalSession)
        var edited = try TerminalConfigurationField.environment.updating(initial, with: "ZDOTDIR=\(root.path)\nHISTFILE=/dev/null\nEDITED=one=two")
        edited = try TerminalConfigurationField.script.updating(edited, with: "printf edited > \(TerminalBootstrap.quote(marker.path))\nexport SECOND_LINE=yes")
        try state.updateTerminalConfiguration(edited)
        #expect(state.terminalSession === original)
        #expect(original.configuration == initial)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(HistoryRepository.shared.config(id: state.id)?.terminalConfiguration == edited)
        #expect(state.toConfig().canRenameTitle)
        state.applyFoilTitle("A terminal title")
        state.saveState()
        #expect(HistoryRepository.shared.config(id: state.id)?.customTitle == "A terminal title")
        let restored = AppState(config: state.toConfig())
        defer { restored.terminalSession?.stop() }
        #expect(restored.terminalSession?.state == .waiting)
        #expect(restored.terminalConfiguration == edited)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        restored.startTerminalForExplicitOpen()
        try await waitFor { FileManager.default.fileExists(atPath: marker.path) }
        #expect(edited.environment["EDITED"] == "one=two")
    }

    @Test func waitingConfigurationEditsValidateBeforeReplacingSession() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(isIncognito: true)
        let configuration = TerminalLaunchConfiguration(shellPath: "/bin/zsh", workingDirectory: root.path)
        state.prepareTerminal(configuration, start: false)
        let original = try #require(state.terminalSession)
        let invalid = try TerminalConfigurationField.directory.updating(configuration, with: root.appendingPathComponent("missing").path)
        #expect(throws: AgentFailure.self) { try state.updateTerminalConfiguration(invalid) }
        #expect(state.terminalSession === original)
        #expect(state.terminalConfiguration == configuration)
        #expect(throws: AgentFailure.self) { try TerminalConfigurationField.environment.updating(configuration, with: "KEY=one\nKEY=two") }
        #expect(throws: AgentFailure.self) { try TerminalConfigurationField.environment.updating(configuration, with: "missing equal") }
        let edited = try TerminalConfigurationField.shell.updating(configuration, with: "/bin/bash")
        try state.updateTerminalConfiguration(edited)
        #expect(state.terminalSession !== original)
        #expect(state.terminalSession?.configuration.shellPath == "/bin/bash")
        #expect(state.terminalSession?.state == .waiting)
        #expect(TerminalConfigurationField.environment.value(in: .init(environment: ["B": "2", "A": "1"])) == "A=1\nB=2")
    }

    @Test func menuOpenReusesBlankThenCreatesWithoutReplacingContent() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let delegate = AppDelegate()
        let blank = FloatingWindowController(appState: AppState())
        let privateBlank = FloatingWindowController(appState: AppState(isIncognito: true))
        delegate.windowControllers = [privateBlank, blank]
        var historyIDs = Set<UUID>()
        defer {
            for controller in delegate.windowControllers { controller.closeWithoutTerminalPrompt() }
            _ = HistoryRepository.shared.remove(ids: historyIDs)
        }
        let invalid = TerminalLaunchConfiguration(workingDirectory: root.appendingPathComponent("missing").path)
        #expect(throws: AgentFailure.self) {
            _ = try delegate.applicationControl.createTerminal(invalid, reuseBlankWindow: true)
        }
        #expect(delegate.isBlank(blank.appState))
        let configuration = TerminalLaunchConfiguration(shellPath: "/bin/zsh", workingDirectory: root.path,
            environment: ["ZDOTDIR": root.path, "HISTFILE": "/dev/null"])
        let reused = try delegate.applicationControl.createTerminal(configuration, title: "Reused", reuseBlankWindow: true)
        historyIDs.insert(reused.appState.id)
        #expect(reused === blank)
        #expect(delegate.windowControllers.count == 2)
        #expect(reused.appState.terminalSession?.stateName == "running")
        #expect(delegate.isBlank(privateBlank.appState))
        let sessionID = reused.appState.terminalSession?.id
        let created = try delegate.applicationControl.createTerminal(configuration, title: "New", reuseBlankWindow: true)
        historyIDs.insert(created.appState.id)
        #expect(created !== reused)
        #expect(delegate.windowControllers.count == 3)
        #expect(reused.appState.terminalSession?.id == sessionID)
        #expect(created.appState.terminalSession?.stateName == "running")
    }

    @Test func genericControlSharesPauseRevocationAndDedupOverSocket() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let delegate = AppDelegate()
        let previous = NSApp.delegate
        var historyIDs = Set<UUID>()
        NSApp.delegate = delegate
        defer {
            delegate.controlSocket?.stop()
            for window in delegate.windowControllers { window.closeWithoutTerminalPrompt() }
            _ = HistoryRepository.shared.remove(ids: historyIDs)
            NSApp.delegate = previous
        }
        delegate.startControlSocketIfNeeded()
        let path = try #require(delegate.controlSocket?.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await oversizedFrameIsClosed(path: path))
        let token = String(repeating: "c", count: 64)
        let authorize = AgentRequest(action: "authorize", run_id: delegate.agentTerminal.runID, credential: token)
        #expect(try await socket(authorize, path: path).error == nil)
        var create = AgentRequest(action: "terminal.create", run_id: delegate.agentTerminal.runID, credential: token)
        create.incognito = true
        create.terminal = .init(shellPath: "/bin/zsh", workingDirectory: root.path, environment: ["ZDOTDIR": root.path, "HISTFILE": "/dev/null"], startupCommands: "printf test")
        let response = try await socket(create, path: path)
        let id = try #require(response.window?.id)
        #expect(response.window?.terminal_state == "running")
        #expect(try await socket(create, path: path).window?.id == id)
        #expect(delegate.windowControllers.count == 1)
        let controller = try #require(delegate.windowControllers.first)
        historyIDs.insert(controller.appState.id)
        controller.appState.id = UUID()
        historyIDs.insert(controller.appState.id)
        var request = AgentRequest(action: "list", run_id: delegate.agentTerminal.runID, credential: token)
        #expect(try await socket(request, path: path).boards?.isEmpty == true)
        request.scope = "all"; request.request_id = UUID().uuidString
        #expect(try await socket(request, path: path).windows?.first?.id == id)
        request.action = "hide"; request.board_id = id; request.request_id = UUID().uuidString
        #expect(try await socket(request, path: path).window?.visible == false)
        delegate.agentTerminal.paused = true
        request.action = "reveal"; request.request_id = UUID().uuidString
        #expect(try await socket(request, path: path).error == "CONTROL_PAUSED")
        delegate.agentTerminal.paused = false
        request.action = "close"; request.force = true; request.request_id = UUID().uuidString
        #expect(try await socket(request, path: path).error == nil)
        #expect(delegate.windowControllers.isEmpty)
        #expect(try await socket(create, path: path).window?.id == id)
        #expect(delegate.windowControllers.isEmpty)
        delegate.agentTerminal.revokeAll()
        request.action = "list"; request.force = nil; request.request_id = UUID().uuidString
        #expect(try await socket(request, path: path).error == "PERMISSION_DENIED")
    }

    @concurrent private func oversizedFrameIsClosed(path: String) async throws -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        AgentSocketIO.configure(fd, seconds: 3)
        var address = try AgentSocketIO.address(path)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard result == 0 else { return false }
        let header: [UInt8] = [0, 1, 0, 0]
        _ = header.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, 0) == 0
    }

    @concurrent private func socket(_ request: AgentRequest, path: String) async throws -> AgentResponse {
        try AgentSocketIO.exchange(request, path: path)
    }
}
