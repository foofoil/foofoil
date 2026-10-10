import SwiftUI
import AppKit

struct FileOpenFeedbackView: View {
    let failures: [FileOpenFeedback]
    let onClose: () -> Void

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
