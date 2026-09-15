//  KeyboardShortcut+SwiftUI.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import AppKit
import SwiftUI

extension KeyboardShortcut {
    /// 转换为 SwiftUI 的 `.keyboardShortcut` 参数；仅用于让右键菜单渲染出当前键位提示。
    var swiftUIKeyEquivalent: KeyEquivalent {
        guard let scalar = keyEquivalent.unicodeScalars.first else { return KeyEquivalent(" ") }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return .upArrow
        case NSDownArrowFunctionKey: return .downArrow
        case NSLeftArrowFunctionKey: return .leftArrow
        case NSRightArrowFunctionKey: return .rightArrow
        case NSHomeFunctionKey: return .home
        case NSEndFunctionKey: return .end
        case NSPageUpFunctionKey: return .pageUp
        case NSPageDownFunctionKey: return .pageDown
        case 0x09: return .tab
        case 0x0D: return .return
        case 0x1B: return .escape
        case 0x20: return .space
        case 0x7F: return .delete
        default:
            return KeyEquivalent(Character(scalar))
        }
    }

    var swiftUIEventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if self.modifiers.contains(.command) { modifiers.insert(.command) }
        if self.modifiers.contains(.option) { modifiers.insert(.option) }
        if self.modifiers.contains(.control) { modifiers.insert(.control) }
        if self.modifiers.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

extension View {
    /// 有快捷键时才附加 `.keyboardShortcut`，用于让右键菜单渲染当前键位提示。
    @ViewBuilder
    func optionalKeyboardShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        if let shortcut {
            keyboardShortcut(shortcut.swiftUIKeyEquivalent, modifiers: shortcut.swiftUIEventModifiers)
        } else {
            self
        }
    }
}
