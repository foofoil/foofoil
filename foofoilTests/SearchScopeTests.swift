import AppKit
import Foundation
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct SearchScopeTests {
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Search did not reach expected state")
    }

    @Test func scopeAvailabilityFollowsMusicLibrarySetting() {
        let disabledScopes = SearchScope.availableScopes(musicLibraryEnabled: false)
        #expect(disabledScopes == [.clipboard, .history, .file, .folder, .url, .terminal, .camera, .enableMusic])

        let enabledScopes = SearchScope.availableScopes(musicLibraryEnabled: true)
        #expect(enabledScopes == [.clipboard, .history, .file, .folder, .url, .terminal, .camera, .album, .playlist, .song])

        #expect(SearchScope.history.displayName == "历史")
        #expect(SearchScope.file.displayName == "文件")
        #expect(SearchScope.folder.displayName == "目录")
        #expect(SearchScope.album.displayName == "Apple Music 专辑")
        #expect(SearchScope.album.symbolName == "music.pages")
        #expect(AppleMusicSearchCategory.albums.symbolName == "music.pages")
        #expect(SearchScope.playlist.displayName == "Apple Music 歌单")
        #expect(SearchScope.song.displayName == "Apple Music 歌曲")
    }

    @Test func disabledSourcesBecomeEnableActionsAtTheBottom() {
        #expect(SearchScope.availableScopes(musicLibraryEnabled: false, fileSearchEnabled: false)
            == [.clipboard, .history, .url, .terminal, .camera, .enableFiles, .enableMusic])
        #expect(SearchScope.availableScopes(musicLibraryEnabled: true, fileSearchEnabled: false)
            == [.clipboard, .history, .url, .terminal, .camera, .enableFiles, .album, .playlist, .song])
    }

    @Test func musicScopesRequireBothSettings() {
        for library in [false, true] {
            for search in [false, true] {
                let scopes = SearchScope.availableScopes(musicLibraryEnabled: library, musicSearchEnabled: search)
                #expect(scopes.contains(.song) == (library && search))
                #expect(scopes.contains(.enableMusic) == !(library && search))
            }
        }
    }

    @Test func enablingSourcesKeepsBothSearchMenusOpen() {
        let files = LocalFileSearchSettings.shared.isEnabled
        let music = SettingsStore.shared.appleMusicLibraryEnabled
        let musicSearch = UserDefaults.standard.bool(forKey: "appleMusicSearchEnabled")
        defer {
            LocalFileSearchSettings.shared.isEnabled = files
            SettingsStore.shared.appleMusicSearchEnabled = musicSearch
            SettingsStore.shared.appleMusicLibraryEnabled = music
        }
        for useExpose in [false, true] {
            LocalFileSearchSettings.shared.isEnabled = false
            SettingsStore.shared.appleMusicLibraryEnabled = false
            SettingsStore.shared.appleMusicSearchEnabled = false
            let quick = HistorySearchViewModel()
            let expose = FoilExposeModel(items: [], historyItems: [])
            quick.query = "/"
            expose.searchText = "/"
            #expect(quick.filteredScopes == expose.filteredScopes)
            if useExpose {
                expose.selectScope(.enableFiles)
                expose.selectScope(.enableMusic)
            } else {
                quick.selectScope(.enableFiles)
                quick.selectScope(.enableMusic)
            }
            #expect(LocalFileSearchSettings.shared.isEnabled)
            #expect(SettingsStore.shared.appleMusicLibraryEnabled)
            #expect(SettingsStore.shared.appleMusicSearchEnabled)
            #expect(quick.isPickingScope && expose.isPickingScope)
            #expect(quick.availableScopes.contains(.file) && expose.availableScopes.contains(.song))
            #expect(!quick.availableScopes.contains(.enableFiles))
            quick.stop()
            expose.stopFileSearch()
        }
    }

    @Test func scopeHighlightWrapsInBothSearchModels() {
        let quick = HistorySearchViewModel()
        let expose = FoilExposeModel(items: [], historyItems: [])
        defer { quick.stop(); expose.stopFileSearch() }
        quick.query = "/"
        expose.searchText = "/"
        let count = quick.filteredScopes.count
        #expect(count > 1 && expose.filteredScopes.count == count)
        quick.moveScopeSelection(by: -1)
        expose.moveScopeSelection(by: -1)
        #expect(quick.highlightedScopeIndex == count - 1)
        #expect(expose.highlightedScopeIndex == count - 1)
        quick.moveScopeSelection(by: 1)
        expose.moveScopeSelection(by: 1)
        #expect(quick.highlightedScopeIndex == 0)
        #expect(expose.highlightedScopeIndex == 0)

        quick.query = "/nonexistent-scope"
        expose.searchText = "/nonexistent-scope"
        #expect(quick.filteredScopes.isEmpty && expose.filteredScopes.isEmpty)
        quick.moveScopeSelection(by: -1)
        expose.moveScopeSelection(by: -1)
        #expect(quick.highlightedScopeIndex == 0 && expose.highlightedScopeIndex == 0)

        quick.query = "/clipboard"
        expose.searchText = "/clipboard"
        #expect(quick.filteredScopes.count == 1 && expose.filteredScopes.count == 1)
        quick.moveScopeSelection(by: -1)
        expose.moveScopeSelection(by: 1)
        #expect(quick.highlightedScopeIndex == 0 && expose.highlightedScopeIndex == 0)
    }

    @Test func urlOptionEntersInputAndClipboardEntersSearchScope() {
        let quick = HistorySearchViewModel()
        defer { quick.stop() }
        quick.query = "/"
        quick.selectScope(.url)
        #expect(quick.mode == .url && quick.query.isEmpty && quick.activeScope == nil)
        quick.reset()
        quick.query = "/"
        var quickAction: SearchScope?
        quick.openCommand = { quickAction = $0 }
        quick.selectScope(.clipboard)
        #expect(quickAction == nil && quick.activeScope == .clipboard)

        let expose = FoilExposeModel(items: [], historyItems: [], clipboardContent: .init(.text))
        defer { expose.stopFileSearch() }
        var exposeAction: SearchScope?
        expose.onOpenCommand = { exposeAction = $0 }
        expose.selectScope(.url)
        #expect(exposeAction == .url && expose.activeScope == nil)
        expose.selectScope(.clipboard)
        #expect(exposeAction == .url && expose.activeScope == .clipboard)
    }

    @Test func clipboardScopeIsAvailableEvenWhenCurrentClipboardIsEmpty() {
        let quick = HistorySearchViewModel()
        quick.query = "/"
        defer { quick.stop() }
        var executed = false
        quick.openCommand = { _ in executed = true }
        quick.selectScope(.clipboard)
        #expect(!executed && quick.isScopeEnabled(.clipboard) && quick.activeScope == .clipboard)
        let expose = FoilExposeModel(items: [], historyItems: [])
        defer { expose.stopFileSearch() }
        expose.onOpenCommand = { _ in executed = true }
        expose.selectScope(.clipboard)
        #expect(!executed && expose.isScopeEnabled(.clipboard) && expose.activeScope == .clipboard)
    }

    @Test func clipboardScopeExcludesOtherSourcesAndClearingRestoresSearch() async throws {
        var historyCalled = false
        var filesCalled = false
        let quick = HistorySearchViewModel(historySearch: { _ in historyCalled = true; return [] },
                                           fileSearch: { _, completion in filesCalled = true; completion(.results([])) })
        defer { quick.stop() }
        quick.selectScope(.clipboard)
        quick.query = "clipboard regression query"
        try await Task.sleep(for: .milliseconds(350))
        #expect(!historyCalled && !filesCalled)
        #expect(quick.directPath == nil && quick.openURL == nil)
        quick.clearActiveScope()
        try await eventually { historyCalled && filesCalled }
        #expect(quick.activeScope == nil && quick.query == "clipboard regression query")
    }

    @Test func openingCommandsExecuteWithoutActivatingScope() {
        for scope in [SearchScope.terminal, .camera] {
            let quickOpen = HistorySearchViewModel()
            var quickCommand: SearchScope?
            quickOpen.openCommand = { quickCommand = $0 }
            quickOpen.query = "/" + scope.englishName
            quickOpen.selectHighlightedScope()
            #expect(quickCommand == scope)
            #expect(quickOpen.activeScope == nil)

            let expose = FoilExposeModel(items: [], historyItems: [])
            var exposeCommand: SearchScope?
            expose.onOpenCommand = { exposeCommand = $0 }
            expose.searchText = "/" + scope.englishName
            expose.selectHighlightedScope()
            #expect(exposeCommand == scope)
            #expect(expose.activeScope == nil)
            #expect(scope.matches(filter: scope == .terminal ? "终端" : "摄像头"))
        }
    }

    @Test func scopeMatchingSupportsChineseEnglishAndPinyin() {
        let allScopes = SearchScope.availableScopes(musicLibraryEnabled: true)

        // 空过滤词匹配所有范围
        #expect(allScopes.filter { $0.matches(filter: "") } == allScopes)

        // 中文匹配
        #expect(allScopes.filter { $0.matches(filter: "历史") } == [.history])
        #expect(allScopes.filter { $0.matches(filter: "文") } == [.file])
        #expect(allScopes.filter { $0.matches(filter: "目录") } == [.folder])
        #expect(allScopes.filter { $0.matches(filter: "专辑") } == [.album])
        #expect(allScopes.filter { $0.matches(filter: "歌单") } == [.playlist])
        #expect(allScopes.filter { $0.matches(filter: "歌曲") } == [.song])

        // 英文匹配与大小写不敏感
        #expect(allScopes.filter { $0.matches(filter: "his") } == [.history])
        #expect(allScopes.filter { $0.matches(filter: "FILE") } == [.file])
        #expect(allScopes.filter { $0.matches(filter: "Folder") } == [.folder])
        #expect(allScopes.filter { $0.matches(filter: "album") } == [.album])
        #expect(allScopes.filter { $0.matches(filter: "play") } == [.playlist])
        #expect(allScopes.filter { $0.matches(filter: "SONG") } == [.song])

        // 拼音缩写匹配
        #expect(allScopes.filter { $0.matches(filter: "ls") } == [.history])
        #expect(allScopes.filter { $0.matches(filter: "wj") } == [.file])
        #expect(allScopes.filter { $0.matches(filter: "ml") } == [.folder])
        #expect(allScopes.filter { $0.matches(filter: "zj") } == [.album])
        #expect(allScopes.filter { $0.matches(filter: "gd") } == [.terminal, .playlist])
        #expect(allScopes.filter { $0.matches(filter: "gq") } == [.song])

        // 前缀缩小范围包含多项时保留顺序
        let fScopes = allScopes.filter { $0.matches(filter: "f") }
        #expect(fScopes == [.file, .folder])
    }

    @Test func historySearchScopePickingAndFolderTargetWorkflow() async throws {
        let previousFileSearch = LocalFileSearchSettings.shared.isEnabled
        defer { LocalFileSearchSettings.shared.isEnabled = previousFileSearch }
        LocalFileSearchSettings.shared.isEnabled = true
        var searchedTarget: SpotlightSearchTarget?
        var searchedFileTerm: String?

        let model = HistorySearchViewModel(
            historySearch: { _ in [] },
            targetFileSearch: { term, target, completion in
                searchedFileTerm = term
                searchedTarget = target
                completion(.results([]))
            },
            cameraAvailable: { false },
            musicSearch: { _ in [] },
            musicAuthorized: { false },
            musicEnabled: { false }
        )

        // 键入 / 进入范围选择模式
        model.query = "/"
        #expect(model.isPickingScope)
        #expect(model.scopeFilterText == "")
        #expect(model.highlightedScopeIndex == 0)
        #expect(!model.filteredScopes.isEmpty)

        // 输入拼音缩小范围
        model.query = "/f"
        #expect(model.isPickingScope)
        #expect(model.scopeFilterText == "f")
        #expect(model.filteredScopes == [.file, .folder])
        #expect(model.highlightedScopeIndex == 0) // 始终高亮第一项

        // 移动高亮项
        model.moveScopeSelection(by: 1)
        #expect(model.highlightedScopeIndex == 1)

        // 回车选择高亮项（目录）
        model.selectHighlightedScope()
        #expect(!model.isPickingScope)
        #expect(model.activeScope == .folder)
        #expect(model.resultFilter == .folders)
        #expect(model.query == "") // 清空后等待用户继续输入具体关键字

        // 用户输入具体关键字
        model.query = "workspace"
        try await eventually { searchedFileTerm == "workspace" }
        #expect(searchedTarget == .folders) // 目录限定范围调用 Spotlight 目录搜索

        // 清除 activeScope
        model.clearActiveScope()
        #expect(model.activeScope == nil)
        #expect(model.resultFilter == .all)
    }

    @Test func historySearchScopeSelectingWithSpaceToken() async throws {
        let model = HistorySearchViewModel(
            historySearch: { _ in [] },
            targetFileSearch: { _, _, completion in completion(.results([])) },
            cameraAvailable: { false }
        )

        // 用户快速输入 "/folder workspace"（带空格分隔）自动识别范围
        model.query = "/folder workspace"
        #expect(model.activeScope == .folder)
        #expect(model.resultFilter == .folders)
        #expect(model.query == "workspace")
    }

    @Test func exposeScopePickingAndSelectingWorkflow() async throws {
        let previousFileSearch = LocalFileSearchSettings.shared.isEnabled
        defer { LocalFileSearchSettings.shared.isEnabled = previousFileSearch }
        LocalFileSearchSettings.shared.isEnabled = true
        var searchedTarget: SpotlightSearchTarget?
        var searchedFileTerm: String?

        let model = FoilExposeModel(
            items: [],
            historyItems: [],
            targetFileSearch: { term, target, completion in
                searchedFileTerm = term
                searchedTarget = target
                completion(.results([]))
            },
            cameraAvailable: { false },
            musicSearch: { _ in [] },
            musicAuthorized: { false },
            musicEnabled: { false }
        )

        // 第一次 / 触发搜索模式，此时 searchText 为空，不进入分类选择
        model.beginSearch()
        #expect(model.isSearching)
        #expect(model.searchText == "")
        #expect(!model.isPickingScope)

        // 第二次 /（在搜索输入框中键入 /）触发分类选择
        model.searchText = "/"
        #expect(model.isPickingScope)
        #expect(model.scopeFilterText == "")
        #expect(model.highlightedScopeIndex == 0)

        // 中文缩小范围
        model.searchText = "/文件"
        #expect(model.isPickingScope)
        #expect(model.filteredScopes == [.file])
        #expect(model.highlightedScopeIndex == 0)

        // 回车选中高亮范围
        model.selectHighlightedScope()
        #expect(!model.isPickingScope)
        #expect(model.activeScope == .file)
        #expect(model.resultFilter == .files)
        #expect(model.searchText == "")

        // 输入搜索词
        model.searchText = "invoice"
        try await eventually { searchedFileTerm == "invoice" }
        #expect(searchedTarget == .files)

        // 清除搜索恢复初始状态
        model.clearSearch()
        #expect(model.activeScope == nil)
        #expect(model.resultFilter == .all)
        #expect(model.searchText.isEmpty)
        #expect(model.isSearching) // 总览始终提供搜索，清除只重置查询与范围。
    }

    @Test func spotlightFolderPredicateAndResultMetadata() {
        let folderPredicate = SpotlightFileSearch.predicate(for: "project swift", target: .folders)
        let filePredicate = SpotlightFileSearch.predicate(for: "project swift", target: .files)
        #expect(folderPredicate.predicateFormat.contains("public.folder"))
        #expect(filePredicate.predicateFormat.contains("NOT kMDItemContentType == \"public.folder\""))

        let folderURL = URL(fileURLWithPath: "/Users/test/Documents/Projects")
        let folderResult = SpotlightFileResult(url: folderURL, modifiedAt: Date(), isDirectory: true)
        #expect(folderResult.isDirectory)
        #expect(folderResult.symbolName == "folder")

        let fileURL = URL(fileURLWithPath: "/Users/test/Documents/Projects/main.swift")
        let fileResult = SpotlightFileResult(url: fileURL, modifiedAt: Date(), isDirectory: false)
        #expect(!fileResult.isDirectory)
        #expect(fileResult.symbolName == "doc")
    }

    @Test func spotlightAllTargetSearchesFilesAndFolders() {
        let allPredicate = SpotlightFileSearch.predicate(for: "project swift", target: .all)
        #expect(!allPredicate.predicateFormat.contains("kMDItemContentType"))

        let home = LocalFileSearchSettings.userHome.path
        #expect(allPredicate.evaluate(with: [
            "kMDItemFSName": "project swift folder",
            "kMDItemContentType": "public.folder",
            "kMDItemPath": "\(home)/Documents/project swift folder"
        ]))
        #expect(allPredicate.evaluate(with: [
            "kMDItemFSName": "project swift file.swift",
            "kMDItemContentType": "public.plain-text",
            "kMDItemPath": "\(home)/Documents/project swift file.swift"
        ]))

        #expect(SearchResultFilter.all.target == .all)
        #expect(SearchResultFilter.files.target == .files)
        #expect(SearchResultFilter.folders.target == .folders)
        #expect(SearchResultFilter.all.fileSectionLocalizationKey == "Local Files and Folders Section")
        #expect(SearchResultFilter.files.fileSectionLocalizationKey == "Local Files Section")
        #expect(SearchResultFilter.folders.fileSectionLocalizationKey == "Local Folders Section")
        #expect(SearchResultFilter.all.moreFilesLocalizationKey == "Search More Files and Folders")
        #expect(SearchResultFilter.all.searchingFilesLocalizationKey == "Searching Local Files and Folders")
        #expect(SearchResultFilter.all.noFilesLocalizationKey == "No Local Files and Folders Results")
    }

    @Test func tabKeySelectsHighlightedScopeInHistorySearchPanel() {
        let model = HistorySearchViewModel(
            historySearch: { _ in [] },
            cameraAvailable: { false }
        )
        let panel = HistorySearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.searchModel = model

        model.query = "/"
        #expect(model.isPickingScope)
        #expect(model.highlightedScopeIndex == 0)
        let firstScope = model.filteredScopes[0]

        let tabEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        )!
        panel.sendEvent(tabEvent)

        #expect(!model.isPickingScope)
        #expect(model.activeScope == firstScope)
        #expect(model.query == "")
    }

    @Test func ctrlNAndCtrlPSelectScopeInHistorySearchPanel() {
        let model = HistorySearchViewModel(
            historySearch: { _ in [] },
            cameraAvailable: { false }
        )
        let panel = HistorySearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.searchModel = model

        model.query = "/"
        #expect(model.isPickingScope)
        #expect(model.highlightedScopeIndex == 0)

        // Ctrl+N 移动到下一项
        let ctrlNEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\u{0e}",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        )!
        panel.sendEvent(ctrlNEvent)
        #expect(model.highlightedScopeIndex == 1)

        // Ctrl+P 移动回上一项
        let ctrlPEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\u{10}",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        )!
        panel.sendEvent(ctrlPEvent)
        #expect(model.highlightedScopeIndex == 0)
    }

    @Test func ctrlNAndCtrlPSelectScopeInFoilExposeController() {
        let controller = FoilExposeController.shared
        let originalModel = controller.model
        defer { controller.model = originalModel }

        let model = FoilExposeModel(
            items: [],
            historyItems: [],
            cameraAvailable: { false }
        )
        controller.model = model

        model.beginSearch()
        model.searchText = "/"
        #expect(model.isPickingScope)
        #expect(model.highlightedScopeIndex == 0)

        // Ctrl+N 移动到下一项
        let ctrlNEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{0e}",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        )!
        _ = controller.handleKeyEvent(ctrlNEvent)
        #expect(model.highlightedScopeIndex == 1)

        // Ctrl+P 移动回上一项
        let ctrlPEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{10}",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        )!
        _ = controller.handleKeyEvent(ctrlPEvent)
        #expect(model.highlightedScopeIndex == 0)
    }
}
