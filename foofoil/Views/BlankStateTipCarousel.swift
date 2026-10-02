//
//  BlankStateTipCarousel.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI

// 空白窗口中的随机操作提示。
struct BlankStateTipCarousel: View {
    @State private var shortcutRevision = 0
    @State private var displayedTip = ""
    @State private var horizontalOffset: CGFloat = 0
    @State private var isVisible = false

    private var tips: [String] {
        [
            NSLocalizedString("Tip: Drop image, PDF, or Markdown", comment: ""),
            NSLocalizedString("Tip: Type directly to write a note", comment: ""),
            NSLocalizedString("Tip: Hold Command while dragging to move the window", comment: ""),
            NSLocalizedString("Tip: Try a two-finger pinch", comment: "")
        ] + [
            ("view.togglePin", "Shortcut Tip Pin"),
            ("file.openURL", "Shortcut Tip URL"),
            ("file.openClipboardContent", "Shortcut Tip Clipboard")
        ].compactMap { identifier, titleKey in
            guard let shortcut = KeyboardShortcutStore.shared.shortcut(forID: identifier) else { return nil }
            return String(format: NSLocalizedString(titleKey, comment: ""), shortcut.displayString)
        }
    }

    var body: some View {
        Text(displayedTip)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary.opacity(0.72))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .offset(x: horizontalOffset)
            .opacity(isVisible ? 1 : 0)
            .onReceive(NotificationCenter.default.publisher(for: .keyboardShortcutsDidChange)) { _ in
                shortcutRevision += 1
            }
            .task(id: shortcutRevision) {
                // 每次进入空白状态时重新洗牌，随后按该顺序轮播。
                await rotateTips(in: tips.shuffled())
            }
    }

    private func rotateTips(in orderedTips: [String]) async {
        guard !orderedTips.isEmpty else { return }

        while !Task.isCancelled {
            for tip in orderedTips {
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    displayedTip = ""
                    horizontalOffset = 0
                    isVisible = true
                }

                for character in tip {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        displayedTip.append(character)
                    }
                    guard await pause(for: 35_000_000) else { return }
                }

                guard await pause(for: 4_500_000_000) else { return }

                await MainActor.run {
                    withAnimation(.easeIn(duration: 0.35)) {
                        horizontalOffset = -180
                        isVisible = false
                    }
                }

                guard await pause(for: 550_000_000) else { return }
            }
        }
    }

    private func pause(for nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
