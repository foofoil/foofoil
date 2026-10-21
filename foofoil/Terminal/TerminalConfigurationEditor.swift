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
                    multilineField("Terminal Environment", text: $model.environment, height: 64)
                    Text("Terminal Environment Note").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            GridRow {
                fieldLabel("Terminal Trusted Script")
                multilineField("Terminal Trusted Script", text: $model.commands, height: 120)
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
        guard let window = NSApp.modalWindow else { return }
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

    private func multilineField(_ title: LocalizedStringKey, text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(0.55)))
            .accessibilityLabel(Text(title))
    }

}

// 使用普通面板避免 NSAlert 的应用图标和说明区域；关闭窗口也要结束模态循环。
@MainActor
private final class TerminalConfigurationPanel: NSPanel {
    @objc func cancelOpening() { NSApp.stopModal(withCode: .cancel) }
    @objc func confirmOpening() { NSApp.stopModal(withCode: .OK) }

    override func close() {
        NSApp.stopModal(withCode: .cancel)
        super.close()
    }
}

extension AppDelegate {
    @objc func openTerminalAction() {
        openTerminal(isIncognito: false)
    }

    func openTerminal(isIncognito: Bool) {
        let model = TerminalEditorModel()
        let panel = TerminalConfigurationPanel(contentRect: NSRect(x: 0, y: 0, width: 512, height: 430),
                                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = NSLocalizedString("Open Terminal Title", comment: "")
        panel.isReleasedWhenClosed = false
        // 模态循环中的结束按钮使用 AppKit target/action，避免 SwiftUI 动作调度滞留。
        let editor = NSHostingView(rootView: TerminalConfigurationEditor(model: model))
        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: panel, action: #selector(TerminalConfigurationPanel.cancelOpening))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let confirm = NSButton(title: NSLocalizedString("Open", comment: ""), target: panel, action: #selector(TerminalConfigurationPanel.confirmOpening))
        confirm.bezelStyle = .rounded
        confirm.keyEquivalent = "\r"
        let content = NSView()
        let divider = NSBox()
        divider.boxType = .separator
        for view in [editor, divider, cancel, confirm] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: content.topAnchor),
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: editor.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            confirm.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            confirm.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            confirm.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.centerYAnchor.constraint(equalTo: confirm.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: confirm.leadingAnchor, constant: -8)
        ])
        panel.contentView = content
        panel.setContentSize(NSSize(width: 512, height: 450))
        panel.defaultButtonCell = confirm.cell as? NSButtonCell
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        guard response == .OK else { return }
        do { _ = try applicationControl.createTerminal(model.configuration(), title: model.title, incognito: isIncognito, reuseBlankWindow: true) }
        catch {
            let failure = NSAlert()
            failure.messageText = NSLocalizedString("Terminal Configuration Failed", comment: "")
            failure.informativeText = (error as? AgentFailure)?.code ?? "INVALID_ARGUMENTS"
            failure.runModal()
        }
    }
}
