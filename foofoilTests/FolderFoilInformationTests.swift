import AppKit
import AVFoundation
import Testing
import FoofoilExtensionKit
@testable import foofoil

@MainActor @Suite(.sharedApplicationState, .serialized)
struct FolderFoilInformationTests {
    private func fixture() throws -> (URL, [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let text = nested.appendingPathComponent("note.txt")
        try "first line\nsecond line".write(to: text, atomically: true, encoding: .utf8)
        let image = NSImage(size: NSSize(width: 20, height: 30), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let data = try #require(image.tiffRepresentation)
        let images = [root.appendingPathComponent("one.tiff"), nested.appendingPathComponent("two.tiff")]
        for url in images { try data.write(to: url) }
        return (root, images + [text])
    }

    private func settle(_ session: ArchiveSession) async throws {
        for _ in 0..<300 {
            if !session.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Folder did not finish opening")
    }

    @Test func fileInformationDescribesTheTargetWithoutWindowOrHistoryRows() async throws {
        let (root, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection(urls, roots: [root])
        let session = try #require(state.archiveSession)
        try await settle(session)
        let target = try #require(session.contribution.items.first { $0.title == "two.tiff" })
        let details = try #require(try await session.fileInformation(target.id))
        #expect(TestFileIdentity.equals(details.source, urls[1]))
        #expect(details.rows.contains { $0.key == "Foil Info Pixels" && $0.value == "20 × 30 px" })
        #expect(details.rows.contains { $0.key == "Foil Info File Size" })
        #expect(!details.rows.contains { ["Foil Info Window Size", "Foil Info First Visit", "Foil Info Last Visit"].contains($0.key) })
        #expect(session.selectedID == nil)
    }

    @Test func explicitFolderAndMultiFileBatchResolveToDirectories() async throws {
        let (root, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        // 即使只有子目录中的文件，也必须保留用户打开的根目录。
        state.openFileCollection([urls[1], urls[2]], roots: [root])
        let session = try #require(state.archiveSession)
        try await settle(session)
        let details = await FoilInformation.details(config: state.toConfig(), state: state, windowSize: nil)
        #expect(TestFileIdentity.equals(details.source, root))
        #expect(details.available)
        #expect(details.rows.contains { $0.key == "Foil Info Type" && $0.value == NSLocalizedString("Foil Info Type Folder", comment: "") })
        #expect(details.rows.contains { $0.key == "Foil Info Folder Path" })
        #expect(!details.rows.contains { $0.key == "Foil Info File Path" || $0.key == "Foil Info File Size" })
        #expect(FoilInformation.currentFileConfig(for: state) == nil)
        state.openFileCollection(urls)
        #expect(TestFileIdentity.equals(FoilInformation.sourceURL(for: state.toConfig()), root))
    }

    @Test func currentTextUsesTheSameDetailsAsAnOrdinaryFile() async throws {
        let (root, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection(urls, roots: [root])
        let session = try #require(state.archiveSession)
        try await settle(session)
        let note = try #require(session.contribution.items.first { $0.title == "note.txt" })
        session.select(note.id)
        let current = try #require(FoilInformation.currentFileConfig(for: state))
        let details = await FoilInformation.details(config: current, state: state.readingState, windowSize: nil)
        let ordinary = AppState(isIncognito: true)
        defer { ordinary.resetContent() }
        ordinary.openFile(url: urls[2])
        let standalone = await FoilInformation.details(config: ordinary.toConfig(), state: ordinary, windowSize: nil)
        #expect(TestFileIdentity.equals(details.source, urls[2]))
        for key in ["Foil Info Title", "Foil Info Type", "Foil Info File Size", "Foil Info Characters", "Foil Info Lines"] {
            #expect(details.rows.first { $0.key == key }?.value == standalone.rows.first { $0.key == key }?.value)
        }
    }

    @Test func currentAudioUsesTheSameDetailsAsAnOrdinaryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("track.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            try file.write(from: buffer)
        }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection([url], roots: [root])
        let session = try #require(state.archiveSession)
        try await settle(session)
        session.select(try #require(session.contribution.items.first { $0.title == "track.wav" }).id)
        for _ in 0..<300 {
            if FoilInformation.currentFileConfig(for: state) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let config = try #require(FoilInformation.currentFileConfig(for: state))
        let details = await FoilInformation.details(config: config, state: state.readingState, windowSize: nil)
        let ordinary = WindowConfig(id: UUID(), imagePath: url.path, originalImageName: url.lastPathComponent, contentKind: .audio)
        let standalone = await FoilInformation.details(config: ordinary, state: nil, windowSize: nil)
        for key in ["Foil Info Audio Codec", "Foil Info Sample Rate", "Foil Info Bit Depth", "Foil Info Channels"] {
            let value = try #require(standalone.rows.first { $0.key == key }?.value)
            #expect(details.rows.first { $0.key == key }?.value == value)
        }
    }

    @Test func mediaModeDescribesTheCurrentImageInsteadOfTheWholeList() async throws {
        let (root, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection(urls, roots: [root])
        let session = try #require(state.archiveSession)
        try await settle(session)
        session.setSidebarMode(.image)
        try await settle(session)
        state.activateAdjacentFileListItem(delta: 1)
        let config = try #require(FoilInformation.currentFileConfig(for: state))
        #expect(config.fileList == nil)
        #expect(config.historyMenuDisplayName == "two.tiff")
        let details = await FoilInformation.details(config: config, state: state.readingState, windowSize: nil)
        #expect(TestFileIdentity.equals(details.source, urls[1]))
        #expect(details.rows.contains { $0.key == "Foil Info Pixels" && $0.value == "20 × 30 px" })
        #expect(!details.rows.contains { $0.key == "Foil Info Items" })
        #expect(TestFileIdentity.equals(FoilInformation.sourceURL(for: state.toConfig()), root))
    }

    @Test func informationSheetHasSeparateEnabledFolderAndFileFinderActions() async throws {
        let (root, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection(urls, roots: [root])
        let session = try #require(state.archiveSession)
        try await settle(session)
        session.select(try #require(session.contribution.items.first { $0.title == "note.txt" }).id)
        let controller = FloatingWindowController(appState: state)
        defer { controller.close() }
        let window = try #require(controller.window)
        window.orderFront(nil)
        let delegate = AppDelegate()
        defer { NotificationCenter.default.removeObserver(delegate) }
        delegate.showFoilInformation(config: state.toConfig(), state: state, window: window)
        for _ in 0..<300 {
            if window.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sheet = try #require(window.attachedSheet)
        defer { window.endSheet(sheet) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(try #require(sheet.contentView))
        let scroll = try #require(views.compactMap { $0 as? NSScrollView }.first)
        #expect(scroll.hasVerticalScroller)
        #expect(!scroll.hasHorizontalScroller)
        #expect(scroll.horizontalScrollElasticity == .none)
        var proposed = scroll.contentView.bounds
        proposed.origin.x = 50
        #expect(scroll.contentView.constrainBoundsRect(proposed).origin.x == 0)
        let fields = views.compactMap { $0 as? NSTextField }.map(\.stringValue)
        let buttons = views.compactMap { $0 as? NSButton }
        #expect(fields.contains(NSLocalizedString("Foil Info Current File", comment: "")))
        #expect(fields.contains(NSLocalizedString("Foil Info Folder Path", comment: "")))
        #expect(fields.contains(NSLocalizedString("Foil Info File Path", comment: "")))
        #expect(buttons.contains { $0.toolTip == NSLocalizedString("Open Folder in Finder", comment: "") && $0.isEnabled })
        #expect(buttons.contains { $0.toolTip == NSLocalizedString("Show in Finder", comment: "") && $0.isEnabled })
        #expect(buttons.filter { $0.toolTip == NSLocalizedString("Change Title", comment: "") }.count == 1)
    }
}
