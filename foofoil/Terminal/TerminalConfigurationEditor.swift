import AppKit
import SwiftUI
import Combine

private struct TerminalEditorError: LocalizedError {
    let key: String
    var errorDescription: String? { NSLocalizedString(key, comment: "") }
}

@MainActor
private final class TerminalEditorModel: ObservableObject {
    @Published var title = ""
    @Published var useSSH = false
    @Published var sshHost = ""
    @Published var sshUsername = ""
    @Published var sshPort = "22"
    @Published var directory = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var shell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) } ?? "/bin/zsh"
    @Published var environment = ""
    @Published var commands = ""
    weak var window: NSWindow?
    func configuration() throws -> TerminalLaunchConfiguration {
        var values: [String: String] = [:]
        for line in environment.split(separator: "\n") {
            guard let equal = line.firstIndex(of: "=") else { throw TerminalEditorError(key: "Terminal Invalid Environment") }
            let key = String(line[..<equal]); let value = String(line[line.index(after: equal)...])
            guard values[key] == nil else { throw TerminalEditorError(key: "Terminal Invalid Environment") }
            values[key] = value
        }
        var ssh: TerminalLaunchConfiguration.SSH?
        if useSSH {
            let host = sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = sshUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            guard host.range(of: "^[A-Za-z0-9_:][A-Za-z0-9_.:-]*$", options: .regularExpression) != nil else { throw TerminalEditorError(key: "Terminal Invalid SSH Host") }
            guard username.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { throw TerminalEditorError(key: "Terminal Invalid SSH Username") }
            guard let port = Int(sshPort), (1...65535).contains(port) else { throw TerminalEditorError(key: "Terminal Invalid SSH Port") }
            ssh = .init(host: host, username: username, port: port)
        }
        return TerminalLaunchConfiguration(shellPath: useSSH ? nil : shell, workingDirectory: directory, environment: values, startupCommands: commands, ssh: ssh)
    }
}

private struct TerminalConfigurationEditor: View {
    @ObservedObject var model: TerminalEditorModel
    private enum MultilineField: Hashable { case environment, commands }
    @FocusState private var focusedMultilineField: MultilineField?

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                fieldLabel("Terminal Title")
                singleLineField("Terminal Title", text: $model.title)
            }
            GridRow {
                fieldLabel("Terminal SSH")
                Toggle("Terminal SSH", isOn: $model.useSSH).toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(Text("Terminal SSH"))
                    .onChange(of: model.useSSH) {
                        model.directory = model.useSSH ? "" : FileManager.default.homeDirectoryForCurrentUser.path
                    }
            }
            if model.useSSH {
                GridRow { fieldLabel("Terminal SSH Host"); singleLineField("Terminal SSH Host", text: $model.sshHost) }
                GridRow { fieldLabel("Terminal SSH Username"); singleLineField("Terminal SSH Username", text: $model.sshUsername) }
                GridRow { fieldLabel("Terminal SSH Port"); singleLineField("Terminal SSH Port", text: $model.sshPort) }
            }
            GridRow {
                fieldLabel(model.useSSH ? "Terminal Remote Directory" : "Terminal Directory")
                HStack(spacing: 6) {
                    singleLineField(model.useSSH ? "Terminal Remote Directory" : "Terminal Directory", text: $model.directory)
                    if !model.useSSH { Button(action: chooseDirectory) {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel(Text("Choose Terminal Directory"))
                    .help("Choose Terminal Directory") }
                    if model.useSSH { Text("Terminal Remote Directory Note").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !model.useSSH { GridRow {
                fieldLabel("Terminal Shell")
                singleLineField("Terminal Shell", text: $model.shell)
            } }
            GridRow {
                fieldLabel(model.useSSH ? "Terminal Remote Environment Label" : "Terminal Environment Label")
                VStack(alignment: .leading, spacing: 5) {
                    multilineField(model.useSSH ? "Terminal Remote Environment" : "Terminal Environment", text: $model.environment, height: 64, field: .environment)
                    Text("Terminal Environment Note").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                fieldLabel(model.useSSH ? "Terminal Remote Script" : "Terminal Trusted Script")
                multilineField(model.useSSH ? "Terminal Remote Script" : "Terminal Trusted Script", text: $model.commands, height: 120, field: .commands)
            }
        }.padding(8).frame(width: 480, height: 470, alignment: .top)
    }

    private func chooseDirectory() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.directoryURL = URL(fileURLWithPath: (model.directory as NSString).expandingTildeInPath)
        guard let window = model.window else { return }
        picker.beginSheetModal(for: window) { response in
            if response == .OK, let url = picker.url { model.directory = url.path }
        }
    }

    private func fieldLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .multilineTextAlignment(.trailing)
            .frame(width: 128, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    private func singleLineField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(Text(title))
    }

    private func multilineField(_ title: LocalizedStringKey, text: Binding<String>, height: CGFloat, field: MultilineField) -> some View {
        TextEditor(text: text)
            .focused($focusedMultilineField, equals: field)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                // 焦点不依赖光标闪烁来表达；装饰描边不拦截编辑区点击。
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focusedMultilineField == field ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.55),
                                  lineWidth: focusedMultilineField == field ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(Text(title))
    }

}

// 独立配置面板保持异步生命周期，不用嵌套模态循环阻塞 SwiftUI 与系统光标刷新。
@MainActor
private final class TerminalConfigurationPanel: NSPanel {
    static var current: TerminalConfigurationPanel?
    var onOpen: (@MainActor @Sendable () throws -> Void)?

    func finish(open: Bool) {
        if open {
            do { try onOpen?() }
            catch {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Terminal Configuration Failed", comment: "")
                if let error = error as? TerminalEditorError {
                    alert.informativeText = error.localizedDescription
                } else if (error as? AgentFailure)?.code == "WORKING_DIRECTORY_UNAVAILABLE" {
                    alert.informativeText = NSLocalizedString("Terminal Invalid Directory", comment: "")
                } else {
                    alert.informativeText = NSLocalizedString("Terminal Invalid Configuration", comment: "")
                }
                alert.beginSheetModal(for: self)
                return
            }
        }
        onOpen = nil
        orderOut(nil)
        Self.current = nil
        super.close()
    }

    override func close() { finish(open: false) }
}

extension AppDelegate {
    @objc func openTerminalAction() {
        openTerminal(isIncognito: false)
    }

    func openTerminal(isIncognito: Bool) {
        // 先退出 SwiftUI 的按钮/搜索提交回调，再呈现独立配置面板。
        DispatchQueue.main.async { [weak self] in
            self?.presentTerminalConfiguration(isIncognito: isIncognito)
        }
    }

    private func presentTerminalConfiguration(isIncognito: Bool) {
        if let panel = TerminalConfigurationPanel.current {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let model = TerminalEditorModel()
        let panel = TerminalConfigurationPanel(contentRect: NSRect(x: 0, y: 0, width: 512, height: 530),
                                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("Open Terminal Title", comment: "")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        model.window = panel
        TerminalConfigurationPanel.current = panel
        panel.onOpen = { [weak self] in
            let configuration = try model.configuration()
            let validation = try TerminalBootstrap(configuration: configuration, terminalID: "validation")
            validation.cleanup()
            // 先完成表单校验，再退出按钮回调创建窗口，避免 SwiftUI 回调重入。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                do { _ = try self.applicationControl.createTerminal(configuration, title: model.title, incognito: isIncognito, reuseBlankWindow: true) }
                catch {
                    let failure = NSAlert()
                    failure.messageText = NSLocalizedString("Terminal Configuration Failed", comment: "")
                    failure.informativeText = (error as? AgentFailure)?.code ?? "INVALID_ARGUMENTS"
                    failure.runModal()
                }
            }
        }
        panel.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            TerminalConfigurationEditor(model: model)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { [weak panel] in panel?.finish(open: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { [weak panel] in panel?.finish(open: true) }
                    .keyboardShortcut(.defaultAction)
            }.padding(16)
        }.frame(width: 512))
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
