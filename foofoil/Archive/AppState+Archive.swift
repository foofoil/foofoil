import AppKit
import Combine
import FoofoilExtensionKit

extension AppState {
    var readingState: AppState { archiveSession?.preview?.readingState ?? self }
    var selectedArchiveSession: ArchiveSession? { archiveSession?.preview?.selectedArchiveSession ?? archiveSession }
    var presentationWindowState: AppState { archiveWindowOwner ?? self }

    /// 内容订阅沿包内选择链切换；取消旧订阅后不再响应上一条目的异步通知。
    var readingStatePublisher: AnyPublisher<AppState, Never> {
        $archiveSession.map { [weak self] session -> AnyPublisher<AppState, Never> in
            guard let self else { return Empty().eraseToAnyPublisher() }
            guard let session else { return Just(self).eraseToAnyPublisher() }
            return session.$preview.map { [weak self] preview -> AnyPublisher<AppState, Never> in
                if let preview { return preview.readingStatePublisher }
                guard let self else { return Empty().eraseToAnyPublisher() }
                return Just(self).eraseToAnyPublisher()
            }.switchToLatest().eraseToAnyPublisher()
        }.switchToLatest().eraseToAnyPublisher()
    }

    func archiveSession(forNavigatorID id: String) -> ArchiveSession? {
        guard let archiveSession else { return nil }
        if archiveSession.navigatorContributionID == id { return archiveSession }
        return archiveSession.preview?.archiveSession(forNavigatorID: id)
    }
    /// 面板获得键盘事件时，方向键归文件树；正文中的 EPUB 左右键仍归章节。
    func handleArchiveTreeKeyDown(_ event: NSEvent) -> Bool {
        guard let contributionID = activeNavigatorContributionID,
              let archive = archiveSession(forNavigatorID: contributionID), archive.index != nil,
              let contribution = navigatorContributions.first(where: { $0.id == contributionID }),
              !isNavigatorSearchActive,
              !((NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable ?? false) else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, [123, 124, 125, 126, 36, 76, 49].contains(event.keyCode) else { return false }
        let entries = Dictionary(uniqueKeysWithValues: contribution.items.map { ($0.id, $0) })
        let children = Dictionary(grouping: contribution.items, by: \.parentID)
        var visible = [NavigatorItem]()
        var stack = Array((children[nil] ?? []).reversed())
        while let entry = stack.popLast() {
            visible.append(entry)
            if expandedNavigatorItemIDs.contains(entry.id) { stack.append(contentsOf: (children[entry.id] ?? []).reversed()) }
        }
        let selected = contribution.selectedItemIDs.first.flatMap { entries[$0] }
        switch event.keyCode {
        case 125, 126:
            let current = visible.firstIndex { $0.id == selected?.id }
            let next = current.map { $0 + (event.keyCode == 125 ? 1 : -1) } ?? 0
            if visible.indices.contains(next) { archive.selectNavigatorItem(visible[next].id) }
        case 123:
            if let selected {
                if expandedNavigatorItemIDs.contains(selected.id) { expandedNavigatorItemIDs.remove(selected.id) }
                else if let parent = selected.parentID, entries[parent] != nil { archive.selectNavigatorItem(parent) }
            }
        case 124, 36, 76:
            if let selected {
                if !expandedNavigatorItemIDs.contains(selected.id), children[selected.id] != nil || archive.isArchiveNode(selected.id) || archive.selected?.isDirectory == true {
                    expandedNavigatorItemIDs.insert(selected.id)
                } else if let first = children[selected.id]?.first {
                    archive.selectNavigatorItem(first.id)
                } else if event.keyCode != 124 {
                    archive.selectNavigatorItem(selected.id)
                }
            }
        default:
            if let selected { archive.selectNavigatorItem(selected.id) }
        }
        return true
    }

    func clearArchiveForNewContent() {
        relinquishAgentControl()
        guard !isArchivePreview, archiveSession != nil else { return }
        archiveSession?.close()
        archiveSession = nil
        // 外部打开是新文档，不能复用原包 UUID 覆盖它的历史记录。
        id = UUID()
        sourceFingerprint = nil
        resetFileList()
    }

    func restoreArchive(_ source: ArchiveSource, sourceLease: ArchivePreviewLease? = nil) {
        guard !source.volumes.isEmpty else { return }
        imageURL = nil
        textURL = nil
        text = ""
        webURL = nil
        actualWebURL = nil
        extensionSession = nil
        let session = ArchiveSession(source: source, sourceLease: sourceLease)
        session.windowState = presentationWindowState
        archiveSession = session
        session.locateVolumes = { [weak self, weak session] in
            guard let session else { return }
            self?.openArchive(url: session.source.primaryURL)
        }
        session.onChange = { [weak self, weak session] in
            guard let self, let session, self.archiveSession === session else { return }
            self.builtInNavigatorContributions = [session.contribution]
            self.activeNavigatorContributionID = session.navigatorContributionID
        }
        activeNavigatorContributionID = session.navigatorContributionID
        expandedNavigatorItemIDs = ["root"]
        session.load()
    }

    func openArchive(url: URL, displayName: String? = nil, fingerprint: String? = nil, sourceLease: ArchivePreviewLease? = nil) {
        do {
            var source = try archiveVolumes(for: url)
            source.displayName = displayName
            resetContent()
            originalImageName = source.name
            sourceFingerprint = fingerprint ?? Self.localSourceFingerprint(for: source.primaryURL)
            restoreArchive(source, sourceLease: sourceLease)
            saveState()
        } catch is CancellationError {
            return
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Archive Contents", comment: "")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// 分卷类型分别识别；7z 分段流交给 libarchive 多文件读取，ZIP 分盘不做字节拼接。
    private func archiveVolumes(for url: URL) throws -> ArchiveSource {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        if lower.range(of: #"\.z\d{2}$"#, options: .regularExpression) != nil { throw ArchiveFailure.unsupportedVolumes }
        let is7z = lower.range(of: #"\.7z\.\d{3}$"#, options: .regularExpression) != nil
        let isPartRAR = lower.range(of: #"\.part\d+\.rar$"#, options: .regularExpression) != nil
        let isOldRAR = lower.range(of: #"\.r\d{2}$"#, options: .regularExpression) != nil || (lower.hasSuffix(".rar") && !isPartRAR && ArchiveReader.isRARVolume(url))
        guard is7z || isPartRAR || isOldRAR else {
            return ArchiveSource(volumes: [.init(path: url.path, bookmark: Self.makeSecurityScopedBookmark(for: url))])
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = NSLocalizedString("Archive Volume Access", comment: "")
        guard panel.runModal() == .OK, let directory = panel.url else { throw CancellationError() }
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let pattern: String
        if is7z { pattern = #"\.\d{3}$"# }
        else if isPartRAR { pattern = #"\.part\d+\.rar$"# }
        else { pattern = #"\.r\d{2}$"# }
        let stem = lower.replacingOccurrences(of: isOldRAR && lower.hasSuffix(".rar") ? #"\.rar$"# : pattern, with: "", options: .regularExpression)
        var numbered: [Int: String] = [:]
        for candidate in names {
            let value = candidate.lowercased()
            guard value.replacingOccurrences(of: pattern, with: "", options: .regularExpression) == stem,
                  let suffix = value.range(of: pattern, options: .regularExpression) else { continue }
            let digits = value[suffix].filter(\.isNumber)
            guard let number = Int(digits), numbered[number] == nil else { throw ArchiveFailure.conflict }
            numbered[number] = candidate
        }
        let first = isOldRAR ? 0 : 1
        guard let last = numbered.keys.max(), last - first < 1_000,
              (first...last).allSatisfy({ numbered[$0] != nil }) else { throw ArchiveFailure.unreadable }
        var result = (first...last).compactMap { numbered[$0].map { directory.appendingPathComponent($0) } }
        if isOldRAR {
            guard let main = names.first(where: { $0.lowercased() == stem + ".rar" }) else { throw ArchiveFailure.unreadable }
            result.insert(directory.appendingPathComponent(main), at: 0)
        }
        return ArchiveSource(volumes: result.map { .init(path: $0.path, bookmark: Self.makeSecurityScopedBookmark(for: $0)) })
    }
}

extension AppDelegate {
    var activeReadingState: AppState? { activeAppState?.readingState }
}
