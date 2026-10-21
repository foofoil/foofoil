import SwiftUI
import SwiftTerm

struct TerminalFoilView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var appState: AppState
    var body: some View {
        VStack(spacing: 0) {
            if let previous = session.previousOutput {
                TerminalPreviousOutputView(previousOutput: previous, showsNewSession: session.state != .waiting)
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
                HStack {
                    Text(String(format: NSLocalizedString("Terminal Exit Format", comment: ""), code.map(String.init) ?? "—"))
                    Spacer()
                    Button("Restart Terminal") { appState.prepareTerminal(session.configuration, start: true) }
                }.font(.caption).padding(8)
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
    func startTerminalForExplicitOpen() {
        guard terminalConfiguration != nil else { return }
        if let session = terminalSession {
            switch session.state {
            case .exited, .failed:
                prepareTerminal(session.configuration, start: true)
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
