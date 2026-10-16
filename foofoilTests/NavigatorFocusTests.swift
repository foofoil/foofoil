import AppKit
import Testing
import FoofoilExtensionKit
@testable import foofoil

@MainActor @Suite(.sharedApplicationState)
struct NavigatorFocusTests {
    private func event(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [.function, .numericPad]) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                      charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    @Test func arrowsFollowVisibleRowsOnlyWhileSidebarFocused() throws {
        let state = AppState(isIncognito: true)
        state.builtInNavigatorContributions = [.init(id: "test.tree", titleLocalizationKey: "Navigator", style: .outline,
            items: [.init(id: "folder", title: "Folder"), .init(id: "a", parentID: "folder", title: "A"),
                    .init(id: "b", parentID: "folder", title: "B"), .init(id: "last", title: "Last")],
            selectedItemIDs: ["folder"])]
        var activated: [String] = []
        state.builtInNavigatorActionHandler = { action in activated.append(contentsOf: action.itemIDs) }
        #expect(!state.handleNavigatorKeyDown(try event(125)))
        #expect(activated.isEmpty)
        state.isNavigatorFocused = true
        #expect(state.handleNavigatorKeyDown(try event(125)))
        #expect(activated == ["last"])
        #expect(state.handleNavigatorKeyDown(try event(125)))
        #expect(activated == ["last"])
        state.navigatorFocusedItemID = "folder"
        #expect(state.handleNavigatorKeyDown(try event(124)))
        #expect(state.expandedNavigatorItemIDs.contains("folder"))
        #expect(state.handleNavigatorKeyDown(try event(125)))
        #expect(activated.last == "a")
        #expect(state.handleNavigatorKeyDown(try event(125)))
        #expect(activated.last == "b")
        #expect(state.handleNavigatorKeyDown(try event(123)))
        #expect(state.navigatorFocusedItemID == "folder")
        #expect(state.handleNavigatorKeyDown(try event(123)))
        #expect(!state.expandedNavigatorItemIDs.contains("folder"))
        for key: UInt16 in [124, 36, 76] {
            state.expandedNavigatorItemIDs = []
            state.navigatorFocusedItemID = "folder"
            #expect(state.handleNavigatorKeyDown(try event(key)))
            #expect(state.expandedNavigatorItemIDs.contains("folder"))
            #expect(state.handleNavigatorKeyDown(try event(key)))
            #expect(state.navigatorFocusedItemID == "a")
        }
        state.isNavigatorFocused = false
        #expect(!state.handleNavigatorKeyDown(try event(125)))
    }

    @Test func groupedFileListCanMovePastGroupWithoutOpeningIt() throws {
        let state = AppState(isIncognito: true)
        state.builtInNavigatorContributions = [.init(id: AppState.fileListNavigatorID, titleLocalizationKey: "Navigator", style: .outline,
            items: [.init(id: "first", title: "First"), .init(id: "group", title: "Group"),
                    .init(id: "track", parentID: "group", title: "Track")], selectedItemIDs: ["first"])]
        state.expandedNavigatorItemIDs = ["group"]
        state.isNavigatorFocused = true
        var activated: [String] = []
        state.builtInNavigatorActionHandler = { action in activated.append(contentsOf: action.itemIDs) }
        #expect(state.handleNavigatorKeyDown(try event(125)))
        #expect(state.navigatorFocusedItemID == "group" && activated.isEmpty)
        #expect(state.handleNavigatorKeyDown(try event(125)))
        #expect(activated == ["track"])
        #expect(!state.handleNavigatorKeyDown(try event(125, modifiers: .command)))
        state.isNavigatorSearchActive = true
        #expect(!state.handleNavigatorKeyDown(try event(126)))
    }

    @Test func archiveTreeUsesFocusAndDoesNotReadCollapsedChildren() async throws {
        let fixture = try ArchiveTests.Fixture([("folder/a.txt", Data("A".utf8)), ("folder/b.txt", Data("B".utf8))])
        defer { fixture.remove() }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFile(url: fixture.url)
        let archive = try #require(state.archiveSession)
        for _ in 0..<300 where archive.busy { try await Task.sleep(for: .milliseconds(10)) }
        let folder = try #require(archive.index?.entries.first { $0.path == "folder" })
        archive.select(folder.id)
        #expect(!state.handleNavigatorKeyDown(try event(125)))
        state.isNavigatorFocused = true
        #expect(state.handleNavigatorKeyDown(try event(124)))
        #expect(state.expandedNavigatorItemIDs.contains(folder.id))
        #expect(state.handleNavigatorKeyDown(try event(125)))
        #expect(archive.selected?.name == "a.txt")
        #expect(state.handleNavigatorKeyDown(try event(125)))
        #expect(archive.selected?.name == "b.txt")
        #expect(state.handleNavigatorKeyDown(try event(126)))
        #expect(archive.selected?.name == "a.txt")
        for key: UInt16 in [124, 36, 76] {
            state.expandedNavigatorItemIDs.remove(folder.id)
            archive.select(folder.id)
            #expect(state.handleNavigatorKeyDown(try event(key)))
            #expect(state.expandedNavigatorItemIDs.contains(folder.id))
            #expect(state.handleNavigatorKeyDown(try event(key)))
            #expect(archive.selected?.name == "a.txt")
        }
    }

    @Test func inactiveSelectionUsesNeutralSystemColorInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var color: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                color = NSColor.unemphasizedSelectedContentBackgroundColor.usingColorSpace(.deviceRGB)
            }
            let resolved = try #require(color)
            let components = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
            #expect((components.max()! - components.min()!) < 0.03)
            #expect(resolved.alphaComponent == 1)
        }
    }

    @Test func sharedFieldEditorBelongsToItsSidebarSearchField() {
        let state = AppState(isIncognito: true)
        let host = NavigatorHostingView(appState: state)
        let field = NavigatorSearchTestField(frame: .zero)
        host.addSubview(field)
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.delegate = field
        #expect(NavigatorHostingView.enclosing(editor) === host)
    }

    @Test func nativeResponderTracksSidebarAndContentWithinSameWindow() throws {
        let state = AppState(isIncognito: true)
        let panel = NavigatorFocusTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let host = NavigatorHostingView(appState: state, isFullScreenOverlay: true)
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 300)
        let content = FocusableContent(frame: NSRect(x: 180, y: 0, width: 220, height: 300))
        container.addSubview(host)
        container.addSubview(content)
        panel.contentView = container
        defer { panel.close() }
        #expect(panel.makeFirstResponder(host))
        panel.synchronizeNavigatorFocus(state)
        #expect(state.isNavigatorFocused)
        #expect(NavigatorHostingView.enclosing(host) === host)
        #expect(panel.makeFirstResponder(content))
        panel.synchronizeNavigatorFocus(state)
        #expect(!state.isNavigatorFocused)
        #expect(panel.makeFirstResponder(host))
        panel.synchronizeNavigatorFocus(state)
        #expect(panel.isKeyWindow)
        #expect(state.isNavigatorFocused, "Responder: \(String(describing: panel.firstResponder))")
        panel.isTestKeyWindow = false
        panel.synchronizeNavigatorFocus(state)
        #expect(!state.isNavigatorFocused)
    }
}

@MainActor private final class FocusableContent: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// 测试宿主可能不在前台；固定 key 状态，验证实际 responder 子树而不争夺系统焦点。
@MainActor private final class NavigatorFocusTestWindow: NSWindow {
    var isTestKeyWindow = true
    override var isKeyWindow: Bool { isTestKeyWindow }
}

@MainActor private final class NavigatorSearchTestField: NSTextField, NSTextViewDelegate {}
