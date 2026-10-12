import SwiftUI

/// ⌘P 与总览搜索共用的来源加载状态：小号进度指示与说明文字同排，颜色由所在界面决定。
struct SearchLoadingStatusView: View {
    let text: String
    var foreground: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(foreground)
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(foreground)
    }
}
