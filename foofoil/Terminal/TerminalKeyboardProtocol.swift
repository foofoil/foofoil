import AppKit

/// SwiftTerm 暂未处理 Kitty 键盘协商；这里只实现按键消歧（flag 1），不宣称支持其他增强。
struct TerminalKeyboardProtocol {
    enum Output { case display([UInt8]), reply(String) }
    private enum State { case ground, escape, csi, csiPassthrough, string, stringEscape }
    private var state: State = .ground
    private var pending: [UInt8] = []
    private var isOSC = false
    private var alternate = false
    private var normalModes = [0]
    private var alternateModes = [0]
    private var modes: [Int] {
        get { alternate ? alternateModes : normalModes }
        set { if alternate { alternateModes = newValue } else { normalModes = newValue } }
    }
    var flags: Int { modes.last ?? 0 }

    /// 在 PTY 分片之间保存解析状态，不把 OSC/DCS/APC 字符串里的示例文本当作协商命令。
    mutating func receive(_ bytes: ArraySlice<UInt8>) -> [Output] {
        var result: [Output] = []
        var display: [UInt8] = []
        for byte in bytes {
            switch state {
            case .ground:
                if byte == 0x1b { pending = [byte]; state = .escape }
                else { display.append(byte) }
            case .escape:
                if byte == 0x1b { display += pending; pending = [byte]; continue }
                pending.append(byte)
                if byte == 0x5b { state = .csi; continue }
                if [0x5d, 0x50, 0x58, 0x5e, 0x5f].contains(byte) {
                    isOSC = byte == 0x5d
                    state = .string
                } else {
                    if byte == 0x63 { normalModes = [0]; alternateModes = [0]; alternate = false }
                    state = .ground
                }
                display += pending; pending.removeAll(keepingCapacity: true)
            case .csi:
                if byte == 0x1b {
                    display += pending; pending = [byte]; state = .escape; continue
                }
                pending.append(byte)
                if (0x40...0x7e).contains(byte) {
                    let sequence = pending
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                    let handled = handle(sequence)
                    if !handled.consumed { display += sequence }
                    if let reply = handled.reply {
                        if !display.isEmpty { result.append(.display(display)); display.removeAll(keepingCapacity: true) }
                        result.append(.reply(reply))
                    }
                } else if byte == 0x18 || byte == 0x1a {
                    display += pending; pending.removeAll(keepingCapacity: true); state = .ground
                } else if pending.count >= 128 {
                    // 超长或恶意控制序列原样交还引擎，不无限积累内存。
                    display += pending; pending.removeAll(keepingCapacity: true); state = .csiPassthrough
                }
            case .csiPassthrough:
                if byte == 0x1b { pending = [byte]; state = .escape }
                else {
                    display.append(byte)
                    if (0x40...0x7e).contains(byte) || byte == 0x18 || byte == 0x1a { state = .ground }
                }
            case .string:
                display.append(byte)
                if byte == 0x1b { state = .stringEscape }
                else if (isOSC && byte == 7) || byte == 0x18 || byte == 0x1a { state = .ground }
            case .stringEscape:
                display.append(byte)
                if byte == 0x5c || byte == 0x18 || byte == 0x1a || (isOSC && byte == 7) { state = .ground }
                else if byte != 0x1b { state = .string }
            }
        }
        if !display.isEmpty { result.append(.display(display)) }
        return result
    }

    private mutating func handle(_ bytes: [UInt8]) -> (consumed: Bool, reply: String?) {
        let body = String(decoding: bytes.dropFirst(2).dropLast(), as: UTF8.self)
        let final = bytes.last
        if final == 0x68 || final == 0x6c, body.hasPrefix("?") {
            let parameters = body.dropFirst().split(separator: ";")
            if parameters.contains(where: { ["47", "1047", "1049"].contains(String($0)) }) {
                alternate = final == 0x68
            }
            return (false, nil)
        }
        guard final == 0x75, let prefix = body.first, "?><=".contains(prefix) else { return (false, nil) }
        if body == "?" { return (true, "\u{1b}[?\(flags)u") }
        let fields = body.dropFirst().split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count <= 2, fields.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return (false, nil) }
        let raw = fields.first.map(String.init) ?? ""
        guard let value = raw.isEmpty ? (prefix == "<" ? 1 : 0) : Int(raw) else { return (false, nil) }
        switch prefix {
        case ">" where fields.count == 1:
            var stack = modes
            if stack.count == 32 { stack.removeFirst() }
            stack.append(value & 1); modes = stack
        case "<" where fields.count == 1:
            var stack = modes
            stack.removeLast(min(max(1, value), stack.count))
            modes = stack.isEmpty ? [0] : stack
        case "=":
            let modeText = fields.count == 2 ? String(fields[1]) : ""
            guard let mode = modeText.isEmpty ? 1 : Int(modeText), (1...3).contains(mode) else { return (false, nil) }
            var stack = modes
            switch mode {
            case 1: stack[stack.count - 1] = value & 1
            case 2: stack[stack.count - 1] |= value & 1
            default: stack[stack.count - 1] &= ~(value & 1)
            }
            modes = stack
        default: return (false, nil)
        }
        return (true, nil)
    }

    /// nil 表示继续使用 SwiftTerm / 输入法；普通文本不绕过 NSTextInputClient。
    func encoding(for event: NSEvent, optionAsMetaKey: Bool = false) -> String? {
        guard flags & 1 != 0, event.type == .keyDown, !event.modifierFlags.contains(.command) else { return nil }
        let modifiers = event.modifierFlags.intersection([.shift, .option, .control])
        let modifier = 1 + (modifiers.contains(.shift) ? 1 : 0)
            + (modifiers.contains(.option) ? 2 : 0) + (modifiers.contains(.control) ? 4 : 0)
        let suffix = modifier == 1 ? "" : ";\(modifier)"
        func unicode(_ code: UInt32) -> String { "\u{1b}[\(code)\(suffix)u" }
        // Return/Tab/Backspace 的无修饰版本仍保留传统字节，允许异常退出后输入 reset。
        switch event.keyCode {
        case 53: return unicode(27)
        case 36: return modifiers.isEmpty ? "\r" : unicode(13)
        case 48: return modifiers.isEmpty ? "\t" : unicode(9)
        case 51: return modifiers.isEmpty ? "\u{7f}" : unicode(127)
        default: break
        }
        let functional: [UInt16: String] = [
            123: "D", 124: "C", 125: "B", 126: "A", 115: "H", 119: "F",
            122: "P", 120: "Q", 118: "S"
        ]
        if let final = functional[event.keyCode] { return "\u{1b}[\(modifier == 1 ? "" : "1;\(modifier)")\(final)" }
        let tilde: [UInt16: Int] = [114: 2, 117: 3, 116: 5, 121: 6, 99: 13,
            96: 15, 97: 17, 98: 18, 100: 19, 101: 20, 109: 21, 103: 23, 111: 24]
        if let number = tilde[event.keyCode] { return "\u{1b}[\(number)\(suffix)~" }
        // 键盘区的 Enter 和非文本数字键盘键使用独立编码。
        if event.keyCode == 76 { return unicode(57414) }
        if let code: UInt32 = [65: 57409, 67: 57411, 69: 57413, 75: 57410, 78: 57412, 81: 57415][event.keyCode] {
            return unicode(code)
        }
        guard modifiers.contains(.control) || (optionAsMetaKey && modifiers.contains(.option)),
              let characters = event.characters(byApplyingModifiers: []), characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first, scalar.value >= 32, scalar.value < 0xf700 else { return nil }
        return unicode(scalar.value)
    }

}
