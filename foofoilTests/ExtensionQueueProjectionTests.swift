import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

extension ExtensionKitTests {
@MainActor
@Suite
struct ExtensionQueueProjectionTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    private func session(
        urls: [URL],
        ids: [String],
        current: String,
        singleResource: Bool = false
    ) -> ContentSession {
        ContentSession(
            extensionID: nil,
            providerID: "test.queue-projection",
            request: singleResource
                ? .singleFile(.init(url: urls[0]))
                : .fileCollection(urls.map { .init(url: $0) }),
            presentation: .text(titleKey: "Test", body: "Fixture"),
            playbackQueue: .init(items: ids.map { .init(id: $0, title: $0) }, currentItemID: current)
        )
    }

    @discardableResult
    private func list(_ urls: [URL], currentIndex: Int = 0) -> FileListState {
        let items = urls.enumerated().map { index, value in
            FileListItem(id: "host:\(index)", path: value.path, displayName: value.lastPathComponent)
        }
        return FileListState(kind: .audio, items: items, currentID: items[currentIndex].id)
    }

    // MARK: ID 生命周期

    @Test func extensionItemIDIsSessionOnlyAcrossCoding() throws {
        let item = FileListItem(
            id: "host:0", path: "/tmp/a.dsf", displayName: "a.dsf", extensionItemID: "item-a"
        )
        let decoded = try JSONDecoder().decode(FileListItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.extensionItemID == nil)
        #expect(decoded.id == "host:0")
        #expect(decoded.path == "/tmp/a.dsf")
    }

    @Test func containerTrackIDStillRoundTripsForRestore() throws {
        let item = FileListItem(
            id: "host:0", path: "/tmp/disc.iso", displayName: "One",
            cue: FileListCueInfo(startCueFrames: 0, containerTrackID: "track:1")
        )
        let decoded = try JSONDecoder().decode(FileListItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.cue?.containerTrackID == "track:1")
    }

    /// 新会话重新盖章时不能复用“旧值恰好也在新队列里”的陈旧映射。
    @Test func stampingRecomputesInsteadOfReusingStaleSessionIDs() {
        let first = url("first.dsf")
        let second = url("second.dsf")
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.fileList = FileListState(
            kind: .audio,
            items: [
                FileListItem(id: "host:0", path: first.path, displayName: "first", extensionItemID: "q-2"),
                FileListItem(id: "host:1", path: second.path, displayName: "second", extensionItemID: "q-1")
            ],
            currentID: "host:0"
        )
        let session = session(urls: [first, second], ids: ["q-1", "q-2"], current: "q-1")
        state.stampHostListWithExtensionQueueIDs(session)
        #expect(state.fileList?.items.map(\.extensionItemID) == ["q-1", "q-2"])
    }

    @Test func recordExtensionRemovalsTracksOpaqueIDs() {
        let first = url("first.dsf")
        let second = url("second.dsf")
        let state = AppState()
        defer {
            state.extensionSession = nil
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        let session = session(urls: [first, second], ids: ["q-1", "q-2"], current: "q-1")
        state.extensionSession = session
        state.recordExtensionRemovals(in: [
            FileListItem(id: "host:1", path: second.path, displayName: "second")
        ])
        #expect(state.extensionRemovedItemIDs == ["q-2"])
    }

    // MARK: 队列投影六类场景

    /// 1. 映射失败且没有删除意图：保持原扩展队列，不裁剪成单曲。
    @Test func mappingFailureKeepsExtensionQueue() {
        let first = url("a.dsf")
        let second = url("b.dsf")
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.fileList = list([url("x.dsf"), url("y.dsf")])
        let session = session(urls: [first, second], ids: ["q-a", "q-b"], current: "q-a")
        #expect(state.hostPlaybackSequenceProjection(for: session) == .unchanged)
        #expect(
            state.sessionByApplyingHostPlaybackSequence(session).playbackQueue?.items.map(\.id)
                == ["q-a", "q-b"]
        )
    }

    /// 2. 删除当前曲：只允许当前项收尾，不能续播旧列表。
    @Test func deletingCurrentTrackKeepsOnlyCurrentForFinish() {
        let first = url("a.dsf")
        let second = url("b.dsf")
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.extensionRemovedItemIDs = ["q-a"]
        state.fileList = list([second])
        let session = session(urls: [first, second], ids: ["q-a", "q-b"], current: "q-a")
        #expect(state.hostPlaybackSequenceProjection(for: session) == .currentOnly("q-a"))
        #expect(
            state.sessionByApplyingHostPlaybackSequence(session).playbackQueue?.items.map(\.id)
                == ["q-a"]
        )
    }

    /// 3. 仅删除后继：从最新宿主顺序去掉已删项。
    @Test func deletingSuccessorDropsItFromHostOrder() {
        let first = url("a.dsf")
        let second = url("b.dsf")
        let third = url("c.dsf")
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.mediaPlaybackMode = .sequential
        state.fileList = list([first, third])
        let session = session(urls: [first, second, third], ids: ["q-a", "q-b", "q-c"], current: "q-a")
        #expect(state.hostPlaybackSequenceProjection(for: session) == .sequence(["q-a", "q-c"]))
    }

    /// 4. 重排后继：按宿主新顺序，不重启当前曲。
    @Test func reorderingSuccessorsFollowsHostOrder() {
        let first = url("a.dsf")
        let second = url("b.dsf")
        let third = url("c.dsf")
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.mediaPlaybackMode = .sequential
        state.fileList = list([first, third, second])
        let session = session(urls: [first, second, third], ids: ["q-a", "q-b", "q-c"], current: "q-a")
        #expect(state.hostPlaybackSequenceProjection(for: session) == .sequence(["q-a", "q-c", "q-b"]))
    }

    /// 5. 多文件连续播放：顺序模式保留全部有效后继。
    @Test func multiFileSequentialKeepsAllSuccessors() {
        let first = url("a.dsf")
        let second = url("b.dsf")
        let third = url("c.dsf")
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.mediaPlaybackMode = .sequential
        state.fileList = list([first, second, third])
        let session = session(urls: [first, second, third], ids: ["q-a", "q-b", "q-c"], current: "q-a")
        #expect(state.hostPlaybackSequenceProjection(for: session) == .sequence(["q-a", "q-b", "q-c"]))
    }

    /// 6. 单资源容器：内部顺序归扩展，宿主不按外部文件列表规则裁剪。
    @Test func singleResourceContainerQueueIsNotTrimmedByHostList() {
        let iso = url("disc.iso")
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.fileList = FileListState(
            kind: .audio,
            items: [
                FileListItem(
                    id: "host:0", path: iso.path, displayName: "One",
                    cue: FileListCueInfo(startCueFrames: 0, containerTrackID: "track:1")
                ),
                FileListItem(
                    id: "host:1", path: iso.path, displayName: "Two",
                    cue: FileListCueInfo(startCueFrames: 100, containerTrackID: "track:2")
                )
            ],
            currentID: "host:0"
        )
        let session = session(urls: [iso], ids: ["track:1", "track:2"], current: "track:1", singleResource: true)
        #expect(state.hostPlaybackSequenceProjection(for: session) == .unchanged)
        #expect(
            state.sessionByApplyingHostPlaybackSequence(session).playbackQueue?.items.map(\.id)
                == ["track:1", "track:2"]
        )
    }

    // MARK: 当前版本恢复

    @Test func restartRestoresTrackAndPositionWhenIDsStable() async throws {
        let provider = RestoreQueueTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }

        provider.idPrefix = "cur"
        var saved = try await provider.makeSession(for: restoreRequest, negotiatedAPI: 1)
        saved.playbackQueue?.currentItemID = "cur:1"
        saved.mediaPlayback?.position = 1.5

        provider.idPrefix = "cur"
        let fresh = try await provider.makeSession(for: restoreRequest, negotiatedAPI: 1)
        let restored = try await host.restorePlayback(from: saved, in: fresh)
        #expect(restored.id == fresh.id)
        #expect(restored.playbackQueue?.currentItemID == "cur:1")
        #expect(restored.mediaPlayback?.position == 1.5)
        #expect(restored.mediaPlayback?.state == .paused)
    }

    /// 临时项目 ID 改变或曲目不存在时，不把旧位置套到新曲目，从起点暂停开始。
    @Test func restartWithChangedIDsStartsPausedAtBeginning() async throws {
        let provider = RestoreQueueTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }

        provider.idPrefix = "old"
        var saved = try await provider.makeSession(for: restoreRequest, negotiatedAPI: 1)
        saved.playbackQueue?.currentItemID = "old:1"
        saved.mediaPlayback?.position = 42

        provider.idPrefix = "new"
        let fresh = try await provider.makeSession(for: restoreRequest, negotiatedAPI: 1)
        let restored = try await host.restorePlayback(from: saved, in: fresh)
        #expect(restored.playbackQueue?.currentItemID == "new:0")
        #expect(restored.mediaPlayback?.position == 0)
        #expect(restored.mediaPlayback?.state == .paused)
    }

    /// fresh 队列不含保存 ID（资源被替换/曲目消失）时同样降级到起点暂停，不套用旧位置。
    @Test func restoreDoesNotApplyPositionWhenSavedTrackIsGone() async throws {
        let provider = RestoreQueueTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }

        provider.idPrefix = "cur"
        var saved = try await provider.makeSession(for: restoreRequest, negotiatedAPI: 1)
        saved.playbackQueue?.currentItemID = "cur:removed"
        saved.mediaPlayback?.position = 30

        let fresh = try await provider.makeSession(for: restoreRequest, negotiatedAPI: 1)
        let restored = try await host.restorePlayback(from: saved, in: fresh)
        #expect(restored.playbackQueue?.currentItemID == "cur:0")
        #expect(restored.mediaPlayback?.position == 0)
        #expect(restored.mediaPlayback?.state == .paused)
    }

    private var restoreRequest: ContentRequest {
        .fileCollection([.init(url: url("restore-a.dsf")), .init(url: url("restore-b.dsf"))])
    }
}
}

@MainActor
private final class RestoreQueueTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.restore-queue", extensionID: "app.foofoil.extension.test-restore-queue",
        role: .primary, fallbackProviderID: nil, enhancementDomain: "audio", contentFamily: .audio,
        filenameExtensions: ["dsf"], isEnabled: true, isRuntimeAvailable: true
    )
    var idPrefix = "cur"

    func match(_ request: ContentRequest) -> ProviderMatch? { nil }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        var session = ContentSession(
            extensionID: descriptor.extensionID, providerID: descriptor.id, request: request,
            presentation: .text(titleKey: "Generic Audio", body: request.primaryFileURL?.lastPathComponent ?? ""),
            capabilities: [
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.mediaTransport, scope: .session), state: .active),
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.seekable, scope: .session), state: .active),
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.mediaPlaybackQueue, scope: .session), state: .active),
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.sessionLifecycle, scope: .session), state: .active)
            ],
            mediaPlayback: .init(state: .paused, position: 0, duration: 100, isSeekable: true)
        )
        session.playbackQueue = .init(
            items: [
                .init(id: "\(idPrefix):0", title: "First"),
                .init(id: "\(idPrefix):1", title: "Second")
            ],
            currentItemID: "\(idPrefix):0"
        )
        return session
    }

    /// 只在 fresh 队列仍含保存 ID 时恢复曲目/位置；否则从起点暂停开始。
    func restorePlayback(from saved: ContentSession, in fresh: ContentSession) async throws -> ContentSession {
        guard let request = ExtensionSessionLifecycle.restorationRequest(from: saved, in: fresh) else {
            return fresh
        }
        var restored = request.session
        restored.mediaPlayback?.state = .paused
        guard let itemID = request.restoration?.currentItemID,
              restored.playbackQueue?.items.contains(where: { $0.id == itemID }) == true else {
            restored.mediaPlayback?.position = 0
            return restored
        }
        restored.playbackQueue?.currentItemID = itemID
        restored.mediaPlayback?.position = request.restoration?.position ?? 0
        return restored
    }
}
