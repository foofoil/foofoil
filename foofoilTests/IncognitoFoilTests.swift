import AppKit
import Testing
import SwiftUI
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct IncognitoFoilTests {
    @Test func contentChangesAndResetNeverEnterHistory() {
        let state = AppState(isIncognito: true)
        state.openText("Private note", isMarkdown: false)
        let firstID = state.id
        state.opacity = 0.7
        state.saveState()
        #expect(HistoryRepository.shared.config(id: firstID) == nil)
        state.resetContent()
        state.openText("# Private replacement", isMarkdown: true)
        state.saveState()
        #expect(state.isIncognito)
        #expect(HistoryRepository.shared.config(id: state.id) == nil)
        #expect(HistoryRepository.shared.config(id: firstID) == nil)
    }

    @Test func normalFoilsStillSaveHistory() {
        let state = AppState()
        state.openText("Normal note", isMarkdown: false)
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(HistoryRepository.shared.config(id: state.id) != nil)
    }

    @Test func privateShareLinksRoundTripAndRejectInvalidContent() throws {
        for content in [SharedContentLink.text("Private 中文 & text"), .website(URL(string: "https://example.com/private")!)] {
            let url = try #require(content.url.flatMap(SharedContentLink.incognitoURL))
            #expect(SharedContentLink.isIncognito(url))
            #expect(SharedContentLink(url: url) == content)
        }
        #expect(SharedContentLink(url: URL(string: "foofoil://incognito-share?text=a&text=b")!) == nil)
        #expect(SharedContentLink.incognitoURL(URL(string: "https://example.com")!) == nil)
    }

    @Test func privateShareFilesKeepPrivacyMarker() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "Private".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }
        let staged = try ShareStaging.copy(source, isIncognito: true)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        #expect(ShareStaging.isStaged(staged))
        #expect(ShareStaging.isIncognito(staged))
        #expect(!ShareStaging.isIncognito(source))
    }

    @Test func blankWindowReuseKeepsPrivacyModesSeparate() {
        let delegate = AppDelegate()
        let normal = FloatingWindowController(appState: AppState())
        let incognito = FloatingWindowController(appState: AppState(isIncognito: true))
        delegate.windowControllers = [normal, incognito]
        defer { normal.close(); incognito.close() }
        #expect(delegate.blankWindowController(isIncognito: false) === normal)
        #expect(delegate.blankWindowController(isIncognito: true) == nil)
        #expect(delegate.availableBlankWindowController === normal)
        delegate.windowControllers = [incognito]
        #expect(delegate.availableBlankWindowController == nil)
        delegate.windowControllers = [normal, incognito]
        #expect(delegate.restorableWindowConfigs.map(\.id) == [normal.appState.id])
    }

    @Test func incognitoEmptyStateNeverOffersRecentHistory() {
        let normal = AppState()
        let incognito = AppState(isIncognito: true)
        #expect(normal.canOpenRecentHistory)
        #expect(incognito.isBlank)
        #expect(!incognito.canOpenRecentHistory)
        incognito.openText("Private note", isMarkdown: false)
        incognito.resetContent()
        #expect(!incognito.canOpenRecentHistory)
    }

    @Test func incognitoIgnoresRecentHistoryNumberShortcut() throws {
        let recent = AppState()
        recent.openText("Recent history shortcut fixture", isMarkdown: false)
        defer { HistoryManager.shared.removeFromHistory(recent.toConfig()) }
        #expect(!HistoryManager.shared.historyConfigs.isEmpty)
        let controller = FloatingWindowController(appState: AppState(isIncognito: true))
        defer { controller.close() }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
                                                context: nil, characters: "1", charactersIgnoringModifiers: "1",
                                                isARepeat: false, keyCode: 18))
        let id = controller.appState.id
        _ = controller.window?.performKeyEquivalent(with: event)
        #expect(controller.appState.id == id)
        #expect(controller.appState.isBlank)
    }

    @Test func incognitoIconIsRenderableAtMenuAndEmptyStateSizes() throws {
        #expect(IncognitoFoilIcon.image.isTemplate)
        #expect(IncognitoFoilIcon.menuImage.size == NSSize(width: 16, height: 16))
        let data = try #require(IncognitoFoilIcon.image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        var visiblePixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                visiblePixels += 1
            }
        }
        #expect(visiblePixels > 30)
    }

    /// 将实际空箔视图的两种外观附在测试结果中，供视觉检查。
    @Test(arguments: [ColorScheme.light, .dark])
    func renderIncognitoEmptyState(colorScheme: ColorScheme) async throws {
        let view = NSHostingView(rootView: TextEditorModeView(appState: AppState(isIncognito: true))
            .environment(\.colorScheme, colorScheme)
            .background(colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.93)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        window.contentView = view
        defer { window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(png), named: "foofoil-incognito-\(colorScheme == .dark ? "dark" : "light").png")
    }

    @Test func fileGroupsInheritTargetPrivacy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("note.txt")
        let secondText = directory.appendingPathComponent("second.txt")
        try "Private dropped text".write(to: text, atomically: true, encoding: .utf8)
        try "Private second text".write(to: secondText, atomically: true, encoding: .utf8)
        let delegate = AppDelegate()
        defer { for controller in delegate.windowControllers { controller.close() } }
        let state = AppState(isIncognito: true)
        #expect(delegate.openGroupedFiles([text, secondText], into: state, append: false))
        #expect(delegate.windowControllers.count == 1)
        #expect(delegate.windowControllers.allSatisfy { $0.appState.isIncognito })
        #expect(delegate.windowControllers.allSatisfy { HistoryRepository.shared.config(id: $0.appState.id) == nil })
        #expect(HistoryRepository.shared.config(id: state.id) == nil)
    }

    @Test func incognitoShortcutDefaults() throws {
        let newFoil = try #require(KeyboardShortcutCatalog.definition(withID: "file.newIncognito")?.defaultShortcut)
        let clipboard = try #require(KeyboardShortcutCatalog.definition(withID: "file.openClipboardIncognito")?.defaultShortcut)
        #expect(newFoil.keyEquivalent == "n")
        #expect(newFoil.modifiers == [.command, .shift])
        #expect(clipboard.keyEquivalent == "v")
        #expect(clipboard.modifiers == [.command, .shift, .option])
    }

    @Test func privateShareExtensionIsEmbeddedAndLocalized() throws {
        let plugins = try #require(Bundle(for: AppDelegate.self).builtInPlugInsURL)
        let bundle = try #require(Bundle(url: plugins.appendingPathComponent("foofoilIncognitoShareExtension.appex")))
        #expect(bundle.object(forInfoDictionaryKey: "FoofoilIncognito") as? Bool == true)
        #expect(bundle.bundleIdentifier == "com.markonce.foofoil.IncognitoShareExtension")
        for language in ["en", "zh-Hans"] {
            let url = try #require(bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: language))
            let strings = try #require(NSDictionary(contentsOf: url))
            #expect(strings["CFBundleDisplayName"] as? String == (language == "en" ? "Incognito Foil" : "无痕箔"))
        }
    }
}
