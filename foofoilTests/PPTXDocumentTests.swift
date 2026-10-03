
import Foundation
import AppKit
import Testing
import FoofoilExtensionKit
@testable import foofoil

struct PPTXDocumentTests {
    @Test func readsSlideOrderTitlesAndPreservesResources() async throws {
        let source = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        let document = try PPTXDocument(url: source)
        #expect(document.slideSize == NSSize(width: 720, height: 540))
        #expect(document.slides == [PPTXSlide(id: "rId9", title: "目录 & Title"), PPTXSlide(id: "rId2", title: nil)])
        let preview = try await document.preview(at: 1)
        #expect(try await document.preview(at: 1) == preview)
        let archive = try PPTXArchive(url: preview)
        let xml = try PPTXDocument.parseXML(archive.data(for: "ppt/presentation.xml"))
        let nodes = try xml.nodes(forXPath: "/*/*[local-name()='sldIdLst']/*[local-name()='sldId']")
        #expect(nodes.count == 1)
        #expect((nodes.first as? XMLElement)?.attribute(forName: "r:id")?.stringValue == "rId2")
        #expect(try xml.nodes(forXPath: "/*/*[local-name()='custShowLst' or local-name()='extLst']").isEmpty)
        let input = try PPTXArchive(url: source)
        #expect(Set(archive.entries.keys) == Set(input.entries.keys))
        for path in input.entries.keys where path != "ppt/presentation.xml" {
            #expect(try archive.data(for: path) == input.data(for: path))
        }
        #expect(try Data(contentsOf: source) == original)
        await #expect(throws: PPTXError.self) { try await document.preview(at: 2) }
    }

    @Test func rejectsUnsafeXMLAndCorruptArchive() throws {
        #expect(throws: PPTXError.self) {
            try PPTXDocument.parseXML(Data("<!DOCTYPE x [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><x>&x;</x>".utf8))
        }
        #expect(try PPTXDocument.slidePath("./slides/slide1.xml") == "ppt/slides/slide1.xml")
        #expect(try PPTXDocument.slidePath("/ppt/slides/slide1.xml") == "ppt/slides/slide1.xml")
        #expect(throws: PPTXError.self) { try PPTXDocument.slidePath("../../outside") }
        #expect(throws: PPTXError.self) { try PPTXArchive.validatedPath("ppt/../../outside") }
        #expect(throws: PPTXError.self) { try PPTXDocument.singleSlidePresentation(Data("<x/>".utf8), at: 0) }
        let source = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        var data = try Data(contentsOf: source)
        // 第一个 entry 的 CRC；压缩内容不变仍必须拒绝读取。
        let central = try #require(data.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        data[central.lowerBound + 16] ^= 0xff
        try data.write(to: source)
        let archive = try PPTXArchive(url: source)
        #expect(throws: PPTXError.self) { try archive.data(for: "ppt/presentation.xml") }
    }

    @MainActor @Test func navigatorSelectionAndClose() async throws {
        let source = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let state = AppState()
        state.openFile(url: source)
        let controller = state.pptxNavigationController
        await controller.open(url: source, appState: state)
        try await waitForPreview(controller)
        let contribution = try #require(state.builtInNavigatorContributions.first)
        #expect(contribution.selectedItemIDs == ["rId9"])
        #expect(contribution.items[1].badge == "2")
        #expect(contribution.allowedActions == [.activate])
        state.performNavigatorAction(NavigatorAction(contributionID: contribution.id, kind: .activate, itemIDs: ["rId2"]))
        controller.select(0)
        controller.select(1)
        try await waitForPreview(controller)
        #expect(controller.currentIndex == 1)
        #expect(state.builtInNavigatorContributions.first?.selectedItemIDs == ["rId2"])
        // 模拟全屏重建视图：同 URL 再次挂载，不重新创建文稿或退回第一页。
        await controller.open(url: source, appState: state)
        #expect(controller.currentIndex == 1)
        #expect(state.imageURL == source)
        #expect(state.toConfig().originalImageName == source.lastPathComponent)
        let preview = try #require(controller.previewURL)
        state.resetContent()
        #expect(state.builtInNavigatorContributions.isEmpty)
        #expect(state.builtInNavigatorActionHandler == nil)
        #expect(controller.previewURL == nil)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: preview.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: preview.path))
    }

    @Test func slideFitsFullScreenAndNavigatorSpace() {
        let slide = NSSize(width: 720, height: 540)
        #expect(PPTXModeView.fittedSlideSize(in: NSSize(width: 1920, height: 1080), slide: slide) == NSSize(width: 1440, height: 1080))
        #expect(PPTXModeView.fittedSlideSize(in: NSSize(width: 1000, height: 1080), slide: slide) == NSSize(width: 1000, height: 750))
        #expect(PPTXModeView.fittedSlideSize(in: NSSize(width: 160, height: 90), slide: NSSize(width: 1280, height: 720)) == NSSize(width: 160, height: 90))
    }

    @MainActor @Test func windowTracksSlideAspectAndUsesVideoControlsTimer() async throws {
        let source = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let state = AppState()
        state.openFile(url: source)
        state.showBorder = false
        let windowController = FloatingWindowController(appState: state)
        defer { state.resetContent(); windowController.close() }
        let window = try #require(windowController.window)
        await state.pptxNavigationController.open(url: source, appState: state)
        try await waitForPreview(state.pptxNavigationController)
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(window.frame.width / window.frame.height - 4.0 / 3.0) < 0.001)
        windowController.beginManualLiveResize()
        let resized = windowController.constrainedManualResizeSize(NSSize(width: 900, height: 450), from: window.frame.size)
        #expect(abs(resized.width / resized.height - 4.0 / 3.0) < 0.001)
        windowController.endManualLiveResize()
        state.navigatorPanelVisibilityMode = .always
        state.isFullScreen = true
        let point = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        windowController.handleMediaPointerActivity(at: point, autoHideInterval: 0.01)
        #expect(state.isMediaPlaybackControlsVisible)
        #expect(state.isFullScreenNavigatorVisible)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.isMediaPlaybackControlsVisible)
        #expect(!state.isFullScreenNavigatorVisible)
        windowController.handleMediaPointerActivity(at: point, autoHideInterval: 1)
        #expect(state.isMediaPlaybackControlsVisible)
        windowController.handleMediaPointerExit(autoHideInterval: 0.01)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.isMediaPlaybackControlsVisible)
        state.isFullScreen = false
        state.showBorder = true
        state.showBorder = false
        #expect(abs(window.frame.width / window.frame.height - 4.0 / 3.0) < 0.001)
    }

    @MainActor @Test func usesImageNavigationShortcutsAndHonorsCustomization() async throws {
        let source = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let state = AppState()
        state.openFile(url: source)
        defer { state.resetContent() }
        let controller = state.pptxNavigationController
        await controller.open(url: source, appState: state)
        try await waitForPreview(controller)
        let shortcuts = KeyboardShortcutStore.shared
        let nextDefinition = try #require(KeyboardShortcutCatalog.definition(withID: "go.nextItem"))
        let previousDefinition = try #require(KeyboardShortcutCatalog.definition(withID: "go.previousItem"))
        let savedDefinitions = [nextDefinition, previousDefinition].map {
            ($0, shortcuts.isCustomized($0), shortcuts.shortcut(for: $0))
        }
        defer {
            for (definition, customized, shortcut) in savedDefinitions {
                if customized { shortcuts.setShortcut(shortcut, for: definition) }
                else { shortcuts.reset(definition) }
            }
        }
        shortcuts.reset(nextDefinition)
        shortcuts.reset(previousDefinition)
        func event(_ code: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                            isARepeat: false, keyCode: code)!
        }
        for (next, previous) in [
            (event(125, "\u{F701}", [.function, .numericPad]), event(126, "\u{F700}", [.function, .numericPad])),
            (event(124, "\u{F703}"), event(123, "\u{F702}")),
            (event(45, "n", .control), event(35, "p", .control)),
            (event(3, "f", .control), event(11, "b", .control))
        ] {
            #expect(state.handleFileListKeyDown(next))
            try await waitForPreview(controller)
            #expect(controller.currentIndex == 1)
            #expect(state.handleFileListKeyDown(next))
            #expect(controller.currentIndex == 1)
            #expect(state.handleFileListKeyDown(previous))
            try await waitForPreview(controller)
            #expect(controller.currentIndex == 0)
        }
        #expect(state.handleFileListKeyDown(event(125, "\u{F701}")))
        #expect(state.handleFileListKeyDown(event(126, "\u{F700}")))
        try await waitForPreview(controller)
        #expect(controller.currentIndex == 0)
        shortcuts.setShortcut(KeyboardShortcut(keyEquivalent: "j", modifiers: .command), for: nextDefinition)
        #expect(!state.handleFileListKeyDown(event(124, "\u{F703}")))
        #expect(!state.handleFileListKeyDown(event(45, "n", .control)))
        #expect(state.handleFileListKeyDown(event(38, "j", .command)))
        try await waitForPreview(controller)
        #expect(controller.currentIndex == 1)
        shortcuts.setShortcut(nil, for: previousDefinition)
        #expect(!state.handleFileListKeyDown(event(123, "\u{F702}")))
        #expect(controller.currentIndex == 1)
    }

    @MainActor @Test func fullScreenTemporarilyAllowsNativeWindowExpansion() {
        final class ProbeWindow: NSWindow {
            var requestedStyle: StyleMask?
            override func toggleFullScreen(_ sender: Any?) { requestedStyle = styleMask }
        }
        let state = AppState()
        let controller = FloatingWindowController(appState: state)
        let window = ProbeWindow(contentRect: NSRect(x: 20, y: 30, width: 400, height: 300),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        controller.toggleFullScreen()
        #expect(window.requestedStyle?.contains(.resizable) == true)
        #expect(window.collectionBehavior == [.fullScreenPrimary])
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: false)
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        #expect(state.isFullScreen)
        #expect(window.frame.size == NSSize(width: 1440, height: 900))
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(!state.isFullScreen)
        #expect(!window.styleMask.contains(.resizable))
        controller.toggleFullScreen()
        controller.windowDidFailToEnterFullScreen(window)
        #expect(!window.styleMask.contains(.resizable))
        #expect(!state.isFullScreen)
        window.close()
    }

    @MainActor private func waitForPreview(_ controller: PPTXNavigationController) async throws {
        for _ in 0..<300 where controller.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.isLoading)
        #expect(!controller.failed)
        #expect(controller.previewURL != nil)
    }

    static func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).pptx")
        try Data(base64Encoded: "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")!.write(to: url)
        return url
    }
}
