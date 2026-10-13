import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

/// 外部字幕关联按影片保存；字体等样式单独全局保存，切项不会互相覆盖。
@MainActor final class VideoSubtitleController: NSObject, ObservableObject, AVPlayerItemLegibleOutputPushDelegate {
    @Published private(set) var videoURL: URL?
    @Published private(set) var association = SubtitleAssociation()
    @Published private(set) var isHidden = false
    @Published var hasEmbeddedSubtitles = false
    var hasLoadedSubtitle: Bool {
        association.selectedPath != nil ? document != nil : !nativeOptions.isEmpty || hasEmbeddedSubtitles
    }
    @Published private(set) var document: SubtitleDocument?
    @Published private(set) var failure: String?
    @Published private(set) var nativeOptions: [AVMediaSelectionOption] = []
    @Published private(set) var embeddedCues: [SubtitleCue] = []
    private var nativeGroup: AVMediaSelectionGroup?
    private weak var player: AVPlayer?
    private var output: AVPlayerItemLegibleOutput?
    private weak var outputItem: AVPlayerItem?
    private var styleObservation: AnyCancellable?
    private var accessedSubtitle: URL?
    private var accessedDirectory: URL?
    private var generation = 0
    private var lastNativeText = ""
    private var lastNativeStart = 0.0
    var onChange: (() -> Void)?
    var history: [String: SubtitleAssociation] = [:]
    override init() {
        super.init()
        styleObservation = SubtitleStyleStore.shared.$style.sink { [weak self] style in
            self?.output?.advanceIntervalForDelegateInvocation = max(0, -style.delay)
        }
    }
    private static var saved: [String: SubtitleAssociation] {
        get { UserDefaults.standard.data(forKey: "video.subtitle.associations").flatMap { try? JSONDecoder().decode([String: SubtitleAssociation].self, from: $0) } ?? [:] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "video.subtitle.associations") }
    }
    static func key(_ url: URL) -> String { url.standardizedFileURL.path }
    deinit { accessedSubtitle?.stopAccessingSecurityScopedResource(); accessedDirectory?.stopAccessingSecurityScopedResource() }
    func restore(_ values: [String: SubtitleAssociation]?) {
        guard let values else { return }
        history.merge(values) { _, restored in restored }
    }
    func prepare(video: URL) async {
        isHidden = false
        guard videoURL?.standardizedFileURL != video.standardizedFileURL else { return }
        generation += 1
        let token = generation
        accessedSubtitle?.stopAccessingSecurityScopedResource(); accessedSubtitle = nil
        accessedDirectory?.stopAccessingSecurityScopedResource(); accessedDirectory = nil
        hasEmbeddedSubtitles = false
        videoURL = video; document = nil; failure = nil; embeddedCues = []; nativeOptions = []
        association = history[Self.key(video)] ?? Self.saved[Self.key(video)] ?? .init()
        if let selected = association.selectedPath, let file = association.files.first(where: { $0.path == selected }) {
            await load(file, token: token)
            return
        }
        let directory = video.deletingLastPathComponent()
        if let bookmark = (UserDefaults.standard.dictionary(forKey: "video.subtitle.directoryBookmarks") as? [String: Data])?[directory.path] {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale),
               resolved.startAccessingSecurityScopedResource() { accessedDirectory = resolved }
        }
        // 没有父目录授权时，按需取得一次授权，避免把自动查找变成每次播放的提示。
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch {
            guard token == generation else { return }
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.directoryURL = directory; panel.message = NSLocalizedString("Subtitle Directory Access", comment: "")
            guard panel.runModal() == .OK, let granted = panel.url,
                  granted.standardizedFileURL == directory.standardizedFileURL else { return }
            if granted.startAccessingSecurityScopedResource() { accessedDirectory = granted }
            if let bookmark = try? granted.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                var values = UserDefaults.standard.dictionary(forKey: "video.subtitle.directoryBookmarks") as? [String: Data] ?? [:]
                values[directory.path] = bookmark; UserDefaults.standard.set(values, forKey: "video.subtitle.directoryBookmarks")
            }
            urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }
        let basename = video.deletingPathExtension().lastPathComponent.lowercased()
        let matching = urls.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return SubtitleDocument.extensions.contains(url.pathExtension.lowercased()) && (name == basename || name.hasPrefix(basename + "."))
        }.sorted { a, b in
            let exactA = a.deletingPathExtension().lastPathComponent.lowercased() == basename
            let exactB = b.deletingPathExtension().lastPathComponent.lowercased() == basename
            if exactA != exactB { return exactA }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        guard token == generation else { return }
        for url in matching where !association.files.contains(where: { $0.path == url.path }) { association.files.append(reference(url)) }
        if association.selectedPath == nil, association.embeddedID == nil, let first = matching.first {
            association.selectedPath = first.path
            await load(reference(first), token: token)
        }
        save()
    }
    func pickFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = SubtitleDocument.extensions.compactMap { UTType(filenameExtension: $0) }
        if let videoURL { panel.directoryURL = videoURL.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }
    func importFile(_ url: URL) {
        guard videoURL != nil, SubtitleDocument.extensions.contains(url.pathExtension.lowercased()) else { return }
        let file = reference(url)
        generation += 1; let token = generation
        Task { await load(file, token: token, selectOnSuccess: true) }
    }
    func selectFile(_ file: SubtitleFileReference) {
        generation += 1; let token = generation
        Task { await load(file, token: token, selectOnSuccess: true) }
    }
    private func load(_ file: SubtitleFileReference, token: Int, selectOnSuccess: Bool = false) async {
        var stale = false
        let resolved = file.bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: .withSecurityScope, bookmarkDataIsStale: &stale) } ?? URL(fileURLWithPath: file.path)
        let accessed = resolved.startAccessingSecurityScopedResource()
        do {
            let doc = try await Task.detached(priority: .userInitiated) {
                try SubtitleDocument.parse(Data(contentsOf: resolved), extension: resolved.pathExtension)
            }.value
            guard token == generation else { if accessed { resolved.stopAccessingSecurityScopedResource() }; return }
            accessedSubtitle?.stopAccessingSecurityScopedResource(); accessedSubtitle = accessed ? resolved : nil
            document = doc; failure = nil
            if selectOnSuccess {
                if !association.files.contains(where: { $0.path == file.path }) { association.files.append(file) }
                association.selectedPath = file.path; association.embeddedID = nil; isHidden = false
            }
            save()
        } catch {
            if accessed { resolved.stopAccessingSecurityScopedResource() }
            guard token == generation else { return }
            failure = error.localizedDescription
        }
    }
    private func reference(_ url: URL) -> SubtitleFileReference {
        .init(path: url.path, bookmark: try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
    }
    func hide() { isHidden = true }
    func setVisible(_ visible: Bool) { isHidden = !visible }
    func useEmbedded(_ commandID: String? = nil) {
        association.selectedPath = nil; association.embeddedID = commandID; isHidden = false; document = nil; failure = nil; save()
    }
    private func save() {
        guard let videoURL else { return }
        let key = Self.key(videoURL)
        history[key] = association
        var values = Self.saved; values[key] = association; Self.saved = values
        onChange?()
    }
    func text(at time: Double) -> String {
        guard !isHidden else { return "" }
        let delayed = time - SubtitleStyleStore.shared.style.delay
        if association.selectedPath != nil { return document?.text(at: delayed) ?? "" }
        return embeddedCues.filter { $0.start <= delayed && delayed < $0.end }.map(\.text).joined(separator: "\n")
    }
    func bindNative(_ player: AVPlayer) async {
        let token = generation
        self.player = player
        guard let item = player.currentItem else { return }
        if let output { outputItem?.remove(output) }
        let capture = AVPlayerItemLegibleOutput(); capture.suppressesPlayerRendering = true
        capture.advanceIntervalForDelegateInvocation = max(0, -SubtitleStyleStore.shared.style.delay)
        capture.setDelegate(self, queue: .main); item.add(capture); output = capture; outputItem = item
        nativeGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        guard token == generation, self.player === player, player.currentItem === item else { return }
        nativeOptions = nativeGroup?.options ?? []
        if let id = association.embeddedID, let index = Int(id), nativeOptions.indices.contains(index) { selectNative(index) }
        else if association.selectedPath == nil, !isHidden,
                let preferred = nativeGroup?.defaultOption ?? nativeOptions.first,
                let index = nativeOptions.firstIndex(of: preferred) { selectNative(index) }
    }
    func selectNative(_ index: Int) {
        guard let group = nativeGroup, nativeOptions.indices.contains(index) else { return }
        player?.currentItem?.select(nativeOptions[index], in: group); useEmbedded(String(index))
    }
    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        MainActor.assumeIsolated {
            let time = itemTime.seconds
            guard time.isFinite else { return }
            if !lastNativeText.isEmpty, time > lastNativeStart {
                embeddedCues.append(.init(start: lastNativeStart, end: time, text: lastNativeText))
            }
            objectWillChange.send()
            lastNativeText = strings.map(\.string).joined(separator: "\n"); lastNativeStart = time
            embeddedCues.removeAll { $0.end < time - 120 }
        }
    }
    nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        MainActor.assumeIsolated {
            embeddedCues = []; lastNativeText = ""; lastNativeStart = 0
        }
    }
    func nativeText(at time: Double) -> String {
        let delayed = time - SubtitleStyleStore.shared.style.delay
        guard !isHidden else { return "" }
        if association.selectedPath != nil { return document?.text(at: delayed) ?? "" }
        if !lastNativeText.isEmpty, delayed >= lastNativeStart { return lastNativeText }
        return text(at: time)
    }
}
