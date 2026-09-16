//
//  MovableBackgrounds.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

/// 仅显式标记的背景视图允许伴随窗口拖动箔片，避免吞掉 SwiftUI 控件点击。
protocol ExplicitlyMovableWindowBackground {}

/// 用 SwiftUI 原生手势移动所在窗口。新版 macOS 下 AppKit 不再对 NSHostingView 内容
/// 自动响应 `isMovableByWindowBackground`，无标题栏箔片必须在非交互的背景/内容层
/// 显式声明拖拽区域；位于其上的控件仍优先处理事件，不会被吞掉。
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }
}

final class MovableWindowBackgroundNSView: NSView, ExplicitlyMovableWindowBackground {
    override var mouseDownCanMoveWindow: Bool { true }
}

// 用于让 SwiftUI View 区域阻止 macOS 窗口通过背景进行拖动的辅助容器背景
struct NonMovableBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return NonMovableNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class NonMovableNSView: NSView {
        override var mouseDownCanMoveWindow: Bool {
            return false
        }
    }
}

// 用于将文字模式中露出的边距标记为可移动窗口的原生背景。
struct MovableBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MovableWindowBackgroundNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
