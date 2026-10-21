import SwiftUI

/// 空箔的打开入口直接绑定来源状态，避免主窗口变化导致无痕内容进入普通箔。
struct BlankOpenButtons: View {
    @ObservedObject var appState: AppState
    @State private var hovered: Int?
    @State private var shortcutRevision = 0

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
        result.append(Item(title: "Open Clipboard Content", symbol: "doc.on.clipboard", selector: #selector(AppDelegate.openClipboardContentAction), shortcutID: "file.openClipboardContent"))
        result.append(Item(title: "Search History Menu Item", symbol: "magnifyingglass", selector: #selector(AppDelegate.showHistorySearchAction), shortcutID: "history.search"))
        return result
    }

    private func shortcut(for item: Item) -> String? {
        guard let id = item.shortcutID else { return nil }
        let shortcut = appState.isIncognito
            ? KeyboardShortcutStore.shared.incognitoShortcut(forID: id)
            : KeyboardShortcutStore.shared.shortcut(forID: id)
        return shortcut?.displayString
    }

    private func title(for item: Item) -> String {
        let key = appState.isIncognito ? item.shortcutID.flatMap { IncognitoOpening.titles[$0] } ?? item.title : item.title
        return NSLocalizedString(key, comment: "")
    }

    var body: some View {
        let _ = shortcutRevision
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if let hovered, items.indices.contains(hovered) {
                    let item = items[hovered]
                    Text(title(for: item))
                        .lineLimit(1)
                    if let shortcut = shortcut(for: item) {
                        HStack(spacing: 3) {
                            ForEach(Array(shortcut.enumerated()), id: \.offset) { _, key in
                                Text(String(key))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .frame(minWidth: 16, minHeight: 18)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.25)))
                            }
                        }
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(height: 22)
            .allowsHitTesting(false)

            HStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Button { open(index) } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 17))
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                            .background(hovered == index ? Color.primary.opacity(0.08) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(title(for: item)))
                    .onHover { hovering in
                        if hovering { hovered = index }
                        else if hovered == index { hovered = nil }
                    }
                }
            }
        }
        .background(NonMovableBackground())
        .onReceive(NotificationCenter.default.publisher(for: .keyboardShortcutsDidChange)) { _ in
            shortcutRevision += 1
        }
    }

    private func open(_ index: Int) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        if let controller = delegate.windowControllers.first(where: { $0.appState === appState }) {
            delegate.activateWindow(controller)
        }
        switch index {
        case 0, 1:
            delegate.openContentPanel(directory: index == 1, target: appState)
        case 2:
            HistorySearchWindowController.shared.showURLInput(target: appState)
        case 3:
            delegate.openTerminal(isIncognito: appState.isIncognito)
        default:
            if items[index].selector == #selector(AppDelegate.showHistorySearchAction) {
                HistorySearchWindowController.shared.show(isIncognito: appState.isIncognito, target: appState)
            } else if items[index].selector == #selector(AppDelegate.openCameraAction) {
                appState.showBorder = false
                appState.openCamera()
            } else {
                _ = delegate.openClipboardContentInNewWindow(isIncognito: appState.isIncognito)
            }
        }
    }
}
