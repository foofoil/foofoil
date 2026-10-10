//  ShortcutRecorderView.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import AppKit
import SwiftUI

/// 快捷键录制控件：点击后捕获下一个按键组合（不强制带修饰键）；按 Delete 清除快捷键。
struct ShortcutRecorderView: NSViewRepresentable {
    var shortcut: KeyboardShortcut?
    /// 快捷键为空时的占位标题（搜索等场景）；nil 时沿用“无快捷键”。
    var promptTitle: String? = nil
    /// 自定义悬停提示；nil 时使用录制帮助文本。
    var helpText: String? = nil
    /// 搜索模式：录制结束后，Esc 或 Backspace 可清除已录键位（按钮持有焦点时生效）。
    var cancelClearsShortcut: Bool = false
    /// 图标模式（搜索）：按钮只显示图标。空闲时显示该图标；录制中或已有键位时显示取消/清除叉号。
    var idleSymbolName: String? = nil
    /// 录制开始或结束时回调，外层据此切换左侧的录制提示。
    var onRecordingChange: ((Bool) -> Void)? = nil
    var onChange: (KeyboardShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.promptTitle = promptTitle
        button.cancelClearsShortcut = cancelClearsShortcut
        button.idleSymbolName = idleSymbolName
        if let helpText { button.toolTip = helpText }
        button.onChange = onChange
        button.onRecordingChange = onRecordingChange
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.promptTitle = promptTitle
        nsView.cancelClearsShortcut = cancelClearsShortcut
        nsView.idleSymbolName = idleSymbolName
        nsView.onChange = onChange
        nsView.onRecordingChange = onRecordingChange
        nsView.shortcut = shortcut
    }
}

/// 用即时本地事件监听覆盖菜单匹配：录制期间按键不会触发菜单命令。
final class ShortcutRecorderButton: NSButton {
    var onChange: ((KeyboardShortcut?) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var promptTitle: String? {
        didSet { updateTitle() }
    }
    /// 搜索模式下，录制结束后 Esc/Backspace 清除已录键位。
    var cancelClearsShortcut = false
    /// 图标模式：空闲时显示的 SF Symbol；非 nil 时按钮只显示图标。
    var idleSymbolName: String? {
        didSet { updateTitle() }
    }
    var shortcut: KeyboardShortcut? {
        didSet { updateTitle() }
    }

    private var isRecording = false
    private var monitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    /// 视图移出窗口（如切换设置页）时结束录制，避免遗留事件监听。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            endRecording()
        }
    }

    private func configure() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(handleClick)
        toolTip = NSLocalizedString("Record Shortcut Help", comment: "")
        updateTitle()
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        // 图标模式下按钮只保留图标宽度，不再撑到文字录制按钮的最小宽度。
        let minWidth: CGFloat = idleSymbolName == nil ? 96 : 30
        return NSSize(width: max(size.width, minWidth), height: max(size.height, 22))
    }

    /// 图标模式：录制中点击为取消，已有键位时点击为清除，空闲时开始录制。
    @objc private func handleClick() {
        if isRecording {
            endRecording()
            return
        }
        if idleSymbolName != nil, shortcut != nil {
            shortcut = nil
            onChange?(nil)
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        updateTitle()
        notifyRecordingChange()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handle(event)
        }
    }

    /// 录制期间的事件由本地监听吞掉；这里处理的是录制结束、按钮仍持有焦点时的按键。
    override func keyDown(with event: NSEvent) {
        if cancelClearsShortcut, shortcut != nil, event.keyCode == 53 || event.keyCode == 51 {
            shortcut = nil
            onChange?(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// 返回 nil 表示吞掉事件；录制期间不允许普通按键触发菜单或控件。
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            // 点击控件外部视为取消，并把点击继续传给目标控件。
            if !bounds.contains(convert(event.locationInWindow, from: nil)) {
                endRecording()
                return event
            }
            // 图标模式下，录制中点击按钮即为取消（点击被吞掉，不会再触发 action）。
            if idleSymbolName != nil {
                endRecording()
            }
            return nil
        case .flagsChanged:
            return nil
        case .keyDown:
            if event.keyCode == 53 { // Esc 取消录制
                endRecording()
                return nil
            }
            if event.keyCode == 51 { // Delete 清除快捷键
                self.shortcut = nil
                onChange?(nil)
                endRecording()
                return nil
            }
            let shortcut = KeyboardShortcut(
                keyEquivalent: event.charactersIgnoringModifiers ?? "",
                modifiers: event.modifierFlags
            )
            // 不强制带修饰键：允许录制裸键（如方向键、空格、字母）。
            guard !shortcut.keyEquivalent.isEmpty else {
                NSSound.beep()
                return nil
            }
            self.shortcut = shortcut
            onChange?(shortcut)
            endRecording()
            return nil
        default:
            return event
        }
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        removeMonitor()
        updateTitle()
        notifyRecordingChange()
    }

    /// 异步回调，避免在 SwiftUI 视图更新过程中修改外层状态。
    private func notifyRecordingChange() {
        let recording = isRecording
        DispatchQueue.main.async { [weak self] in
            self?.onRecordingChange?(recording)
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func updateTitle() {
        image = nil
        imagePosition = .noImage
        setAccessibilityLabel(nil)
        if let idleSymbolName {
            if isRecording {
                showSymbol("xmark.circle.fill", label: NSLocalizedString("Cancel Shortcut Recording", comment: ""))
            } else if shortcut != nil {
                showSymbol("xmark.circle.fill", label: NSLocalizedString("Clear Shortcut Search", comment: ""))
            } else {
                showSymbol(idleSymbolName, label: promptTitle)
            }
        } else if isRecording {
            title = NSLocalizedString("Recording Shortcut", comment: "")
        } else if let shortcut {
            title = shortcut.displayString
        } else {
            title = promptTitle ?? NSLocalizedString("No Shortcut", comment: "")
        }
    }

    private func showSymbol(_ name: String, label: String?) {
        title = ""
        image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        imagePosition = .imageOnly
        setAccessibilityLabel(label)
    }
}
