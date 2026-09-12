import Foundation
import AVFoundation
import Testing
import FoofoilExtensionKit
@testable import foofoil

@MainActor
@Suite(.serialized)
struct FileListNavigatorPerformanceTests {
    @Test func largeListHistoryFlushKeepsLatestSelectionAndRemovalCancelsPendingSave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("list-save-\(UUID()).wav")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let items = (0..<300).map {
            FileListItem(id: "\($0)", path: url.path, displayName: "Track \($0)")
        }
        var config = WindowConfig(
            id: UUID(), imagePath: url.path, originalImageName: url.lastPathComponent,
            contentKind: .audio,
            fileList: FileListState(kind: .audio, items: items, currentID: "0")
        )
        defer { HistoryManager.shared.removeFromHistory(config) }
        for index in 0..<100 {
            config.fileList?.currentID = "\(index)"
            HistoryManager.shared.addToHistory(config)
        }
        HistoryManager.shared.flushPendingListSaves()
        #expect(HistoryRepository.shared.config(id: config.id)?.fileList?.currentID == "99")
        config.fileList?.currentID = "100"
        HistoryManager.shared.addToHistory(config)
        HistoryManager.shared.removeFromHistory(config)
        HistoryManager.shared.flushPendingListSaves()
        #expect(HistoryRepository.shared.config(id: config.id) == nil)
    }

    @Test func nativePlayerExceptionBecomesSwiftErrorWithoutPoisoningExecutor() async {
        // 未接入引擎的节点必然拒绝启动；重复跨 await 验证异常没有破坏执行器。
        for _ in 0..<20 {
            do {
                try AudioPlaybackController.playNodeSafely(AVAudioPlayerNode())
                Issue.record("Unattached player unexpectedly started")
            } catch {
                #expect((error as NSError).domain == "com.foofoil.audio.player-start")
            }
            await Task.yield()
            verifyExecutor()
        }
    }

    private func verifyExecutor() {
        MainActor.assumeIsolated { #expect(Thread.isMainThread) }
    }

    private func makeState(count: Int = 2) -> AppState {
        let state = AppState()
        state.fileList = FileListState(
            kind: .audio,
            items: (0..<count).map {
                FileListItem(id: "track-\($0)", path: "/missing/\($0).wav", displayName: "Track \($0)")
            },
            currentID: "track-0"
        )
        state.syncFileListNavigator()
        return state
    }

    @Test func selectionKeepsMetadataAndDoesNotRestartScan() throws {
        let state = makeState(count: 10_000)
        defer { state.resetFileList() }
        let generation = state.navigatorMetadataGeneration
        let first = try #require(state.fileList?.items.first)
        state.applyNavigatorMetadata([
            FileListNavigatorMetadata(item: first, isAccessible: true, badge: "3:42")
        ], generation: generation)
        for index in 1...100 {
            state.fileList?.currentID = "track-\(index)"
            state.syncFileListNavigator()
        }
        let contribution = try #require(state.builtInNavigatorContributions.first)
        #expect(state.navigatorMetadataGeneration == generation)
        #expect(contribution.items.count == 10_000)
        #expect(contribution.items[0].badge == "3:42")
        #expect(contribution.items.filter(\.isCurrent).map(\.id) == ["track-100"])
        #expect(contribution.selectedItemIDs == ["track-100"])
    }

    @Test func resetDiscardsLateResultsEvenWhenIDsAreReused() throws {
        let state = makeState()
        let oldGeneration = state.navigatorMetadataGeneration
        let oldItem = try #require(state.fileList?.items.first)
        let list = state.fileList
        state.resetFileList()
        state.fileList = list
        state.syncFileListNavigator()
        defer { state.resetFileList() }
        state.applyNavigatorMetadata([
            FileListNavigatorMetadata(item: oldItem, isAccessible: false, badge: "stale")
        ], generation: oldGeneration)
        #expect(state.navigatorMetadata.isEmpty)
        #expect(state.builtInNavigatorContributions[0].items[0].badge == nil)
    }

    @Test func replacingFileInvalidatesCachedFailureAndDuration() throws {
        let state = makeState()
        defer { state.resetFileList() }
        let oldItem = try #require(state.fileList?.items.first)
        let generation = state.navigatorMetadataGeneration
        state.applyNavigatorMetadata([
            FileListNavigatorMetadata(item: oldItem, isAccessible: false, badge: nil)
        ], generation: generation)
        state.syncFileListNavigator()
        #expect(state.navigatorMetadataGeneration == generation)
        state.fileList?.items[0].path = "/new/source.wav"
        state.syncFileListNavigator()
        #expect(state.navigatorMetadataGeneration != generation)
        #expect(state.navigatorMetadata[oldItem.id] == nil)
        #expect(state.builtInNavigatorContributions[0].items[0].isEnabled)
    }

    @Test func batchPublishesOnceAndPreservesLatestSelection() throws {
        let state = makeState(count: 64)
        defer { state.resetFileList() }
        let items = try #require(state.fileList?.items)
        state.fileList?.currentID = "track-32"
        state.syncFileListNavigator()
        let revision = state.fileListRevision
        state.applyNavigatorMetadata(items.map {
            FileListNavigatorMetadata(item: $0, isAccessible: true, badge: "1:00")
        }, generation: state.navigatorMetadataGeneration)
        #expect(state.fileListRevision == revision + 1)
        #expect(state.builtInNavigatorContributions[0].items.filter(\.isCurrent).map(\.id) == ["track-32"])
        #expect(state.navigatorMetadata.count == 64)
    }
}
