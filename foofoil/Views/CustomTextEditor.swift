//
//  CustomTextEditor.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

// 自定义文本编辑器，支持随着输入文本区域自动扩展高度
struct CustomTextEditor: NSViewRepresentable {
    private static let minimumEditorHeight: CGFloat = 40

    @Binding var text: String
    @Binding var calculatedHeight: CGFloat
    let fontSize: Double
    let shouldMaintainFocus: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let contentSize = scrollView.contentSize

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true

        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        // 字体样式（圆角设计）
        let systemFont = NSFont.systemFont(ofSize: CGFloat(fontSize))
        if let roundedDescriptor = systemFont.fontDescriptor.withDesign(.rounded) {
            textView.font = NSFont(descriptor: roundedDescriptor, size: CGFloat(fontSize))
        } else {
            textView.font = systemFont
        }
        textView.textColor = .labelColor

        textView.textContainerInset = .zero
        textView.minSize = NSSize(width: 0, height: Self.minimumEditorHeight)
        textView.frame.size.height = Self.minimumEditorHeight

        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.configureFocus(for: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            context.coordinator.parent = self
            if textView.string != text {
                textView.string = text
            }
            let systemFont = NSFont.systemFont(ofSize: CGFloat(fontSize))
            let updatedFont = systemFont.fontDescriptor.withDesign(.rounded).flatMap {
                NSFont(descriptor: $0, size: CGFloat(fontSize))
            } ?? systemFont
            if textView.font?.pointSize != CGFloat(fontSize) {
                textView.font = updatedFont
            }
            // 更新高度
            context.coordinator.updateHeight(nsView)
            context.coordinator.configureFocus(for: textView)
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
        (nsView.documentView as? NSTextView)?.delegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        private weak var observedWindow: NSWindow?
        private var windowDidBecomeKeyObserver: NSObjectProtocol?
        private var isDismantled = false
        private var focusGeneration: UInt64 = 0

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        deinit {
            if let windowDidBecomeKeyObserver {
                NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
            }
        }

        func dismantle() {
            isDismantled = true
            focusGeneration &+= 1
            if let windowDidBecomeKeyObserver {
                NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
                self.windowDidBecomeKeyObserver = nil
            }
            observedWindow = nil
        }

        // SwiftUI 可能在 NSWindow.dealloc 的视图解绑回调中更新编辑器。
        // 此时不能读取并弱引用 textView.window；等解绑完成后再获取当前窗口。
        func configureFocus(for textView: NSTextView) {
            guard !isDismantled else { return }
            focusGeneration &+= 1
            let generation = focusGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, !self.isDismantled, self.focusGeneration == generation,
                      let textView else { return }
                self.observeWindowAndFocus(textView)
            }
        }

        // 空白窗口重新成为活动窗口时，恢复输入焦点以便直接输入。
        private func observeWindowAndFocus(_ textView: NSTextView) {
            let window = textView.window
            if window !== observedWindow {
                if let windowDidBecomeKeyObserver {
                    NotificationCenter.default.removeObserver(windowDidBecomeKeyObserver)
                    self.windowDidBecomeKeyObserver = nil
                }
                observedWindow = window
                if let window {
                    windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.didBecomeKeyNotification,
                        object: window,
                        queue: .main
                    ) { [weak self, weak textView] _ in
                        guard let self, let textView else { return }
                        self.configureFocus(for: textView)
                    }
                }
            }
            focusIfNeeded(textView)
        }

        private func focusIfNeeded(_ textView: NSTextView) {
            guard !isDismantled, parent.shouldMaintainFocus, let window = textView.window, window.isKeyWindow else { return }
            window.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            if let scrollView = textView.enclosingScrollView {
                updateHeight(scrollView)
            }
        }

        func updateHeight(_ scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            // 强制布局计算以获取最新高度
            layoutManager.ensureLayout(for: textContainer)

            let usedRect = layoutManager.usedRect(for: textContainer)
            // 空文本的已用区域高度为 0，仍需保留稳定的编辑区域以完整显示插入光标。
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: 14))
            let neededHeight = max(usedRect.height, lineHeight, CustomTextEditor.minimumEditorHeight)
            textView.frame.size.height = neededHeight

            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDismantled else { return }
                if self.parent.calculatedHeight != neededHeight {
                    self.parent.calculatedHeight = neededHeight
                }
            }
        }
    }
}
