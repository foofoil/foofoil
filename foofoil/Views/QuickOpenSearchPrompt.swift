import AppKit
import SwiftUI

/// 提示独立于实际输入，按可用宽度整体缩放，键帽和文字始终保持同一行。
struct QuickOpenSearchPrompt: View {
    let musicLibraryEnabled: Bool
    var compact = false

    static func title(musicLibraryEnabled: Bool) -> String {
        NSLocalizedString(musicLibraryEnabled ? "Quick Open Prompt With Music" : "Quick Open Prompt", comment: "")
    }

    static func idealWidth(musicLibraryEnabled: Bool, compact: Bool = false) -> CGFloat {
        let title = compact ? NSLocalizedString("Blank Foil Open Prompt", comment: "") : title(musicLibraryEnabled: musicLibraryEnabled)
        let more = NSLocalizedString("Quick Open More Options", comment: "")
        return (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
            + (more as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 34
    }

    var body: some View {
        GeometryReader { proxy in
            let width = Self.idealWidth(musicLibraryEnabled: musicLibraryEnabled, compact: compact)
            let scale = min(1, max(0, proxy.size.width) / width)
            HStack(spacing: 6) {
                Text(compact ? NSLocalizedString("Blank Foil Open Prompt", comment: "") : Self.title(musicLibraryEnabled: musicLibraryEnabled))
                    .font(.system(size: 13))
                Text("/")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 16, height: 17)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.3)))
                Text(NSLocalizedString("Quick Open More Options", comment: ""))
                    .font(.system(size: 11))
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.secondary)
            .scaleEffect(scale, anchor: .leading)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .accessibilityHidden(true)
    }
}

/// 提示覆盖在原生输入框上方，但点击仍穿透到输入框。
final class QuickOpenPromptHostingView: NSHostingView<QuickOpenSearchPrompt> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
