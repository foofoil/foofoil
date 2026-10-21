import SwiftUI
import SwiftTerm

struct TerminalFoilView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var appState: AppState
    var body: some View {
        VStack(spacing: 0) {
            if let previous = session.previousOutput {
                TerminalPreviousOutputView(previousOutput: previous, showsNewSession: session.state != .waiting,
                    onClear: { appState.clearPreviousTerminalOutput() })
                    .id(session.id)
            }
            if session.state != .waiting {
                TerminalSurface(session: session, font: appState.documentFont(size: CGFloat(appState.textFontSize)),
                    foregroundColor: appState.documentTextColor, backgroundColor: appState.contentBackgroundColor)
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
            case .failed(let code): Text(code).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .padding(8)
        .foregroundStyle(Color(nsColor: appState.documentTextColor ?? .textColor))
        .background(Color(nsColor: appState.contentBackgroundColor ?? .textBackgroundColor))
    }
}

private struct TerminalPreviousOutputView: View {
    let previousOutput: String
    let showsNewSession: Bool
    let onClear: () -> Void
    @State private var confirmsClear = false
    @State private var isExpanded = false
    @State private var isHidden = false
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
                            ScrollView {
                                Text(preparedOutput).font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
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
    func makeNSView(context: Context) -> FoilTerminalView {
        let view = session.view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: FoilTerminalView, context: Context) {
        view.applyDocumentStyle(font: font, foregroundColor: foregroundColor, backgroundColor: backgroundColor)
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
