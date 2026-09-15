//  KeyboardShortcut.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import AppKit
import Carbon.HIToolbox

/// 用户可配置的快捷键：菜单键字符 + 修饰键。
/// 以稳定标识持久化单个按键，键字符统一小写存储，Shift 通过修饰键位表达。
nonisolated struct KeyboardShortcut: Codable, Equatable, Hashable {
    var keyEquivalent: String
    var modifierFlags: UInt

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    init(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) {
        self.keyEquivalent = Self.normalizedKeyEquivalent(keyEquivalent)
        self.modifierFlags = modifiers.intersection([.command, .control, .option, .shift]).rawValue
    }

    /// 单字母统一小写；AppKit 用修饰键位表达 Shift，而非大写字符。
    static func normalizedKeyEquivalent(_ value: String) -> String {
        guard value.count == 1, let scalar = value.unicodeScalars.first,
              scalar.value >= 65, scalar.value <= 90 else {
            return value
        }
        return String(UnicodeScalar(scalar.value + 32)!)
    }

    /// 是否包含菜单快捷键必需的修饰键；无修饰键会吞掉普通输入。
    var hasRequiredModifiers: Bool {
        let flags = modifiers
        return flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
    }

    /// 展示用文本，如 ⌃⌥Q、⇧⌘←。
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        text += Self.keyDisplay(for: keyEquivalent)
        return text
    }

    /// Carbon 全局热键需要的虚拟键码；不支持的特殊键返回 nil。
    var carbonKeyCode: UInt32? {
        KeyboardShortcutKeyCode.carbonKeyCode(for: keyEquivalent)
    }

    /// Carbon 全局热键需要的修饰键位。
    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    private static func keyDisplay(for keyEquivalent: String) -> String {
        guard keyEquivalent.unicodeScalars.count == 1,
              let scalar = keyEquivalent.unicodeScalars.first else {
            return keyEquivalent.uppercased()
        }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSHomeFunctionKey: return "↖"
        case NSEndFunctionKey: return "↘"
        case NSPageUpFunctionKey: return "⇞"
        case NSPageDownFunctionKey: return "⇟"
        case NSDeleteFunctionKey: return "⌦"
        case 0x09: return "⇥"
        case 0x0D: return "↩"
        case 0x1B: return "⎋"
        case 0x20: return "␣"
        case 0x7F: return "⌫"
        case NSF1FunctionKey: return "F1"
        case NSF2FunctionKey: return "F2"
        case NSF3FunctionKey: return "F3"
        case NSF4FunctionKey: return "F4"
        case NSF5FunctionKey: return "F5"
        case NSF6FunctionKey: return "F6"
        case NSF7FunctionKey: return "F7"
        case NSF8FunctionKey: return "F8"
        case NSF9FunctionKey: return "F9"
        case NSF10FunctionKey: return "F10"
        case NSF11FunctionKey: return "F11"
        case NSF12FunctionKey: return "F12"
        default: return String(scalar).uppercased()
        }
    }
}

/// 键字符到 Carbon 虚拟键码的映射；仅覆盖窗口快捷键可能用到的按键。
nonisolated enum KeyboardShortcutKeyCode {
    static func carbonKeyCode(for keyEquivalent: String) -> UInt32? {
        guard keyEquivalent.unicodeScalars.count == 1 else {
            return nil
        }
        switch keyEquivalent {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        case "0": return UInt32(kVK_ANSI_0)
        case "1": return UInt32(kVK_ANSI_1)
        case "2": return UInt32(kVK_ANSI_2)
        case "3": return UInt32(kVK_ANSI_3)
        case "4": return UInt32(kVK_ANSI_4)
        case "5": return UInt32(kVK_ANSI_5)
        case "6": return UInt32(kVK_ANSI_6)
        case "7": return UInt32(kVK_ANSI_7)
        case "8": return UInt32(kVK_ANSI_8)
        case "9": return UInt32(kVK_ANSI_9)
        case "-": return UInt32(kVK_ANSI_Minus)
        case "=": return UInt32(kVK_ANSI_Equal)
        case "[": return UInt32(kVK_ANSI_LeftBracket)
        case "]": return UInt32(kVK_ANSI_RightBracket)
        case ";": return UInt32(kVK_ANSI_Semicolon)
        case "'": return UInt32(kVK_ANSI_Quote)
        case "\\": return UInt32(kVK_ANSI_Backslash)
        case ",": return UInt32(kVK_ANSI_Comma)
        case ".": return UInt32(kVK_ANSI_Period)
        case "/": return UInt32(kVK_ANSI_Slash)
        case "`": return UInt32(kVK_ANSI_Grave)
        case "\t": return UInt32(kVK_Tab)
        case "\r": return UInt32(kVK_Return)
        case " ": return UInt32(kVK_Space)
        case "\u{1b}": return UInt32(kVK_Escape)
        case "\u{7f}": return UInt32(kVK_Delete)
        case "\u{F700}": return UInt32(kVK_UpArrow)
        case "\u{F701}": return UInt32(kVK_DownArrow)
        case "\u{F702}": return UInt32(kVK_LeftArrow)
        case "\u{F703}": return UInt32(kVK_RightArrow)
        case "\u{F729}": return UInt32(kVK_Home)
        case "\u{F72B}": return UInt32(kVK_End)
        case "\u{F72C}": return UInt32(kVK_PageUp)
        case "\u{F72D}": return UInt32(kVK_PageDown)
        case "\u{F728}": return UInt32(kVK_ForwardDelete)
        case "\u{F704}": return UInt32(kVK_F1)
        case "\u{F705}": return UInt32(kVK_F2)
        case "\u{F706}": return UInt32(kVK_F3)
        case "\u{F707}": return UInt32(kVK_F4)
        case "\u{F708}": return UInt32(kVK_F5)
        case "\u{F709}": return UInt32(kVK_F6)
        case "\u{F70A}": return UInt32(kVK_F7)
        case "\u{F70B}": return UInt32(kVK_F8)
        case "\u{F70C}": return UInt32(kVK_F9)
        case "\u{F70D}": return UInt32(kVK_F10)
        case "\u{F70E}": return UInt32(kVK_F11)
        case "\u{F70F}": return UInt32(kVK_F12)
        default: return nil
        }
    }
}
