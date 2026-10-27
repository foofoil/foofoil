import SwiftUI

/// 空箔的打开入口直接绑定来源状态，避免主窗口变化导致无痕内容进入普通箔。
struct BlankOpenButtons: View {
    @ObservedObject var appState: AppState
    let showClipboardSearch: () -> Void
    @State private var hovered: Int?
    @State private var shortcutRevision = 0
    @State private var clipboardContent: ClipboardOpenableContent?
    @State private var clipboardChangeCount: Int?

    private struct Item {
        let title: String
        let symbol: String
        let selector: Selector
        let shortcutID: String?
    }

    private var items: [Item] {
        var result = [
            Item(title: "Open File...", symbol: "document", selector: #selector(AppDelegate.openFileAction), shortcutID: "file.openFile"),
            Item(title: "Open Directory...", symbol: "folder", selector: #selector(AppDelegate.openDirectoryAction), shortcutID: "file.openDirectory"),
            Item(title: "Open URL Menu Item", symbol: "link", selector: #selector(AppDelegate.openWebURLAction), shortcutID: "file.openURL"),
            Item(title: "Open Terminal Menu Item", symbol: "terminal", selector: #selector(AppDelegate.openTerminalAction), shortcutID: "file.openTerminal")
        ]
        if CameraCaptureController.isAvailable {
            result.append(Item(title: "Open Camera", symbol: "web.camera.fill", selector: #selector(AppDelegate.openCameraAction), shortcutID: "file.openCamera"))
        }
        result.append(Item(title: appState.isIncognito ? "Exit Incognito Mode" : "Switch to Incognito Foil", symbol: "", selector: #selector(AppDelegate.toggleCurrentFoilIncognitoAction), shortcutID: "file.toggleIncognito"))
        result.append(Item(title: "Foil Overview", symbol: "rectangle.grid.2x2", selector: #selector(AppDelegate.showAllFoilsAction), shortcutID: "window.showAllFoils"))
        return result
    }

    private var opensIncognito: Bool { appState.usesIncognitoOpening }

    private func shortcut(for item: Item) -> String? {
        guard let id = item.shortcutID else { return nil }
        let shortcut = opensIncognito && IncognitoOpening.titles[id] != nil
            ? KeyboardShortcutStore.shared.incognitoShortcut(forID: id)
            : KeyboardShortcutStore.shared.shortcut(forID: id)
        return shortcut?.displayString
    }

    private func title(for item: Item) -> String {
        let key = opensIncognito ? item.shortcutID.flatMap { IncognitoOpening.titles[$0] } ?? item.title : item.title
        return NSLocalizedString(key, comment: "")
    }

    private func refreshClipboard(force: Bool = false) {
        let count = NSPasteboard.general.changeCount
        guard force || clipboardChangeCount != count else { return }
        clipboardChangeCount = count
        clipboardContent = (NSApp.delegate as? AppDelegate)?.clipboardOpenableContent()
    }

    var body: some View {
        let _ = shortcutRevision
        VStack(spacing: 6) {
            BlankFoilHintLayout(buttonIndex: hovered ?? 0, buttonCount: items.count) {
                HStack(spacing: 8) {
                    if let hovered, items.indices.contains(hovered) {
                        let item = items[hovered]
                        Text(title(for: item))
                            .lineLimit(1)
                        if let shortcut = shortcut(for: item) {
                            HStack(spacing: 3) {
                                ForEach(Array(shortcut.enumerated()), id: \.offset) { _, key in
                                    Text(key == "⎋" ? "esc" : String(key))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .fixedSize(horizontal: true, vertical: false)
                                        .padding(.horizontal, key == "⎋" ? 4 : 0)
                                        .frame(minWidth: 16, minHeight: 18)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.25)))
                                }
                            }
                            // 键帽保持完整宽度，空间不足时只压缩左侧说明文字。
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(height: 22)
            .clipped()
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    // 外层接收悬停，使禁用按钮仍能说明不可用原因。
                    ZStack {
                        Button { open(index) } label: {
                            Group {
                                if item.selector == #selector(AppDelegate.toggleCurrentFoilIncognitoAction) {
                                    if appState.isIncognito {
                                        Image(systemName: "shoeprints.fill")
                                            .font(.system(size: 17))
                                    } else {
                                        Image(nsImage: IncognitoFoilIcon.image)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 20, height: 20)
                                    }
                                } else {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 17))
                                }
                            }
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .contentShape(Rectangle())
                                .background(hovered == index ? Color.primary.opacity(0.08) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(title(for: item)))
                        .accessibilityHint(Text(title(for: item)))
                    }
                    .contentShape(Rectangle())
                    .background {
                        HoverTrackingView { hovering in
                            if hovering {
                                refreshClipboard()
                                hovered = index
                            } else if hovered == index { hovered = nil }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            clipboardBanner
        }
        .background(NonMovableBackground())
        .task {
            refreshClipboard(force: true)
            // NSPasteboard 没有内容变化通知；只在空箔存在时检查计数，变化后才解析内容。
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                if NSApp.isActive { refreshClipboard() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshClipboard(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyboardShortcutsDidChange)) { _ in
            shortcutRevision += 1
        }
    }

    private var clipboardShortcut: String? {
        (opensIncognito
            ? KeyboardShortcutStore.shared.incognitoShortcut(forID: "file.openClipboardContent")
            : KeyboardShortcutStore.shared.shortcut(forID: "file.openClipboardContent"))?.displayString
    }

    @ViewBuilder
    private var clipboardBanner: some View {
        HStack(spacing: 6) {
            if let content = clipboardContent {
                Button {
                    refreshClipboard(force: true)
                    guard clipboardContent != nil, let delegate = NSApp.delegate as? AppDelegate else { return }
                    if let controller = delegate.windowControllers.first(where: { $0.appState === appState }) {
                        delegate.activateWindow(controller)
                    }
                    _ = delegate.openClipboardContentInNewWindow(isIncognito: opensIncognito)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                        Text(content.openingTitle(isIncognito: opensIncognito, abbreviatesFileName: false))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let shortcut = clipboardShortcut {
                            Text(shortcut)
                                .font(.system(size: 10, weight: .medium))
                                .fixedSize()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(content.openingTitle(isIncognito: opensIncognito, abbreviatesFileName: false))
                .accessibilityIdentifier("blank.clipboard")
            }
            Button(action: showClipboardSearch) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Browse Clipboard History", comment: ""))
            .accessibilityLabel(NSLocalizedString("Browse Clipboard History", comment: ""))
            .accessibilityIdentifier("blank.clipboardHistory")
        }
        .padding(.bottom, 2)
    }

    private func open(_ index: Int) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        if let controller = delegate.windowControllers.first(where: { $0.appState === appState }) {
            delegate.activateWindow(controller)
        }
        // 临时无痕不改变当前空箔的持久属性，显式打开的入口都落到新的无痕目标。
        let temporaryTarget = appState.isTemporaryIncognito ? AppState(isIncognito: true) : nil
        switch index {
        case 0, 1:
            let target = appState.isTemporaryIncognito ? temporaryTarget : appState
            delegate.openContentPanel(directory: index == 1, target: target)
        case 2:
            HistorySearchWindowController.shared.showURLInput(target: appState.isTemporaryIncognito ? temporaryTarget : appState)
        case 3:
            delegate.openTerminal(isIncognito: opensIncognito)
        default:
            if items[index].selector == #selector(AppDelegate.showAllFoilsAction) {
                delegate.showAllFoilsAction()
            } else if items[index].selector == #selector(AppDelegate.toggleCurrentFoilIncognitoAction) {
                if appState.toggleIncognitoMode() { delegate.updateHistoryMenu() }
            } else if items[index].selector == #selector(AppDelegate.openCameraAction) {
                if appState.isTemporaryIncognito {
                    delegate.openCamera(isIncognito: true)
                } else {
                    appState.showBorder = false
                    appState.openCamera()
                }
            }
        }
    }
}

/// 空箔提示跟随来源左缘；右侧空间不足时向左收进可见区域。
struct BlankFoilHintLayout: Layout {
    var buttonIndex: Int = 0
    var buttonCount: Int = 1
    var sourceLeading: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? subviews.first?.sizeThatFits(.unspecified).width ?? 0, height: 22)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let hint = subviews.first else { return }
        let size = hint.sizeThatFits(ProposedViewSize(width: bounds.width, height: bounds.height))
        let count = CGFloat(max(1, buttonCount))
        let buttonWidth = max(0, (bounds.width - (count - 1) * 4) / count)
        let buttonLeading = CGFloat(buttonIndex) * (buttonWidth + 4)
        let leading = max(0, min(sourceLeading ?? buttonLeading, max(0, bounds.width - size.width)))
        hint.place(at: CGPoint(x: bounds.minX + leading, y: bounds.midY), anchor: .leading,
                   proposal: ProposedViewSize(width: min(size.width, bounds.width), height: bounds.height))
    }
}
