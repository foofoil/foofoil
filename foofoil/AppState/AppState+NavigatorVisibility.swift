//  AppState+NavigatorVisibility.swift
//  foofoil

import Foundation

/// 侧边栏模式切换后的视觉反馈：始终显示为红框，自动为灰框；每次切换生成新的 id，驱动面板闪一下。
struct NavigatorModeFeedback: Equatable {
    enum Tone {
        case active
        case automatic
    }

    let id = UUID()
    let tone: Tone
    let date = Date()
}

extension AppState {
    /// 切换到“自动”后，面板临时展开的时长，让灰框反馈可见。
    static let navigatorModeRevealDuration: TimeInterval = 1.2

    func cycleNavigatorPanelVisibilityMode() {
        setNavigatorPanelVisibilityMode(navigatorPanelVisibilityMode.next)
    }

    func setNavigatorPanelVisibilityMode(_ mode: NavigatorPanelVisibilityMode) {
        guard mode != navigatorPanelVisibilityMode else { return }
        navigatorPanelVisibilityMode = mode
        isNavigatorPanelExplicitlyVisible = false

        switch mode {
        case .hidden:
            // 隐藏后提供恢复入口，使用当前配置的快捷键。
            endNavigatorSearch()
            let message: String
            if let shortcut = KeyboardShortcutStore.shared.shortcut(forID: "view.toggleNavigator") {
                message = String(format: NSLocalizedString("Navigator Hidden Shortcut Toast", comment: ""), shortcut.displayString)
            } else {
                message = NSLocalizedString("Navigator Hidden Menu Toast", comment: "")
            }
            toast.show(message, symbolName: "sidebar.squares.leading", duration: .seconds(3))
        case .always:
            navigatorModeFeedback = NavigatorModeFeedback(tone: .active)
        case .onHover:
            let feedback = NavigatorModeFeedback(tone: .automatic)
            navigatorModeFeedback = feedback
            // 自动模式下面板本应收起，这里临时展开一段时间以展示灰框，之后交还给悬停判定。
            isNavigatorPanelExplicitlyVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.navigatorModeRevealDuration) { [weak self] in
                guard let self, self.navigatorModeFeedback == feedback,
                      self.navigatorPanelVisibilityMode == .onHover else { return }
                self.isNavigatorPanelExplicitlyVisible = false
            }
        }
    }
}
