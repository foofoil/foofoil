import AppKit
import Combine
import SwiftUI

/// 每个箔片或面板独立拥有瞬时提示；内容不进入持久状态，也不创建系统通知。
@MainActor
final class FoilToastCenter: ObservableObject {
    nonisolated struct Message: Identifiable, Equatable, Sendable {
        let id = UUID()
        let text: String
        let symbolName: String?
        let usesIncognitoIcon: Bool
    }

    @Published private(set) var message: Message?
    private var dismissTask: Task<Void, Never>?

    /// 调用者传入已本地化的完整文案；连续通知替换当前提示并重新计时。
    func show(_ text: String, symbolName: String? = nil, usesIncognitoIcon: Bool = false, duration: Duration = .seconds(1.5)) {
        dismissTask?.cancel()
        let message = Message(text: text, symbolName: symbolName, usesIncognitoIcon: usesIncognitoIcon)
        self.message = message
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) }
            catch { return }
            guard let self, self.message?.id == message.id else { return }
            self.message = nil
            self.dismissTask = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        message = nil
    }

    deinit { dismissTask?.cancel() }
}

extension View {
    /// 通用顶部提示层：不参与正文布局，不接管鼠标或键盘焦点。
    func foilToast(_ center: FoilToastCenter, isSuppressed: Bool = false) -> some View {
        modifier(FoilToastModifier(center: center, isSuppressed: isSuppressed))
    }
}

private struct FoilToastModifier: ViewModifier {
    @ObservedObject var center: FoilToastCenter
    let isSuppressed: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message = center.message, !isSuppressed {
                    HStack(spacing: 6) {
                        if message.usesIncognitoIcon {
                            Image(nsImage: IncognitoFoilIcon.image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                        } else if let symbolName = message.symbolName {
                            Image(systemName: symbolName).accessibilityHidden(true)
                        }
                        Text(message.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .id(message.id)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message.text)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: center.message?.id)
            .onChange(of: center.message?.id) { _, _ in
                guard let message = center.message, !isSuppressed else { return }
                NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
                    .announcement: message.text,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue
                ])
            }
            .onDisappear { center.dismiss() }
    }
}
