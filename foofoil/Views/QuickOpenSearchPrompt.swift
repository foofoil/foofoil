import AppKit
import SwiftUI

/// 提示独立于实际输入，按可用宽度整体缩放，键帽和文字始终保持同一行。
struct QuickOpenSearchPrompt: View {
    let musicLibraryEnabled: Bool
    var compact = false
    var onSlash: () -> Void = {}

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
                    .allowsHitTesting(false)
                Button(action: onSlash) { Text("/")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 16, height: 17)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Quick Open More Options", comment: ""))
                Text(NSLocalizedString("Quick Open More Options", comment: ""))
                    .font(.system(size: 11))
                    .allowsHitTesting(false)
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.secondary)
            .scaleEffect(scale, anchor: .leading)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }
}

/// 仅键帽接收点击，其余提示区域继续交给输入框。
final class QuickOpenPromptHostingView: NSHostingView<QuickOpenSearchPrompt> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let prompt = rootView
        let title = prompt.compact ? NSLocalizedString("Blank Foil Open Prompt", comment: "") : QuickOpenSearchPrompt.title(musicLibraryEnabled: prompt.musicLibraryEnabled)
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let scale = min(1, max(0, bounds.width) / QuickOpenSearchPrompt.idealWidth(musicLibraryEnabled: prompt.musicLibraryEnabled, compact: prompt.compact))
        guard local.x >= (titleWidth + 6) * scale, local.x <= (titleWidth + 22) * scale else { return nil }
        return super.hitTest(point)
    }
}
