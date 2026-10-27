import AppKit
import Foundation
import Testing
@testable import foofoil

@MainActor
struct ClipboardHistorySearchTests {
    private func entry(_ id: String, _ text: String) -> ClipboardSearchEntry {
        .init(id: id, title: text, searchText: text, content: .text(text), date: Date())
    }
    private func waitForLoad(_ search: ClipboardHistorySearch) async throws {
        for _ in 0..<100 {
            if !search.isLoading { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Clipboard load did not finish")
    }
    @Test func unauthorizedShowsOnlyCurrentAndFiltersIt() async throws {
        let current = entry("current", "Today’s clipboard")
        let history = entry("old", "Old history")
        let search = ClipboardHistorySearch(load: { .init(access: .needsAuthorization, entries: [history]) }, currentContent: { current })
        defer { search.stop() }
        search.search("")
        try await waitForLoad(search)
        #expect(search.access == .needsAuthorization)
        #expect(search.entries.map(\.id) == [current.id])
        #expect(search.entries.first?.isCurrentClipboard == true)
        search.search("Old")
        #expect(search.entries.isEmpty)
        search.search("CLIPBOARD")
        #expect(search.entries.map(\.id) == [current.id])
        #expect(search.entries.first?.isCurrentClipboard == true)
    }
    @Test func authorizedSearchesBodyAndDeduplicatesCurrent() async throws {
        let current = entry("current", "same body")
        let history = entry("old", "same body")
        let another = ClipboardSearchEntry(id: "another", title: "Title", searchText: "Title\nHidden full body", content: .text("Hidden full body"), date: Date())
        let search = ClipboardHistorySearch(load: { .init(access: .available, entries: [history, another]) }, currentContent: { current })
        defer { search.stop() }
        search.search("")
        try await waitForLoad(search)
        #expect(search.entries.map(\.id) == ["old", "another"])
        search.search("hidden BODY")
        #expect(search.entries.map(\.id) == ["another"])
        #expect(search.entries.first?.content == .text("Hidden full body"))
        search.stop()
        #expect(search.entries.isEmpty)
    }
    @Test func noCurrentClipboardStillAllowsHistoricalResults() async throws {
        let history = entry("old", "Historical text")
        let search = ClipboardHistorySearch(load: { .init(access: .available, entries: [history]) }, currentContent: { nil })
        defer { search.stop() }
        search.search("Historical")
        try await waitForLoad(search)
        #expect(search.entries == [history])
        #expect(!SearchScope.clipboard.isOpeningCommand)
        #expect(SearchScope.clipboard.displayName == NSLocalizedString("Clipboard Search Scope", comment: ""))
    }

    @Test func refreshingAfterAuthorizationReplacesTheFallback() async throws {
        actor Loader {
            var calls = 0
            let history: ClipboardSearchEntry
            init(_ history: ClipboardSearchEntry) { self.history = history }
            func load() -> ClipboardHistorySnapshot {
                calls += 1
                return .init(access: calls == 1 ? .needsAuthorization : .available, entries: [history])
            }
        }
        let loader = Loader(entry("history", "Older body"))
        let search = ClipboardHistorySearch(load: { await loader.load() }, currentContent: { nil })
        defer { search.stop() }
        search.search("")
        try await waitForLoad(search)
        #expect(search.access == .needsAuthorization && search.entries.isEmpty)
        search.refresh()
        try await waitForLoad(search)
        #expect(search.access == .available && search.entries.map(\.id) == ["history"])
    }

    @Test func copyingAnOlderEntryUpdatesOnlyTheChosenPasteboardAndCurrentMarker() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Current text", forType: .string)
        let old = entry("old", "Older multiline\ncontent")
        let search = ClipboardHistorySearch(load: { .init(access: .available, entries: [old]) },
                                            currentContent: { .current(pasteboard: pasteboard) })
        defer { search.stop() }
        search.search("")
        try await waitForLoad(search)
        #expect(search.entries.first?.isCurrentClipboard == true)
        #expect(search.entries.first(where: { $0.id == "old" })?.isCurrentClipboard == false)
        #expect(search.copy(old, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "Older multiline\ncontent")
        #expect(search.entries.map(\.id) == ["old"])
        #expect(search.entries.first?.isCurrentClipboard == true)
    }

    @Test func copyingImagePreservesItsBytesAndCurrentMarker() async throws {
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let old = ClipboardSearchEntry(id: "image", title: "Image", searchText: "Image", content: .image(data), date: Date())
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let search = ClipboardHistorySearch(load: { .init(access: .available, entries: [old]) },
                                            currentContent: { .current(pasteboard: pasteboard) })
        defer { search.stop() }
        search.search("")
        try await waitForLoad(search)
        #expect(search.copy(old, to: pasteboard))
        #expect(pasteboard.data(forType: .png) == data)
        #expect(old.imageFilenameExtension == "png")
        #expect(search.entries.count == 1 && search.entries.first?.isCurrentClipboard == true)
    }

    /// 构造最小 dbStr + 未压缩 LZ4 帧，验证字段恢复及损坏边界；不读取用户历史。
    @Test func nativeStoreRestoresTextAndRejectsTruncatedPages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func word(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        func integer(_ value: Int) -> Data {
            if value < 0x80 { return Data([UInt8(value)]) }
            if value < 0x4000 { return Data([0x80 | UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]) }
            return Data([0xc0 | UInt8(value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        func string(_ value: String) -> Data { let data = Data(value.utf8) + Data([0]); return integer(data.count) + data }
        let keys = ["_kMDItemDomainIdentifier", "_kMDItemExternalID", "kMDItemTitle", "kMDItemDescription", "kMDItemContentCreationDate", "kMDItemContentType"]
        for number in [1, 2, 4, 5] {
            var data = Data([0, 0]), offsets = word(0)
            if number == 1 {
                for (index, key) in keys.enumerated() {
                    offsets += word(data.count)
                    let value = Data([index == 4 ? 12 : 11, 0]) + Data(key.utf8) + Data([0])
                    data += integer(value.count) + value
                }
            }
            var header = Data(count: 56)
            header.replaceSubrange(20..<24, with: word(data.count))
            header.replaceSubrange(28..<32, with: word(offsets.count / 4))
            for (ext, contents) in [("header", header), ("offsets", offsets), ("data", data)] {
                try contents.write(to: directory.appendingPathComponent("dbStr-\(number).map.\(ext)"))
            }
        }
        var body = Data([1, 0, 1, 0, 0])
        for text in ["com.apple.spotlight.pasteboard.text", "fixture-id", "Short title", String(repeating: "Full body ", count: 40)] { body += Data([1]) + string(text) }
        let seconds = Date().timeIntervalSinceReferenceDate.bitPattern
        body += Data([1]) + Data((0..<8).map { UInt8(truncatingIfNeeded: seconds >> ($0 * 8)) })
        body += Data([1]) + string("public.utf8-plain-text")
        let payload = word(body.count) + body
        let frame = Data("bv4-".utf8) + word(payload.count) + payload + Data("bv4$".utf8)
        var database = Data(count: 3 * 4096)
        database.replaceSubrange(0..<4, with: Data("8tsd".utf8))
        for (offset, value) in [(4, 0x10000), (36, 4096), (40, 4096), (44, 4096), (4104, 1), (4124, 2), (8200, 20 + frame.count), (8204, 0x1009), (8208, 20 + payload.count)] {
            database.replaceSubrange(offset..<(offset + 4), with: word(value))
        }
        database.replaceSubrange(8212..<(8212 + frame.count), with: frame)
        let url = directory.appendingPathComponent(".store.db")
        try database.write(to: url)
        var reader = SpotlightClipboardStore()
        let records = try reader.read(directory: directory)
        #expect(records.count == 1)
        #expect(records.first?.identifier == "fixture-id")
        #expect(records.first?.text == String(repeating: "Full body ", count: 40))
        try database.prefix(8300).write(to: url)
        #expect(throws: (any Error).self) { var broken = SpotlightClipboardStore(); _ = try broken.read(directory: directory) }
    }
}
