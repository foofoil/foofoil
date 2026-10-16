import SwiftUI

/// Apple Music 的真实类型图标：红色圆角背景上的白色音符，避免继续使用单色 SF Symbol 无法表达品牌配色。
struct AppleMusicTypeIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.996, green: 0.235, blue: 0.286),
                            Color(red: 0.945, green: 0.059, blue: 0.188)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("♫")
                .font(.system(size: size * 0.62, weight: .bold))
                .foregroundStyle(.white)
                .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
