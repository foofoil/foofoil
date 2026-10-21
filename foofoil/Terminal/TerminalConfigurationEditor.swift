import AppKit
import SwiftUI
import Combine

@MainActor
private final class TerminalEditorModel: ObservableObject {
    @Published var title = ""
    @Published var directory = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var shell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) } ?? "/bin/zsh"
    @Published var environment = ""
    @Published var commands = ""
    weak var window: NSWindow?
    func configuration() throws -> TerminalLaunchConfiguration {
        var values: [String: String] = [:]
        for line in environment.split(separator: "\n") {
            guard let equal = line.firstIndex(of: "=") else { throw AgentFailure("INVALID_ARGUMENTS") }
            let key = String(line[..<equal]); let value = String(line[line.index(after: equal)...])
            guard values[key] == nil else { throw AgentFailure("INVALID_ARGUMENTS") }
            values[key] = value
        }
        return TerminalLaunchConfiguration(shellPath: shell, workingDirectory: directory, environment: values, startupCommands: commands)
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
                fieldLabel("Terminal Directory")
                HStack(spacing: 6) {
                    singleLineField("Terminal Directory", text: $model.directory)
                    Button(action: chooseDirectory) {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel(Text("Choose Terminal Directory"))
                    .help("Choose Terminal Directory")
                }
            }
            GridRow {
                fieldLabel("Terminal Shell")
                singleLineField("Terminal Shell", text: $model.shell)
            }
            GridRow {
                fieldLabel("Terminal Environment Label")
                VStack(alignment: .leading, spacing: 5) {
                    multilineField("Terminal Environment", text: $model.environment, height: 64, field: .environment)
                    Text("Terminal Environment Note").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                fieldLabel("Terminal Trusted Script")
                multilineField("Terminal Trusted Script", text: $model.commands, height: 120, field: .commands)
            }
        }.padding(8).frame(width: 480, height: 370)
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
    var onOpen: (@MainActor @Sendable () -> Void)?

    func finish(open: Bool) {
        let action = open ? onOpen : nil
        onOpen = nil
        orderOut(nil)
        Self.current = nil
        super.close()
        if let action { DispatchQueue.main.async(execute: action) }
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
        let panel = TerminalConfigurationPanel(contentRect: NSRect(x: 0, y: 0, width: 512, height: 430),
                                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("Open Terminal Title", comment: "")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        model.window = panel
        TerminalConfigurationPanel.current = panel
        panel.onOpen = { [weak self] in
            guard let self else { return }
            do { _ = try self.applicationControl.createTerminal(model.configuration(), title: model.title, incognito: isIncognito, reuseBlankWindow: true) }
            catch {
                let failure = NSAlert()
                failure.messageText = NSLocalizedString("Terminal Configuration Failed", comment: "")
                failure.informativeText = (error as? AgentFailure)?.code ?? "INVALID_ARGUMENTS"
                failure.runModal()
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
