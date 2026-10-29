import AppKit
import Testing
import WebKit
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct DocumentReadingPositionTests {
    @Test func historyAndSettingsRoundTripReadingPositions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(isIncognito: true)
        state.openText("阅读正文", isMarkdown: false)
        let key = state.readingPositionKey("text")
        state.noteReadingPosition(.init(x: 12, y: 450), key: key)
        let encoded = try JSONEncoder().encode(state.toConfig())
        let config = try JSONDecoder().decode(WindowConfig.self, from: encoded)
        #expect(config.documentReadingPositions?[key]?.y == 450)
        let database = try HistoryDatabase(databaseURL: root.appendingPathComponent("history.sqlite3"))
        try database.upsert(config)
        let saved = try #require(try database.config(id: state.id))
        let restored = AppState(config: saved, isIncognito: true)
        #expect(restored.documentReadingPositions[key] == .init(x: 12, y: 450))
        restored.resetContent()
        #expect(restored.documentReadingPositions.isEmpty)
    }

    @Test func nativeScrollRestoresAndClampsShorterDocuments() async throws {
        let state = AppState(isIncognito: true)
        state.openText("document", isMarkdown: false)
        let key = state.readingPositionKey("text")
        state.noteReadingPosition(.init(x: 0, y: 700), key: key)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let body = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        scroll.documentView = body
        let tracker = DocumentScrollTracker()
        tracker.bind(scroll, state: state, surface: "text")
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(scroll.contentView.bounds.minY - 700) < 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
        #expect(state.documentReadingPositions[key]?.y == 900)
        body.frame.size.height = 500
        tracker.bind(scroll, state: state, surface: "text", contentChanged: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(scroll.contentView.bounds.minY <= 300)
    }

    @Test func reloadingTextKeepsSavedPosition() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = AppState(isIncognito: true)
        state.openTextFile(url: url)
        let key = state.readingPositionKey("text")
        state.noteReadingPosition(.init(x: 0, y: 640), key: key)
        try "updated".write(to: url, atomically: true, encoding: .utf8)
        await state.reloadContent()
        #expect(state.text == "updated")
        #expect(state.documentReadingPositions[key]?.y == 640)
        #expect(state.readingPositionKey("text") == key)
    }

    @Test func webScrollRestoresAfterPageReload() async throws {
        let state = AppState(isIncognito: true)
        state.openText("code", isMarkdown: false)
        let key = state.readingPositionKey("code")
        state.noteReadingPosition(.init(x: 0, y: 600), key: key)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tracker = WebDocumentScrollTracker()
        tracker.install(on: web, state: state, surface: "code")
        for _ in 0..<2 {
            tracker.beginLoading()
            web.loadHTMLString("<html><body style='height:4000px'>fixture</body></html>", baseURL: nil)
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(30))
                if !web.isLoading, (try? await web.evaluateJavaScript("document.body.scrollHeight")) as? Int == 4000 { break }
            }
            tracker.restore()
            try await Task.sleep(for: .milliseconds(100))
            let y = try await web.evaluateJavaScript("window.scrollY") as? Double
            #expect(y == 600)
            #expect(state.documentReadingPositions[key]?.y == 600)
        }
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
