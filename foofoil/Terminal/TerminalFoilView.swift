import SwiftUI
import SwiftTerm

struct TerminalFoilView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var appState: AppState
    @ObservedObject private var search: FoilContentSearch

    init(session: TerminalSession, appState: AppState) {
        self.session = session; self.appState = appState; self.search = appState.contentSearch
    }

    var body: some View {
        VStack(spacing: 0) {
            if let previous = session.previousOutput {
                TerminalPreviousOutputView(search: appState.contentSearch, isHidden: $session.isPreviousOutputHidden, previousOutput: previous, showsNewSession: session.state != .waiting,
                    onClear: { appState.clearPreviousTerminalOutput() })
                    .id(session.id)
                    // 历史记录的标题及关闭按钮必须位于搜索栏下方。
                    .padding(.top, search.isPresented && !session.isPreviousOutputHidden ? 40 : 0)
            }
            if session.state != .waiting {
                TerminalSurface(session: session, font: appState.documentFont(size: CGFloat(appState.textFontSize)),
                    foregroundColor: appState.documentTextColor, backgroundColor: appState.contentBackgroundColor, isSearching: search.isPresented && (session.previousOutput == nil || session.isPreviousOutputHidden))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            switch session.state {
            case .waiting:
                VStack(alignment: .leading, spacing: 12) {
                    Label("Terminal Ready", systemImage: "terminal")
                    Text(session.configuration.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path).font(.caption).textSelection(.enabled)
                    if !session.configuration.startupCommands.isEmpty {
                        Text("Terminal Trusted Script").font(.caption).foregroundStyle(.secondary)
                        ScrollView { Text(session.configuration.startupCommands).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 180)
                    }
                    Button("Start Terminal") { session.start() }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            case .running: EmptyView()
            case .closing: Text("Terminal Closing").font(.caption).padding(6)
            case .exited(let code):
                // 会话结束后箔片会被宿主关闭，这里只保留退出信息作为兜底显示。
                Text(String(format: NSLocalizedString("Terminal Exit Format", comment: ""), code.map(String.init) ?? "—"))
                    .font(.caption).padding(8)
            case .failed(let code):
                if code == "SSH_SESSION_FAILED" {
                    HStack {
                        Text("Terminal SSH Failed").foregroundStyle(.red)
                        Spacer()
                        Button("Terminal SSH Retry") { appState.startTerminalForExplicitOpen() }
                    }.font(.caption).padding(8)
                } else {
                    Text(code).font(.caption).foregroundStyle(.red).padding(8)
                }
            }
        }
        .padding(8)
        .foregroundStyle(Color(nsColor: appState.documentTextColor ?? .textColor))
        .background(Color(nsColor: appState.contentBackgroundColor ?? .textBackgroundColor))
    }
}

private struct TerminalPreviousOutputView: View {
    @ObservedObject var search: FoilContentSearch
    @Binding var isHidden: Bool
    @State private var expandedBeforeSearch = false
    let previousOutput: String
    let showsNewSession: Bool
    let onClear: () -> Void
    @State private var confirmsClear = false
    @State private var isExpanded = false
    @State private var preparedOutput: AttributedString?

    var body: some View {
        if !isHidden {
            VStack(spacing: 8) {
                HStack {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            Text("Terminal Previous Output")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
                    Spacer()
                    Button { confirmsClear = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear Previous Terminal Output"))
                    .help("Clear Previous Terminal Output")
                    Button {
                        // 仅隐藏当前视图；会话快照仍保留，下次从历史打开时重新显示。
                        isHidden = true
                        search.refreshSurface()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Hide Previous Terminal Output"))
                    .help("Hide Previous Terminal Output")
                }
                if isExpanded {
                    Group {
                        if let preparedOutput {
                            ReadOnlyTextView(text: String(preparedOutput.characters), font: .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), textColor: nil, lineHeightMultiple: nil, paragraphSpacingMultiple: nil)
                        } else {
                            ProgressView("Loading...").controlSize(.small)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: 150)
                    .task {
                        guard preparedOutput == nil else { return }
                        // 先让加载状态参与绘制，再准备只读文本；收起或隐藏时任务自动取消。
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        preparedOutput = AttributedString(previousOutput)
                    }
                }
            }
            .padding(8)
            .onChange(of: search.isPresented, initial: true) { _, active in
                if active { expandedBeforeSearch = isExpanded; isExpanded = true }
                else { isExpanded = expandedBeforeSearch }
            }
            .alert("Clear Previous Terminal Output", isPresented: $confirmsClear) {
                Button("Clear Previous Terminal Output Confirm", role: .destructive) { onClear() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Clear Previous Terminal Output Message")
            }
            Divider()
            if showsNewSession {
                Text("Terminal New Session").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
        }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession
    let font: NSFont
    let foregroundColor: NSColor?
    let backgroundColor: NSColor?
    let isSearching: Bool
    func makeNSView(context: Context) -> TerminalSearchViewport {
        let container = TerminalSearchViewport(terminal: session.view)
        if !isSearching { DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) } }
        return container
    }
    func updateNSView(_ view: TerminalSearchViewport, context: Context) {
        session.view.applyDocumentStyle(font: font, foregroundColor: foregroundColor, backgroundColor: backgroundColor)
        view.searchInset = isSearching ? 40 : 0
    }
}

/// 只裁切可见区域，不改终端画布尺寸；搜索条出现不会改变 PTY 行列数或触发输出重排。
final class TerminalSearchViewport: NSView {
    let terminal: FoilTerminalView
    private let clip = NSClipView()
    private var appliedSearchInset: CGFloat = 0
    var searchInset: CGFloat = 0 { didSet { if oldValue != searchInset { needsLayout = true } } }
    init(terminal: FoilTerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        clip.drawsBackground = false
        terminal.autoresizingMask = []
        clip.documentView = terminal
        addSubview(clip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        let previousOrigin = clip.bounds.origin
        clip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(1, bounds.height - searchInset))
        terminal.frame = NSRect(origin: .zero, size: bounds.size)
        // 只在进入搜索时对齐顶部；后续布局保留定位结果，避免把底部匹配重新裁掉。
        let y = appliedSearchInset == 0 && searchInset > 0 ? searchInset : previousOrigin.y
        appliedSearchInset = searchInset
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, terminal.frame.height - clip.bounds.height), max(0, y))))
    }

}

extension AppState {
    func clearPreviousTerminalOutput() {
        guard let terminalSession else { return }
        // 同一历史项可能有多个窗口；一并移除旧快照，避免其他窗口的自动保存把它写回。
        let peers = (NSApp.delegate as? AppDelegate)?.windowControllers.map(\.appState)
            .filter { $0.id == id && $0.isIncognito == isIncognito } ?? []
        for peer in peers { peer.terminalSession?.clearPreviousOutput() }
        terminalSession.clearPreviousOutput()
        saveState()
        guard !isIncognito else { return }
        let snapshot = terminalSession.outputSnapshot
        // 恢复配置也可能保留快照副本，必须同时清除，不能只隐藏当前视图。
        SettingsStore.shared.windowConfigs = SettingsStore.shared.windowConfigs.map { config in
            var updated = config
            if updated.id == id { updated.terminalScrollback = snapshot }
            return updated
        }
        SettingsStore.shared.lastOpenWindowConfigs = SettingsStore.shared.lastOpenWindowConfigs.map { config in
            var updated = config
            if updated.id == id { updated.terminalScrollback = snapshot }
            return updated
        }
    }

    func startTerminalForExplicitOpen() {
        guard terminalConfiguration != nil else { return }
        if let session = terminalSession {
            switch session.state {
            case .exited, .failed:
                prepareTerminal(terminalConfiguration ?? session.configuration, start: true)
            default: session.start()
            }
        }
    }
    func configureTerminalSnapshotSaving() {
        terminalSession?.onOutputSnapshotChanged = isIncognito ? nil : { [weak self] in self?.saveState() }
        let session = terminalSession
        session?.onConnected = isIncognito ? nil : { [weak self, weak session] in
            guard let self, let session, self.terminalSession === session else { return }
            self.saveState()
        }
    }
    func prepareTerminal(_ configuration: TerminalLaunchConfiguration, start: Bool) {
        let previous = isIncognito ? nil : terminalSession?.outputSnapshot
        terminalSession?.onOutputSnapshotChanged = nil
        terminalSession?.stop()
        terminalConfiguration = configuration
        terminalSession = TerminalSession(configuration: configuration, previousOutput: previous)
        configureTerminalSnapshotSaving()
        if start { terminalSession?.start() }
        saveState()
    }
}
