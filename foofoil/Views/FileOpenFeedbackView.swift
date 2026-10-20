import SwiftUI
import AppKit

struct FileOpenFeedbackView: View {
    let failures: [FileOpenFeedback]
    let onClose: () -> Void

    @State private var removingIDs: Set<String> = []
    @State private var failedIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(spacing: 28) {
                        ForEach(failures) { failure in
                            VStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: failure.url.path))
                                    .resizable().scaledToFit().frame(width: 64, height: 64)
                                    .accessibilityHidden(true)
                                Text(failure.url.lastPathComponent)
                                    .font(.headline).multilineTextAlignment(.center)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text(NSLocalizedString(failure.reason.rawValue, comment: ""))
                                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                                if failure.canRemoveFromHistory {
                                    Button("File Feedback Remove History") {
                                        removingIDs.insert(failure.id)
                                        failedIDs.remove(failure.id)
                                        Task { @MainActor in
                                            let removed = await failure.removeFromHistory()
                                            removingIDs.remove(failure.id)
                                            if removed { onClose() }
                                            else { failedIDs.insert(failure.id) }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(removingIDs.contains(failure.id))
                                }
                                if failedIDs.contains(failure.id) {
                                    Text("File Feedback Remove History Failed")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            Button(NSLocalizedString("Close foofoil", comment: ""), action: onClose)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.bottom, 24)
        }
    }
}
