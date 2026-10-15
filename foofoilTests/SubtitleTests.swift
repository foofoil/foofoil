import Foundation
import Testing
@testable import foofoil

@MainActor @Suite(.serialized) struct SubtitleTests {
    @Test func srtTimingAndOverlap() throws {
        let raw = "1\r\n00:00:01,000 --> 00:00:03,000\r\n你好\r\n\r\n2\r\n00:00:02,000 --> 00:00:04,000\r\nWorld\r\n"
        let doc = try SubtitleDocument.parse(Data(raw.utf8), extension: "srt")
        #expect(doc.text(at: 0).isEmpty)
        #expect(doc.text(at: 1) == "你好")
        #expect(doc.text(at: 2) == "你好\nWorld")
        #expect(doc.text(at: 4).isEmpty)
    }
    @Test func assFormatAndCommaInText() throws {
        let raw = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.20,0:00:03.40,Default,,0,0,0,,{\\b1}Hello, world\\N你好"
        let doc = try SubtitleDocument.parse(Data(raw.utf8), extension: "ass")
        #expect(doc.text(at: 2) == "Hello, world\n你好")
    }
    @Test func vttSettingsAndUTF16() throws {
        let raw = "WEBVTT\n\n00:01.000 --> 00:03.000 align:center\n<b>Hello</b> &amp; goodbye\n"
        let doc = try SubtitleDocument.parse(try #require(raw.data(using: .utf16)), extension: "vtt")
        #expect(doc.text(at: 2) == "Hello & goodbye")
    }
    @Test func invalidSubtitleIsRejected() {
        #expect(throws: SubtitleError.self) { try SubtitleDocument.parse(Data("garbage".utf8), extension: "srt") }
    }
    @Test func historyDatabasePreservesSubtitleBookmarksAndHiddenSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        var association = SubtitleAssociation()
        association.files = [.init(path: "/tmp/movie.srt", bookmark: Data([1,2,3]))]
        association.selectedPath = "/tmp/movie.srt"
        let config = WindowConfig(id: UUID(), originalImageName: "movie.mp4", subtitleAssociations: ["/tmp/movie.mp4": association])
        #expect(repo.upsert(config))
        let saved = try #require(repo.recent(limit: 10).first)
        #expect(saved.subtitleAssociations == config.subtitleAssociations)
        let decoded = try JSONDecoder().decode(WindowConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.subtitleAssociations == config.subtitleAssociations)
    }
    @Test func themeChangePreservesGlobalTimingAndPosition() {
        let store = SubtitleStyleStore.shared
        let original = store.style
        defer { store.style = original }
        store.style.delay = 1.5; store.style.bottom = 12
        store.applyTheme(SubtitleStyle.themes.first { $0.0 == "Subtitle Warm Yellow" }!.1)
        #expect(store.style.delay == 1.5 && store.style.bottom == 12)
        #expect(store.style.color == "#FFE6A3")
    }
}

extension SubtitleTests {
    @Test func automaticMatchingSelectionAndRestore() async throws {
        let originalSaved = UserDefaults.standard.object(forKey: "video.subtitle.associations")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            if let originalSaved { UserDefaults.standard.set(originalSaved, forKey: "video.subtitle.associations") }
            else { UserDefaults.standard.removeObject(forKey: "video.subtitle.associations") }
        }
        let video = directory.appendingPathComponent("movie.mp4")
        let exact = directory.appendingPathComponent("movie.srt")
        let alternate = directory.appendingPathComponent("movie.en.vtt")
        try Data("1\n00:00:01,000 --> 00:00:03,000\n中文\n".utf8).write(to: exact)
        try Data("WEBVTT\n\n00:01.000 --> 00:03.000\nEnglish\n".utf8).write(to: alternate)
        let controller = VideoSubtitleController()
        await controller.prepare(video: video)
        #expect(controller.association.files.count == 2)
        #expect(controller.association.selectedPath == exact.path)
        #expect(controller.document?.text(at: 2) == "中文")
        let historyBeforeHide = controller.history
        var saves = 0
        controller.onChange = { saves += 1 }
        #expect(controller.hasLoadedSubtitle)
        controller.hide()
        #expect(controller.isHidden)
        #expect(controller.history == historyBeforeHide)
        #expect(saves == 0)
        controller.setVisible(true)
        #expect(!controller.isHidden)
        controller.hide()
        let saved = controller.history
        let restored = VideoSubtitleController()
        restored.restore(saved)
        await restored.prepare(video: video)
        #expect(!restored.isHidden)
        #expect(restored.association.selectedPath == exact.path)
        restored.selectFile(try #require(restored.association.files.first(where: { $0.path == alternate.path })))
        for _ in 0..<100 {
            if restored.association.selectedPath == alternate.path { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!restored.isHidden)
        #expect(restored.document?.text(at: 2) == "English")
    }
}

extension SubtitleTests {
    @Test func droppingSubtitleKeepsVideoAndPersistsSelection() async throws {
        let originalSaved = UserDefaults.standard.object(forKey: "video.subtitle.associations")
        let originalStyle = SubtitleStyleStore.shared.style
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            SubtitleStyleStore.shared.style = originalStyle
            if let originalSaved { UserDefaults.standard.set(originalSaved, forKey: "video.subtitle.associations") }
            else { UserDefaults.standard.removeObject(forKey: "video.subtitle.associations") }
        }
        let video = directory.appendingPathComponent("movie.mp4")
        let file = directory.appendingPathComponent("manual.srt")
        try Data("1\n00:00:01,000 --> 00:00:03,000\nDropped subtitle\n".utf8).write(to: file)
        let state = AppState()
        state.imageURL = video; state.originalImageName = video.lastPathComponent
        await state.subtitles.prepare(video: video)
        #expect(state.handleDroppedFileURLs([file]))
        for _ in 0..<100 {
            if state.subtitles.association.selectedPath == file.path { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.imageURL == video)
        #expect(state.isVideoDocument)
        #expect(state.toConfig().subtitleAssociations?[video.path]?.selectedPath == file.path)
        SubtitleStyleStore.shared.style.delay = 1
        #expect(state.subtitles.text(at: 1.5).isEmpty)
        #expect(state.subtitles.text(at: 2.5) == "Dropped subtitle")
        SubtitleStyleStore.shared.style.delay = -1
        #expect(state.subtitles.text(at: 0.5) == "Dropped subtitle")
        state.imageURL = nil
    }
}

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct SubtitleThemeTests {
    @Test func customThemesSaveOverwriteRestoreAndDelete() throws {
        let name = "subtitle-themes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SubtitleStyleStore(defaults: defaults)
        store.style = SubtitleStyle(font: "Helvetica", size: 60, color: "#ABCDEF", background: "#12345680",
                                    shadow: "#654321", bottom: 12, delay: 1.5, theme: "Custom")
        let saved = store.saveTheme(name: "  我的影院  ")
        #expect(saved.name == "我的影院")
        let restored = SubtitleStyleStore(defaults: defaults)
        #expect(restored.customThemes == [saved])
        restored.style.size = 72
        let replaced = restored.saveTheme(name: "我的影院", replacing: saved.id)
        #expect(replaced.id == saved.id)
        #expect(restored.customThemes.count == 1)
        #expect(replaced.style.size == 72)
        restored.applyTheme(SubtitleStyle.themes[0].1)
        restored.selectTheme(replaced)
        #expect(restored.style.size == 72)
        #expect(restored.style.bottom == 12)
        #expect(restored.style.delay == 1.5)
        restored.deleteTheme(id: saved.id)
        #expect(restored.style.theme == "Custom")
        #expect(restored.style.size == 72)
        #expect(SubtitleStyleStore(defaults: defaults).customThemes.isEmpty)
    }
}
