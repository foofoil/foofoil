import AppKit
import ImageIO
import PDFKit
import AVFoundation

/// 信息只展示原始来源；缓存仅供读取内容特征，绝不作为 Finder 入口。
nonisolated enum FoilInformation {
    struct Row: Sendable {
        let key: String
        let value: String
    }

    @MainActor static func sourceURL(for config: WindowConfig) -> URL? {
        if config.isClipboardContent { return nil }
        if let bookmark = config.videoBookmark,
           let fallback = config.textPath ?? config.imagePath ?? config.webURLString.flatMap({ URL(string: $0)?.path }) {
            let resolved = FileReference.resolve(URL(fileURLWithPath: fallback), bookmark: bookmark)
            if resolved.status == .available, !AppState.isManagedCacheURL(resolved.url) { return resolved.url }
        }
        if let item = config.fileList?.currentItem {
            if let bookmark = item.bookmark, let url = AppState.resolveVideoBookmark(bookmark) {
                return url
            }
            let url = item.url
            return AppState.isManagedCacheURL(url) ? nil : url
        }
        if let fingerprint = config.sourceFingerprint, fingerprint.hasPrefix("file:") {
            let url = URL(fileURLWithPath: String(fingerprint.dropFirst(5)))
            return AppState.isManagedCacheURL(url) ? nil : url
        }
        // 未记录来源的旧历史只能从仍保留原始路径的内容补齐，不能反推缓存文件。
        for path in [config.textPath, config.imagePath, config.webURLString.flatMap { URL(string: $0)?.isFileURL == true ? URL(string: $0)?.path : nil }].compactMap({ $0 }) {
            let url = URL(fileURLWithPath: path)
            if !AppState.isManagedCacheURL(url) { return url }
        }
        return nil
    }

    static func fileRows(source: URL?, contentURL: URL?, kind: HistoryContentKind) async -> (rows: [Row], available: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var rows: [Row] = []
                var available = false
                if let source {
                    let accessing = source.startAccessingSecurityScopedResource()
                    defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                    do {
                        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        available = values.isRegularFile == true
                        if let size = values.fileSize {
                            rows.append(Row(key: "Foil Info File Size", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))
                        }
                    } catch {
                        rows.append(Row(key: "Foil Info File Size", value: NSLocalizedString("Foil Info Unknown", comment: "")))
                        let missing = !FileManager.default.fileExists(atPath: source.path)
                        rows.append(Row(key: "Foil Info File Status", value: NSLocalizedString(missing ? "Foil Info Source Missing" : "Foil Info Source Unavailable", comment: "")))
                    }
                }
                if let url = contentURL {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    if kind == .image,
                       let image = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                       let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                       let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                        rows.append(Row(key: "Foil Info Pixels", value: "\(width) × \(height) px"))
                    }
                    if kind == .pdf, let document = PDFDocument(url: url) {
                        rows.append(Row(key: "Foil Info Pages", value: document.pageCount.formatted()))
                    }
                }
                continuation.resume(returning: (rows, available))
            }
        }
    }
}

extension AppDelegate {
    @objc func showFoilInformationAction() {
        guard let controller = activeWindowController, let window = controller.window,
              window.attachedSheet == nil else { return }
        let state = controller.appState
        let config = state.toConfig()
        let kind = config.contentKind ?? HistoryContentKind.infer(from: config)
        let source = FoilInformation.sourceURL(for: config)
        let size = window.frame.size
        var rows = [FoilInformation.Row(key: "Foil Info Title", value: config.historyMenuDisplayName),
                    .init(key: "Foil Info Type", value: NSLocalizedString("Foil Info Type \(kind.rawValue)", comment: "")),
                    .init(key: "Foil Info Window Size", value: "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt")]
        if let configuration = state.terminalConfiguration {
            rows.append(contentsOf: TerminalConfigurationField.allCases.map {
                .init(key: $0.rawValue, value: $0.value(in: configuration))
            })
        }
        if let ownership = state.agentOwnership {
            rows.append(.init(key: "Agent Created By", value: ownership.caller))
        }
        if config.isClipboardContent {
            rows.append(.init(key: "Foil Info Source", value: NSLocalizedString("From Clipboard", comment: "")))
        } else if let source {
            rows.append(.init(key: "Foil Info File Path", value: source.path))
        } else if state.appleMusicReference != nil {
            rows.append(.init(key: "Foil Info Source", value: "Apple Music"))
            if let item = state.appleMusicItem {
                rows.append(.init(key: "Foil Info Artist", value: item.subtitle))
            }
        } else if kind == .archive || kind == .image || kind == .pdf || kind == .ebook || kind == .quickLook || kind == .audio || kind == .video || config.textPath != nil {
            rows.append(.init(key: "Foil Info File Path", value: NSLocalizedString("Foil Info Path Unknown", comment: "")))
            rows.append(.init(key: "Foil Info File Size", value: NSLocalizedString("Foil Info Unknown", comment: "")))
        }
        if kind == .web, source == nil, !config.isClipboardContent {
            if let url = config.webURLString { rows.append(.init(key: "Foil Info Initial URL", value: url)) }
            if let url = config.actualWebURLString ?? config.webURLString { rows.append(.init(key: "Foil Info Current URL", value: url)) }
        }
        if kind.storesIndexedText {
            let text = state.agentReadOnly ? state.text : config.text
            rows.append(.init(key: "Foil Info Characters", value: text.count.formatted()))
            rows.append(.init(key: "Foil Info Lines", value: text.isEmpty ? "0" : (text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }).formatted()))
        }
        if let list = config.fileList, list.isPresentable {
            rows.append(.init(key: "Foil Info Items", value: list.items.count.formatted()))
            if let item = list.currentItem { rows.append(.init(key: "Foil Info Current Item", value: item.displayName)) }
        }
        if kind == .camera {
            if let device = state.cameraController?.selectedDeviceID,
               let name = CameraCaptureController.availableDevices.first(where: { $0.uniqueID == device })?.localizedName {
                rows.append(.init(key: "Foil Info Camera", value: name))
            }
            if let frame = state.cameraController?.frameSize {
                rows.append(.init(key: "Foil Info Pixels", value: "\(Int(frame.width)) × \(Int(frame.height)) px"))
            }
        }
        let contentURL = config.imagePath.map { URL(fileURLWithPath: $0) } ?? source
        let historyID = config.id
        Task { @MainActor in
            let visits = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: HistoryRepository.shared.visitDates(id: historyID))
                }
            }
            let metadata = await FoilInformation.fileRows(source: source, contentURL: contentURL, kind: kind)
            if (kind == .audio || kind == .video), let contentURL {
                let asset = AVURLAsset.media(url: contentURL)
                if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                    rows.append(.init(key: "Foil Info Duration", value: Duration.seconds(duration.seconds).formatted(.time(pattern: .hourMinuteSecond))))
                }
            }
            guard state.id == config.id, window.isVisible, window.attachedSheet == nil else { return }
            let unknown = NSLocalizedString("Foil Info Unknown", comment: "")
            rows.append(.init(key: "Foil Info First Visit", value: (visits?.first ?? config.createdAt)?.formatted(date: .numeric, time: .standard) ?? unknown))
            rows.append(.init(key: "Foil Info Last Visit", value: (visits?.last ?? config.createdAt)?.formatted(date: .numeric, time: .standard) ?? unknown))
            rows.append(contentsOf: metadata.rows)
            presentFoilInformation(rows: rows, source: source, available: metadata.available, window: window, state: state)
        }
    }

    private func presentFoilInformation(rows: [FoilInformation.Row], source: URL?, available: Bool, window: NSWindow, state: AppState) {
        let panel = FoilInformationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.title = NSLocalizedString("Foil Information", comment: "")
        panel.isReleasedWhenClosed = false
        panel.appearance = window.effectiveAppearance

        let heading = NSTextField(labelWithString: panel.title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.isSelectable = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: panel.title)!)
        icon.contentTintColor = .secondaryLabelColor
        let header = NSStackView(views: [icon, heading])
        header.spacing = 10
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 22).isActive = true

        // 固定两列宽度，让长路径换行；标签与内容都使用原生可选文本控件。
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        for row in rows {
            let label = NSTextField(wrappingLabelWithString: NSLocalizedString(row.key, comment: ""))
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.isSelectable = true
            label.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let value = NSTextField(wrappingLabelWithString: row.value)
            value.font = .systemFont(ofSize: 13)
            value.isSelectable = true
            value.maximumNumberOfLines = 0
            value.lineBreakMode = .byCharWrapping
            let entry = NSStackView(views: [label, value])
            entry.alignment = .firstBaseline
            entry.spacing = 16
            if row.key == "Foil Info Title", state.toConfig().canRenameTitle {
                let button = FoilTitleEditButton(title: "", target: self, action: #selector(editFoilTitle(_:)))
                button.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: NSLocalizedString("Change Title", comment: ""))
                button.bezelStyle = .accessoryBarAction
                button.toolTip = NSLocalizedString("Change Title", comment: "")
                button.setAccessibilityLabel(NSLocalizedString("Change Title", comment: ""))
                button.appState = state
                button.titleLabel = value
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                entry.addArrangedSubview(button)
                value.widthAnchor.constraint(equalToConstant: 288).isActive = true
            } else if let field = TerminalConfigurationField(rawValue: row.key), state.terminalConfiguration != nil {
                let button = FoilTerminalEditButton(title: "", target: self, action: #selector(editTerminalConfiguration(_:)))
                button.field = field
                button.appState = state
                button.valueLabel = value
                let editLabel = String(format: NSLocalizedString("Edit Terminal Field Format", comment: ""), NSLocalizedString(row.key, comment: ""))
                button.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: editLabel)
                button.bezelStyle = .accessoryBarAction
                button.toolTip = editLabel
                button.setAccessibilityLabel(editLabel)
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                entry.addArrangedSubview(button)
                value.widthAnchor.constraint(equalToConstant: 288).isActive = true
            } else if row.key == "Foil Info File Path", let source {
                let button = SourceRevealButton(title: "", target: self, action: #selector(revealFoilSource(_:)))
                button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: NSLocalizedString("Show in Finder", comment: ""))
                button.bezelStyle = .accessoryBarAction
                button.toolTip = NSLocalizedString("Show in Finder", comment: "")
                button.setAccessibilityLabel(NSLocalizedString("Show in Finder", comment: ""))
                button.isEnabled = available
                button.sourceURL = source
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                entry.addArrangedSubview(button)
                value.widthAnchor.constraint(equalToConstant: 288).isActive = true
            } else {
                value.widthAnchor.constraint(equalToConstant: 332).isActive = true
            }
            value.preferredMaxLayoutWidth = row.key == "Foil Info Title" || TerminalConfigurationField(rawValue: row.key) != nil ? 288 : 332
            stack.addArrangedSubview(entry)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FoilInformationDocumentView()
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalToConstant: 520)
        ])
        document.layoutSubtreeIfNeeded()
        let height = document.fittingSize.height
        document.setFrameSize(NSSize(width: 520, height: height))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.documentView = document
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(height, 420)).isActive = true

        let card = NSBox()
        card.boxType = .custom
        card.titlePosition = .noTitle
        card.cornerRadius = 10
        card.borderWidth = 1
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.contentViewMargins = .zero
        card.contentView = scroll
        card.widthAnchor.constraint(equalToConstant: 520).isActive = true
        card.heightAnchor.constraint(equalToConstant: min(height, 420)).isActive = true

        let done = NSButton(title: NSLocalizedString("OK", comment: ""), target: self, action: #selector(dismissFoilInformation(_:)))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        let footer = NSStackView(views: [NSView(), done])
        footer.widthAnchor.constraint(equalToConstant: 520).isActive = true
        let layout = NSStackView(views: [header, card, footer])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 18
        layout.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        panel.contentView = content
        panel.setContentSize(NSSize(width: 560, height: min(height, 420) + 126))
        panel.initialFirstResponder = done
        window.beginSheet(panel)
    }

    @objc private func editFoilTitle(_ sender: FoilTitleEditButton) {
        guard let state = sender.appState, state.toConfig().canRenameTitle, let panel = sender.window, panel.attachedSheet == nil else { return }
        let id = state.id
        let alert = FoilTitleEditing.makeAlert(title: FoilTitleEditing.editableTitle(for: state.toConfig()))
        alert.beginSheetModal(for: panel) { [weak sender, weak state] response in
            guard response == .alertFirstButtonReturn, let state, state.id == id, state.toConfig().canRenameTitle,
                  let field = alert.accessoryView as? NSTextField else { return }
            HistoryManager.shared.updateHistoryTitle(configId: id, newTitle: field.stringValue)
            sender?.titleLabel?.stringValue = state.toConfig().historyMenuDisplayName
            if let label = sender?.titleLabel { self.resizeInformationDocument(containing: label) }
        }
    }

    @objc private func editTerminalConfiguration(_ sender: FoilTerminalEditButton) {
        guard let state = sender.appState, let configuration = state.terminalConfiguration,
              let field = sender.field, let panel = sender.window, panel.attachedSheet == nil else { return }
        let id = state.id
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString("Edit Terminal Field Format", comment: ""), NSLocalizedString(field.rawValue, comment: ""))
        alert.informativeText = NSLocalizedString("Terminal Configuration Edit Note", comment: "")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let readValue: () -> String
        if field.isMultiline {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            scroll.wantsLayer = true
            scroll.layer?.cornerRadius = 6
            scroll.layer?.borderWidth = 1
            scroll.layer?.borderColor = NSColor.separatorColor.cgColor
            scroll.layer?.masksToBounds = true
            let text = NSTextView(frame: scroll.bounds)
            text.isRichText = false
            text.textContainerInset = NSSize(width: 6, height: 6)
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.string = field.value(in: configuration)
            scroll.documentView = text
            alert.accessoryView = scroll
            alert.window.initialFirstResponder = text
            readValue = { text.string }
        } else {
            let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
            text.stringValue = field.value(in: configuration)
            alert.accessoryView = text
            alert.window.initialFirstResponder = text
            readValue = { text.stringValue }
        }
        alert.beginSheetModal(for: panel) { [weak sender, weak state] response in
            guard response == .alertFirstButtonReturn, let state, state.id == id,
                  let current = state.terminalConfiguration else { return }
            do {
                let updated = try field.updating(current, with: readValue())
                try state.updateTerminalConfiguration(updated)
                sender?.valueLabel?.stringValue = field.value(in: updated)
                if let label = sender?.valueLabel { self.resizeInformationDocument(containing: label) }
            } catch {
                let failure = NSAlert()
                failure.messageText = NSLocalizedString("Terminal Configuration Failed", comment: "")
                failure.informativeText = (error as? AgentFailure)?.code ?? "INVALID_ARGUMENTS"
                failure.beginSheetModal(for: panel)
            }
        }
    }

    private func resizeInformationDocument(containing label: NSTextField) {
        label.invalidateIntrinsicContentSize()
        guard let document = label.enclosingScrollView?.documentView else { return }
        document.layoutSubtreeIfNeeded()
        document.setFrameSize(NSSize(width: document.frame.width, height: document.fittingSize.height))
    }

    @objc private func dismissFoilInformation(_ sender: NSButton) {
        guard let sheet = sender.window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    @objc private func revealFoilSource(_ sender: SourceRevealButton) {
        guard let url = sender.sourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private final class FoilTitleEditButton: NSButton {
    weak var appState: AppState?
    weak var titleLabel: NSTextField?
}

private final class FoilTerminalEditButton: NSButton {
    weak var appState: AppState?
    weak var valueLabel: NSTextField?
    var field: TerminalConfigurationField?
}

private final class SourceRevealButton: NSButton {
    var sourceURL: URL?
}

/// 长内容从第一行开始显示，保持与常见信息面板一致的滚动方向。
private final class FoilInformationDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class FoilInformationPanel: NSPanel {
    // 选中文字后焦点会落到系统 field editor；在窗口层接住 Esc，避免它只取消文本选择。
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            cancelOperation(nil)
            return
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        sheetParent?.endSheet(self)
    }
}
