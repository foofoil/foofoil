import Foundation
import Testing
@testable import foofoil

@MainActor
struct DirectFilePathTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Search did not reach expected state")
    }

    @Test func resolvesQuotedAndEscapedExistingPaths() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Report 2026.pdf")
        try Data("path".utf8).write(to: file)

        for input in [
            file.path,
            "\"\(file.path)\"",
            "'\(file.path)'",
            "\"\(file.path)'",
            "“\(file.path)”",
            "‘\(file.path)’",
            "「\(file.path)」",
            "『\(file.path)』",
            "《\(file.path)》",
            "`\(file.path)`",
            "\"“\(file.path)”\"",
            "  \"\(file.path)\"  "
        ] {
            let resolved = DirectFilePathResolver.resolve(input)
            #expect(resolved?.url.path == file.path, "Failed to resolve \(input)")
            #expect(resolved?.isDirectory == false)
        }

        // 终端拖入路径时会把空格写成反斜杠转义。
        let escaped = file.path.replacingOccurrences(of: " ", with: "\\ ")
        #expect(DirectFilePathResolver.resolve(escaped)?.url.path == file.path)
    }

    @Test func resolvesDirectoriesAndFileURLs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Notes 2026.txt")
        try Data("path".utf8).write(to: file)

        let folder = DirectFilePathResolver.resolve(directory.path)
        #expect(folder?.isDirectory == true)
        #expect(folder?.name == directory.lastPathComponent)
        #expect(folder?.symbolName == "folder")

        #expect(DirectFilePathResolver.resolve(file.absoluteString)?.url.path == file.path)
    }

    @Test func expandsLeadingTilde() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        #expect(DirectFilePathResolver.resolve("~")?.url.path == home.path)
        #expect(DirectFilePathResolver.resolve("~/")?.url.path == home.path)
        #expect(DirectFilePathResolver.resolve("'~/.'")?.url.path == home.path)
    }

    @Test func rejectsMissingAndRelativeInput() {
        #expect(DirectFilePathResolver.resolve("/definitely/missing-\(UUID().uuidString).txt") == nil)
        #expect(DirectFilePathResolver.resolve("Documents/\(UUID().uuidString).txt") == nil)
        #expect(DirectFilePathResolver.resolve("report 2026") == nil)
        #expect(DirectFilePathResolver.resolve("") == nil)
        #expect(DirectFilePathResolver.resolve("\"\"") == nil)
        #expect(DirectFilePathResolver.resolve("/") == nil)
    }

    @Test func pathLikeInputIsSeparateFromScopesAndURLs() {
        #expect(DirectFilePathResolver.looksLikePath("/Users/example/Documents/report.pdf"))
        #expect(DirectFilePathResolver.looksLikePath("\"/Users/example/Documents/report.pdf\""))
        #expect(DirectFilePathResolver.looksLikePath("~/Documents/report.pdf"))
        #expect(DirectFilePathResolver.looksLikePath("file:///Users/example/Documents/report.pdf"))
        // 单个 / 或 / 加一段过滤词仍是范围选择。
        #expect(!DirectFilePathResolver.looksLikePath("/"))
        #expect(!DirectFilePathResolver.looksLikePath("/f"))
        #expect(!DirectFilePathResolver.looksLikePath("/folder workspace"))
        #expect(!DirectFilePathResolver.looksLikePath("/文件"))
        #expect(!DirectFilePathResolver.looksLikePath("report 2026"))
        #expect(!DirectFilePathResolver.looksLikePath("example.com"))
    }

    @Test func existingPathBecomesFirstResultAndOpensByDefault() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Notes 2026.txt")
        try Data("path".utf8).write(to: file)

        var opened: URL?
        let model = HistorySearchViewModel(
            historySearch: { _ in [] },
            fileSearch: { _, completion in completion(.results([])) },
            cancelFiles: {},
            cameraAvailable: { false },
            musicEnabled: { false }
        )
        model.openFile = { opened = $0 }
        model.query = "\"\(file.path)\""

        #expect(model.directPath?.url.path == file.path)
        #expect(model.itemIDs.first == model.directPath?.id)
        #expect(model.selectedID == model.directPath?.id)
        #expect(model.selectedIndex == 0)
        #expect(model.openURL == nil)

        try await eventually { !model.isSearching }
        #expect(!model.showsOverallEmptyState)
        #expect(model.selectedID == model.directPath?.id)

        model.openSelected()
        #expect(opened?.path == file.path)
        model.stop()
    }

    @Test func directPathStaysSelectedAfterHistoryArrives() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Notes 2026.txt")
        try Data("path".utf8).write(to: file)
        let history = HistorySearchResult(
            id: UUID(), title: "Notes", contentKind: .text, thumbnailPath: nil,
            matchedSnippet: nil, matchedPageNumber: nil, score: 1, sourcePath: nil
        )
        let model = HistorySearchViewModel(
            historySearch: { _ in [history] },
            fileSearch: { _, completion in completion(.results([])) },
            cancelFiles: {},
            cameraAvailable: { false },
            musicEnabled: { false }
        )
        model.query = file.path
        #expect(model.selectedID == model.directPath?.id)

        try await eventually { !model.isHistorySearching }
        #expect(model.itemIDs.first == model.directPath?.id)
        #expect(model.selectedID == model.directPath?.id)
        model.stop()
    }

    @Test func urlModeDoesNotResolveLocalPaths() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Notes.txt")
        try Data("path".utf8).write(to: file)

        let model = HistorySearchViewModel(
            historySearch: { _ in [] },
            fileSearch: { _, completion in completion(.results([])) },
            cancelFiles: {},
            cameraAvailable: { false },
            musicEnabled: { false }
        )
        model.reset(mode: .url, initialQuery: file.path)
        #expect(model.directPath == nil)
        model.stop()
    }

    @Test func missingPathIsNotScopedOrTreatedAsURL() {
        let model = HistorySearchViewModel(
            historySearch: { _ in [] },
            fileSearch: { _, completion in completion(.results([])) },
            cancelFiles: {},
            cameraAvailable: { false },
            musicEnabled: { false }
        )

        model.query = "/\(UUID().uuidString)/missing.txt"
        #expect(model.directPath == nil)
        #expect(!model.isPickingScope)
        #expect(model.openURL == nil)

        model.query = "~/missing-\(UUID().uuidString).pdf"
        #expect(model.directPath == nil)
        #expect(model.openURL == nil)

        // “/” 与范围过滤词仍进入范围选择，不被路径识别抢占。
        model.query = "/"
        #expect(model.isPickingScope)
        model.query = "/f"
        #expect(model.isPickingScope)
        model.stop()
    }
}

@MainActor
struct DirectSearchActionTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-action-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExposeModel() -> FoilExposeModel {
        FoilExposeModel(items: [], historyItems: [], fileSearch: { _, _ in }, cancelFiles: {},
                        cameraAvailable: { false }, musicEnabled: { false })
    }

    @Test func sharedActionResolvesExistingPathsBeforeURLs() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Report 2026.pdf")
        try Data("path".utf8).write(to: file)

        guard case .file(let path)? = DirectSearchAction.resolve("'\(file.path)'") else {
            Issue.record("Existing path should resolve as a direct file action")
            return
        }
        #expect(path.url.path == file.path)
        #expect(DirectSearchAction.resolve("example.com") == .url(URL(string: "https://example.com")!))
        #expect(DirectSearchAction.resolve("\"https://example.com/path\"") == .url(URL(string: "https://example.com/path")!))
        #expect(DirectSearchAction.resolve("/\(UUID().uuidString)/missing.pdf") == nil)
        #expect(DirectSearchAction.resolve("report 2026") == nil)
    }

    @Test func exposeShowsPathAndURLActionsInScopeDropdown() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Expose Notes.txt")
        try Data("path".utf8).write(to: file)

        let model = makeExposeModel()
        var openedFile: URL?
        var openedURL: URL?
        model.onOpenFile = { openedFile = $0 }
        model.onOpenURL = { openedURL = $0 }

        model.searchText = "\"\(file.path)\""
        guard case .file(let path)? = model.directAction else {
            Issue.record("Exposé should expose the direct file action")
            return
        }
        #expect(path.url.path == file.path)
        #expect(model.isChoosingScope)
        #expect(!model.isPickingScope)
        model.selectHighlightedScope()
        #expect(openedFile?.path == file.path)

        model.searchText = "example.com"
        #expect(model.directAction == .url(URL(string: "https://example.com")!))
        #expect(model.isChoosingScope)
        #expect(!model.isPickingScope)
        model.selectHighlightedScope()
        #expect(openedURL?.absoluteString == "https://example.com")

        model.searchText = "/\(UUID().uuidString)/missing.txt"
        #expect(model.directAction == nil)
        #expect(!model.isChoosingScope)
        #expect(!model.isPickingScope)

        // “/” 与范围过滤词仍进入范围选择。
        model.searchText = "/"
        #expect(model.isChoosingScope)
        #expect(model.isPickingScope)
        model.stopFileSearch()
    }
}
