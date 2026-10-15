import SwiftUI
import UniformTypeIdentifiers

struct ArchiveContentView: View {
    @ObservedObject var session: ArchiveSession

    var body: some View {
        VStack(spacing: 12) {
            if session.busy {
                ProgressView()
                Button(NSLocalizedString("Cancel", comment: "")) { session.cancelPreview() }
            } else {
                Image(systemName: session.selected?.isDirectory == true ? "folder" : "archivebox")
                    .font(.largeTitle).foregroundStyle(.secondary)
                if let entry = session.selected {
                    Text(entry.id == "root" ? session.source.primaryURL.lastPathComponent : entry.name).font(.headline)
                    Text(entry.path.isEmpty ? "/" : entry.path).font(.caption).textSelection(.enabled).id(entry.id)
                    Text(entry.isDirectory ? NSLocalizedString("Archive Directory", comment: "") : UTType(filenameExtension: (entry.path as NSString).pathExtension)?.localizedDescription ?? NSLocalizedString("Archive File", comment: ""))
                    if let size = entry.size {
                        Text(String(format: NSLocalizedString("Archive Original Size Format", comment: ""), ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
                    }
                    Text(NSLocalizedString("Archive Compressed Size Unknown", comment: "")).font(.caption)
                    if let format = session.selectedFormat, !format.isEmpty { Text(format).font(.caption) }
                    Button(NSLocalizedString("Save As...", comment: "")) { session.saveSelected() }
                        .disabled(!session.canExport)
                } else {
                    Text(NSLocalizedString("Archive Select File", comment: ""))
                }
                if session.preview?.isFileOpenFeedback == true {
                    Text(NSLocalizedString("Archive Save Before Opening", comment: "")).font(.caption)
                }
                if session.index == nil {
                    Button(NSLocalizedString("Archive Reload", comment: "")) { session.load() }
                    if session.urls.count > 1 || session.source.primaryURL.lastPathComponent.range(of: #"\.(part\d+\.rar|7z\.\d{3}|r\d{2})$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                        Button(NSLocalizedString("Archive Locate Volumes", comment: "")) { session.locateVolumes?() }
                    }
                }
            }
            if let message = session.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).id(message)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 仅桥接压缩包会话；成功打开的文件使用普通箔片的完整呈现层。
struct ArchiveFoilView: View {
    @ObservedObject var windowState: AppState
    @ObservedObject var session: ArchiveSession

    var body: some View {
        FoilContentView(appState: session.preview ?? windowState, windowState: windowState, archive: session)
            .id(session.preview?.id ?? windowState.id)
            .overlay(alignment: .bottom) {
                if session.exporting {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(NSLocalizedString("Archive Exporting", comment: ""))
                        Text(ByteCountFormatter.string(fromByteCount: session.exportedBytes, countStyle: .file))
                        Button(NSLocalizedString("Cancel", comment: "")) { session.cancelExport() }
                    }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        .sheet(isPresented: $session.needsPassword, onDismiss: { if !session.needsPassword { session.cancelUnlock() } }) {
            VStack(alignment: .leading, spacing: 14) {
                Text(NSLocalizedString("Archive Password Title", comment: "")).font(.headline)
                Text(session.passwordPromptName).font(.subheadline).textSelection(.enabled)
                Text(NSLocalizedString("Archive Password Required", comment: "")).font(.caption)
                SecureField(NSLocalizedString("Archive Password", comment: ""), text: $session.passwordInput)
                    .onSubmit { session.unlock() }
                HStack {
                    Button(NSLocalizedString("Cancel", comment: "")) { session.cancelUnlock() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(NSLocalizedString("Archive Unlock", comment: "")) { session.unlock() }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 360)
        }
    }
}
