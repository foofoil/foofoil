//  ShortcutRecorderView.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import AppKit
import SwiftUI

/// 快捷键录制控件：点击后捕获下一个带修饰键的按键组合；按 Delete 清除快捷键。
struct ShortcutRecorderView: NSViewRepresentable {
    var shortcut: KeyboardShortcut?
    var onChange: (KeyboardShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onChange = onChange
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.onChange = onChange
        nsView.shortcut = shortcut
    }
}

/// 用即时本地事件监听覆盖菜单匹配：录制期间按键不会触发菜单命令。
final class ShortcutRecorderButton: NSButton {
    var onChange: ((KeyboardShortcut?) -> Void)?
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
        action = #selector(beginRecording)
        toolTip = NSLocalizedString("Record Shortcut Help", comment: "")
        updateTitle()
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(size.width, 96), height: max(size.height, 22))
    }

    @objc private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        updateTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            return self.handle(event)
        }
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
            guard !shortcut.keyEquivalent.isEmpty, shortcut.hasRequiredModifiers else {
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
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func updateTitle() {
        if isRecording {
            title = NSLocalizedString("Recording Shortcut", comment: "")
        } else if let shortcut {
            title = shortcut.displayString
        } else {
            title = NSLocalizedString("No Shortcut", comment: "")
        }
    }
}
