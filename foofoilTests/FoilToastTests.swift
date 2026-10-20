import Foundation
import Testing
@testable import foofoil

@MainActor
struct FoilToastTests {
    @Test func newerMessageSurvivesPreviousDeadlineAndRepeatedTextRestartsPresentation() async throws {
        let center = FoilToastCenter()
        center.show("First", duration: .milliseconds(10))
        center.show("Second", symbolName: "bookmark.fill", duration: .seconds(5))
        let second = try #require(center.message)
        try await Task.sleep(for: .milliseconds(80))
        #expect(center.message == second)
        center.show("Second", symbolName: "bookmark.fill", duration: .seconds(5))
        #expect(center.message?.id != second.id)
        #expect(center.message?.text == second.text)
        center.dismiss()
    }

    @Test func automaticAndExplicitDismissalDoNotAffectOtherHosts() async throws {
        let first = FoilToastCenter()
        let second = FoilToastCenter()
        first.show("Short", duration: .milliseconds(10))
        second.show("Independent", duration: .seconds(5))
        for _ in 0..<100 {
            if first.message == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.message == nil)
        #expect(second.message?.text == "Independent")
        second.dismiss()
        #expect(second.message == nil)
    }

    @Test func navigatorHideExplainsHowToRestoreAndOnlyHidingShowsToast() throws {
        let state = AppState()
        state.setNavigatorPanelVisibilityMode(.always)
        #expect(state.toast.message == nil)
        state.setNavigatorPanelVisibilityMode(.onHover)
        #expect(state.toast.message == nil)
        state.setNavigatorPanelVisibilityMode(.hidden)
        let message = try #require(state.toast.message)
        if let shortcut = KeyboardShortcutStore.shared.shortcut(forID: "view.toggleNavigator") {
            #expect(message.text == String(format: NSLocalizedString("Navigator Hidden Shortcut Toast", comment: ""), shortcut.displayString))
        } else {
            #expect(message.text == NSLocalizedString("Navigator Hidden Menu Toast", comment: ""))
        }
        state.toast.dismiss()
        state.setNavigatorPanelVisibilityMode(.hidden)
        #expect(state.toast.message == nil)
        state.setNavigatorPanelVisibilityMode(.always)
        #expect(state.toast.message == nil)
    }

    @Test func slideshowFeedbackOnlyAppearsWhenItsStateChanges() {
        let state = AppState(isIncognito: true)
        let items = [
            FileListItem(id: "a", path: "/tmp/a.png", displayName: "a.png"),
            FileListItem(id: "b", path: "/tmp/b.png", displayName: "b.png")
        ]
        state.fileList = FileListState(kind: .image, items: items, currentID: "a")
        defer { state.stopImageListSlideshow() }
        state.setImageListSlideshowEnabled(true)
        #expect(state.toast.message?.text == String(format: NSLocalizedString("Slideshow Started Toast", comment: ""), SettingsStore.shared.imageListSlideshowInterval.formatted()))
        let firstID = state.toast.message?.id
        state.setImageListSlideshowEnabled(true)
        #expect(state.toast.message?.id == firstID)
        state.setImageListSlideshowEnabled(false)
        #expect(state.toast.message?.text == NSLocalizedString("Slideshow Stopped Toast", comment: ""))
    }

    @Test func unsuccessfulImageAndCoverCopyDoNotReportSuccess() {
        let state = AppState(isIncognito: true)
        #expect(!state.copyCurrentImageToPasteboard())
        #expect(!state.copyAudioCoverToPasteboard())
        #expect(state.toast.message == nil)
    }

    @Test func incognitoModeFeedbackRequiresNonblankPrivateContentAndUsesItsIcon() {
        let state = AppState(isIncognito: true)
        state.showIncognitoModeToastIfNeeded()
        #expect(state.toast.message == nil)
        state.text = "Private content"
        state.showIncognitoModeToastIfNeeded()
        #expect(state.toast.message?.text == NSLocalizedString("Incognito Mode Toast", comment: ""))
        #expect(state.toast.message?.usesIncognitoIcon == true)
        let normal = AppState()
        normal.text = "Normal content"
        normal.showIncognitoModeToastIfNeeded()
        #expect(normal.toast.message == nil)
    }

    @Test func windowContentReplacementClearsToastAndNeverPersistsIt() throws {
        let state = AppState()
        state.toast.show("ephemeral_toast_marker", duration: .seconds(5))
        let encoded = try JSONEncoder().encode(state.toConfig())
        #expect(!String(decoding: encoded, as: UTF8.self).contains("ephemeral_toast_marker"))
        state.id = UUID()
        #expect(state.toast.message == nil)
    }

    @Test func favoriteFeedbackReportsPersistedSuccessAndMissingRecordFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
        let cache = ContentCache(repository: repository, directories: { [root] })
        let manager = HistoryManager(repository: repository, contentCache: cache, cacheDirectories: { [root] })
        let center = FoilToastCenter()
        let config = WindowConfig(id: UUID(), text: "Favorite result")
        #expect(!manager.setFavorite(id: config.id, pinned: true, toast: center))
        #expect(center.message?.text == NSLocalizedString("Favorite Update Failed", comment: ""))
        #expect(repository.config(id: config.id) == nil)
        #expect(repository.upsert(config))
        #expect(manager.setFavorite(id: config.id, pinned: true, toast: center))
        #expect(repository.config(id: config.id)?.historyIsPinned == true)
        #expect(center.message?.text == NSLocalizedString("Favorite Added Toast", comment: ""))
        #expect(center.message?.symbolName == "bookmark.fill")
        #expect(manager.setFavorite(id: config.id, pinned: false, toast: center))
        #expect(repository.config(id: config.id)?.historyIsPinned == false)
        #expect(center.message?.text == NSLocalizedString("Favorite Removed Toast", comment: ""))
        #expect(center.message?.symbolName == "bookmark.slash.fill")
        center.dismiss()
    }
}
