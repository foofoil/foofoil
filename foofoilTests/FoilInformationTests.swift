import AppKit
import AVFoundation
import Foundation
import Testing
@testable import foofoil

@MainActor
struct FoilInformationTests {
    @Test func audioRowsShowAvailableTagsAndSourceProperties() {
        var info = AudioTrackInfo.fallback(fileName: "fallback.wav")
        info.taggedTitle = "Track"
        info.album = "Album"
        info.artist = "Artist"
        info.albumArtist = "Album Artist"
        info.composer = "Composer"
        info.genre = "Classical"
        info.year = "2024"
        info.trackNumber = "3"
        info.codecName = "PCM"
        info.sampleRate = 48000
        info.bitDepth = 24
        info.bitRate = 2304000
        info.channelCount = 2
        let rows = Dictionary(uniqueKeysWithValues: FoilInformation.audioRows(info).map { ($0.key, $0.value) })
        #expect(rows["Foil Info Track Title"] == "Track")
        #expect(rows["Foil Info Album Artist"] == "Album Artist")
        #expect(rows["Foil Info Composer"] == "Composer")
        #expect(rows["Foil Info Audio Codec"] == "PCM")
        #expect(rows["Foil Info Sample Rate"] == AudioMetadataLoader.formatSampleRate(48000))
        #expect(rows["Foil Info Bit Depth"] == AudioMetadataLoader.formatBitDepth(24))
        #expect(rows["Foil Info Bit Rate"] == AudioMetadataLoader.formatBitRate(2304000))
        #expect(rows["Foil Info Channels"] == AudioMetadataLoader.formatChannels(2))
        let empty = FoilInformation.audioRows(.fallback(fileName: "untagged.mp3"))
        #expect(empty.isEmpty)
    }

    @Test func audioDetailsReadSourceFileProperties() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            try file.write(from: buffer)
        }
        let config = WindowConfig(id: UUID(), imagePath: url.path, originalImageName: url.lastPathComponent, contentKind: .audio)
        let details = await FoilInformation.details(config: config, state: nil, windowSize: nil)
        let rows = Dictionary(uniqueKeysWithValues: details.rows.map { ($0.key, $0.value) })
        #expect(rows["Foil Info Audio Codec"] == "PCM")
        #expect(rows["Foil Info Sample Rate"] == AudioMetadataLoader.formatSampleRate(48000))
        #expect(rows["Foil Info Channels"] == AudioMetadataLoader.formatChannels(2))
        #expect(rows["Foil Info Track Title"] == nil)
        let cue = FileListCueInfo(startCueFrames: 0, title: "Cue track", artist: "Cue artist")
        let cueDetails = await FoilInformation.details(config: config, state: nil, windowSize: nil, audioCue: cue)
        #expect(cueDetails.rows.contains { $0.key == "Foil Info Track Title" && $0.value == "Cue track" })
        #expect(cueDetails.rows.contains { $0.key == "Foil Info Artist" && $0.value == "Cue artist" })
    }

    @Test func informationShortcutIsConfigurable() throws {
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "file.showInformation"))
        let defaultShortcut = KeyboardShortcut(keyEquivalent: "i", modifiers: [.command, .shift])
        #expect(definition.defaultShortcut == defaultShortcut)
        #expect(KeyboardShortcutCatalog.file.contains { $0.id == definition.id })

        let store = KeyboardShortcutStore.shared
        let wasCustomized = store.isCustomized(definition)
        let previous = store.shortcut(for: definition)
        defer {
            if wasCustomized { store.setShortcut(previous, for: definition) }
            else { store.reset(definition) }
        }
        store.reset(definition)
        let item = NSMenuItem(title: "", action: #selector(AppDelegate.showFoilInformationAction), keyEquivalent: "")
        item.representedObject = definition.id
        let menu = NSMenu()
        menu.addItem(item)
        let delegate = AppDelegate()
        delegate.applyKeyboardShortcuts(to: menu)
        #expect(item.keyEquivalent == "i")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])

        let custom = KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .option])
        #expect(store.setShortcut(custom, for: definition))
        delegate.applyKeyboardShortcuts(to: menu)
        #expect(item.keyEquivalent == "j")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
    }

    @Test func blankFoilCannotShowInformation() {
        _ = NSApplication.shared
        let state = AppState()
        let controller = FloatingWindowController(appState: state)
        let delegate = AppDelegate()
        delegate.windowControllers = [controller]
        delegate.activeWindowProvider = { controller.window }
        controller.window?.orderFront(nil)
        defer { controller.window?.orderOut(nil) }
        let menuItem = NSMenuItem(title: "", action: #selector(AppDelegate.showFoilInformationAction), keyEquivalent: "")
        let item = FoilExposeItem(id: state.id, controller: controller, isHistoryEntry: false, title: "", symbolName: "", contentKind: .note, thumbnailPath: nil)
        #expect(!delegate.validateMenuItem(menuItem))
        #expect(!item.canShowInformation)
        delegate.showFoilInformationAction()
        #expect(controller.window?.attachedSheet == nil)

        state.text = "Content"
        #expect(delegate.validateMenuItem(menuItem))
        #expect(item.canShowInformation)
    }

    @Test func cameraAndEmptyFoilsRejectTitleChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let configs = [WindowConfig(id: UUID()),
                       WindowConfig(id: UUID(), text: " \n ", contentKind: .note),
                       WindowConfig(id: UUID(), isCamera: true, contentKind: .camera),
                       WindowConfig(id: UUID(), imagePath: "/tmp/frame.png", contentKind: .camera)]
        for config in configs {
            #expect(!config.canRenameTitle)
            #expect(repository.upsert(config))
            repository.rename(id: config.id, title: "Rejected")
            #expect(repository.config(id: config.id)?.customTitle == nil)
            let state = AppState(config: config)
            state.applyFoilTitle("Rejected")
            #expect(state.customTitle == nil)
        }
        #expect(WindowConfig(id: UUID(), textPath: "/tmp/empty.txt").canRenameTitle)
        #expect(WindowConfig(id: UUID(), text: "Content").canRenameTitle)
    }

    @Test func renamedHistoryPreservesSourcesAndSurvivesSaveAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let repository = HistoryRepository(databaseURL: url)
        let configs = [
            WindowConfig(id: UUID(), imagePath: "/tmp/source.png", originalImageName: "source.png", imageSource: .clipboard, contentKind: .image),
            WindowConfig(id: UUID(), webURLString: "https://example.com", originalImageName: "Original page", contentKind: .web),
            WindowConfig(id: UUID(), originalImageName: "source.csv", text: "a,b", textPath: "/tmp/source.csv", contentKind: .csv),
            WindowConfig(id: UUID(), originalImageName: "source.md", text: "# Heading", contentKind: .markdown),
            WindowConfig(id: UUID(), contentKind: .terminal, terminalConfiguration: .init())
        ]
        for config in configs {
            #expect(repository.upsert(config))
            let originalTitle = try #require(repository.config(id: config.id)).historyMenuDisplayName
            repository.rename(id: config.id, title: "  自定义标题  ")
            let renamed = try #require(repository.config(id: config.id))
            #expect(renamed.customTitle == "自定义标题")
            #expect(renamed.historyMenuDisplayName == "自定义标题")
            #expect(renamed.originalImageName == config.originalImageName)
            #expect(renamed.contentKind == config.contentKind)
            #expect(renamed.textPath == config.textPath)
            #expect(renamed.webURLString == config.webURLString)
            #expect(repository.upsert(renamed))
            let reopened = HistoryRepository(databaseURL: url)
            #expect(reopened.config(id: config.id)?.historyMenuDisplayName == "自定义标题")
            repository.rename(id: config.id, title: "  ")
            #expect(repository.config(id: config.id)?.customTitle == nil)
            #expect(repository.config(id: config.id)?.historyMenuDisplayName == originalTitle)
        }
        #expect((await repository.search("自定义标题")).isEmpty)
    }

    @Test func activeTitleRoundTripsWithoutChangingFilenameAndResetClearsIt() throws {
        let state = AppState()
        state.isBatchUpdating = true
        state.originalImageName = "source.csv"
        state.text = "a,b"
        state.applyFoilTitle(" 自定义标题 ")
        let config = state.toConfig()
        #expect(config.historyMenuDisplayName == "自定义标题")
        #expect(config.originalImageName == "source.csv")
        let decoded = try JSONDecoder().decode(WindowConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.customTitle == "自定义标题")
        let restored = AppState(config: decoded)
        #expect(restored.toConfig().historyMenuDisplayName == "自定义标题")
        #expect(restored.originalImageName == "source.csv")
        state.applyFoilTitle("  ")
        #expect(state.customTitle == nil)
        state.applyFoilTitle("Reset me")
        state.resetContent()
        #expect(state.customTitle == nil)
    }

    @Test func prefersOriginalSourceOverCacheAndRejectsCacheSource() throws {
        let cache = try #require(AppState.getFoofoilDirectoryURL()).appendingPathComponent("cached_image_test.pdf")
        let original = URL(fileURLWithPath: "/Users/example/Documents/original.pdf")
        let config = WindowConfig(id: UUID(), imagePath: cache.path, sourceFingerprint: "file:\(original.path)")
        #expect(FoilInformation.sourceURL(for: config) == original)
        let cachedConfig = WindowConfig(id: UUID(), imagePath: cache.path)
        #expect(FoilInformation.sourceURL(for: cachedConfig) == nil)
    }

    @Test func missingOriginalRetainsPathAndReportsUnavailableSize() async throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = WindowConfig(id: UUID(), sourceFingerprint: "file:\(original.path)")
        #expect(FoilInformation.sourceURL(for: config) == original)
        let metadata = await FoilInformation.fileRows(source: original, contentURL: nil, kind: .pdf)
        #expect(!metadata.available)
        #expect(metadata.rows.contains { $0.key == "Foil Info File Status" })
        #expect(metadata.rows.contains { $0.key == "Foil Info File Size" })
    }

    @Test func visitsPersistAndWebDeduplicationKeepsFirstVisit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let oldID = UUID()
        #expect(repository.upsert(WindowConfig(id: oldID, webURLString: "https://example.com", createdAt: first)))
        let newID = UUID()
        #expect(repository.upsert(WindowConfig(id: newID, webURLString: "https://example.com", createdAt: Date())))
        let dates = try #require(repository.visitDates(id: newID))
        #expect(dates.first == first)
        repository.touch(id: newID)
        #expect(try #require(repository.visitDates(id: newID)).last >= dates.last)
        let reopened = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        #expect(reopened.visitDates(id: newID)?.first == first)
    }
}
