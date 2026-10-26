import AppKit
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct TerminalKeyboardProtocolTests {
    private func receive(_ text: String, into protocolState: inout TerminalKeyboardProtocol) -> (display: String, replies: [String]) {
        var display = ""
        var replies: [String] = []
        for action in protocolState.receive(Array(text.utf8)[...]) {
            switch action {
            case .display(let bytes): display += String(decoding: bytes, as: UTF8.self)
            case .reply(let reply): replies.append(reply)
            }
        }
        return (display, replies)
    }

    private func event(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    @Test func negotiationIsOptInAndOnlyReportsSupportedFlags() throws {
        var keyboard = TerminalKeyboardProtocol()
        let controlM = try event("m", code: 46, modifiers: .control)
        #expect(keyboard.encoding(for: controlM) == nil)
        #expect(receive("\u{1b}[?u", into: &keyboard).replies == ["\u{1b}[?0u"])
        #expect(receive("\u{1b}[>31u\u{1b}[?u", into: &keyboard).replies == ["\u{1b}[?1u"])
        #expect(keyboard.encoding(for: controlM) == "\u{1b}[109;5u")
        #expect(keyboard.encoding(for: try event("\r", code: 36)) == "\r")
        #expect(keyboard.encoding(for: try event("i", code: 34, modifiers: .control)) == "\u{1b}[105;5u")
        #expect(keyboard.encoding(for: try event("\t", code: 48)) == "\t")
        #expect(keyboard.encoding(for: try event("x", code: 7, modifiers: .control)) == "\u{1b}[120;5u")
        #expect(keyboard.encoding(for: try event("m", code: 46)) == nil)
        #expect(keyboard.encoding(for: try event("c", code: 8, modifiers: .command)) == nil)
        #expect(keyboard.encoding(for: try event("e", code: 14, modifiers: .option)) == nil)
        #expect(keyboard.encoding(for: try event("e", code: 14, modifiers: .option), optionAsMetaKey: true) == "\u{1b}[101;3u")
        #expect(keyboard.encoding(for: try event("M", code: 46, modifiers: [.control, .shift])) == "\u{1b}[109;6u")
        _ = receive("\u{1b}[<u", into: &keyboard)
        #expect(keyboard.encoding(for: controlM) == nil)
    }

    @Test func nestedModesAndScreensRestoreIndependently() {
        var keyboard = TerminalKeyboardProtocol()
        _ = receive("\u{1b}[>1u\u{1b}[>0u", into: &keyboard)
        #expect(keyboard.flags == 0)
        _ = receive("\u{1b}[<u", into: &keyboard)
        #expect(keyboard.flags == 1)
        #expect(receive("\u{1b}[?1049h", into: &keyboard).display == "\u{1b}[?1049h")
        #expect(keyboard.flags == 0)
        _ = receive("\u{1b}[>1u\u{1b}[?1049l", into: &keyboard)
        #expect(keyboard.flags == 1)
        _ = receive("\u{1b}[<99u", into: &keyboard)
        #expect(keyboard.flags == 0)
        _ = receive("\u{1b}[?1049h", into: &keyboard)
        #expect(keyboard.flags == 1)
        _ = receive("\u{1b}c", into: &keyboard)
        #expect(keyboard.flags == 0)
    }

    @Test func modeUpdatesIgnoreUnsupportedEnhancementsAndBoundStack() {
        var keyboard = TerminalKeyboardProtocol()
        _ = receive("\u{1b}[=31u", into: &keyboard)
        #expect(keyboard.flags == 1)
        _ = receive("\u{1b}[=1;3u", into: &keyboard)
        #expect(keyboard.flags == 0)
        _ = receive("\u{1b}[=1;2u", into: &keyboard)
        #expect(keyboard.flags == 1)
        _ = receive(String(repeating: "\u{1b}[>1u", count: 100), into: &keyboard)
        _ = receive("\u{1b}[<32u", into: &keyboard)
        #expect(keyboard.flags == 0)
        #expect(receive("\u{1b}[=1;99u", into: &keyboard).display == "\u{1b}[=1;99u")
    }

    @Test func arbitraryPTYChunksPreserveOutputAndResponseOrder() {
        let stream = "中文\u{1b}[31mred\u{1b}[0m\u{1b}[>1u\u{1b}[?u\u{1b}[<u\u{1b}[?u\u{1b}[u"
        let bytes = Array(stream.utf8)
        for size in 1...bytes.count {
            var keyboard = TerminalKeyboardProtocol()
            var display: [UInt8] = []
            var replies: [String] = []
            for start in stride(from: 0, to: bytes.count, by: size) {
                for action in keyboard.receive(bytes[start..<min(bytes.count, start + size)]) {
                    switch action {
                    case .display(let data): display += data
                    case .reply(let data): replies.append(data)
                    }
                }
            }
            #expect(String(decoding: display, as: UTF8.self) == "中文\u{1b}[31mred\u{1b}[0m\u{1b}[u")
            #expect(replies == ["\u{1b}[?1u", "\u{1b}[?0u"])
            #expect(keyboard.flags == 0)
        }
        var keyboard = TerminalKeyboardProtocol()
        let actions = keyboard.receive(Array("before\u{1b}[?u\u{1b}[c".utf8)[...])
        #expect(actions.count == 3)
        if case .display(let data) = actions[0] { #expect(String(decoding: data, as: UTF8.self) == "before") }
        else { Issue.record("Output before the query was reordered") }
        if case .reply(let data) = actions[1] { #expect(data == "\u{1b}[?0u") }
        else { Issue.record("Query response was reordered") }
    }

    @Test func stringsAndMalformedSequencesDoNotNegotiate() {
        let examples = ["\u{1b}]0;title\u{1b}[>1u\u{7}", "\u{1b}Pdata\u{1b}[>1u\u{1b}\\",
            "\u{1b}_image\u{1b}[>1u\u{1b}\\", "\u{1b}[>99999999999999999999999999999u",
            "\u{1b}[>1:1u", "\u{1b}[>1\u{18}u", "\u{1b}[>" + String(repeating: "1", count: 256) + "u"]
        for example in examples {
            var keyboard = TerminalKeyboardProtocol()
            var output: [UInt8] = []
            for byte in example.utf8 {
                for action in keyboard.receive([byte][...]) {
                    if case .display(let data) = action { output += data }
                    else { Issue.record("String or malformed sequence triggered a reply") }
                }
            }
            #expect(output == Array(example.utf8))
            #expect(keyboard.flags == 0)
        }
    }

    @Test func functionalKeysRemainUsable() throws {
        var keyboard = TerminalKeyboardProtocol()
        _ = receive("\u{1b}[>1u", into: &keyboard)
        #expect(keyboard.encoding(for: try event("", code: 53)) == "\u{1b}[27u")
        #expect(keyboard.encoding(for: try event("", code: 123, modifiers: .control)) == "\u{1b}[1;5D")
        #expect(keyboard.encoding(for: try event("", code: 126)) == "\u{1b}[A")
        #expect(keyboard.encoding(for: try event("", code: 99)) == "\u{1b}[13~")
        #expect(keyboard.encoding(for: try event("", code: 48, modifiers: .shift)) == "\u{1b}[9;2u")
        #expect(keyboard.encoding(for: try event("", code: 51)) == "\u{7f}")
        #expect(keyboard.encoding(for: try event("", code: 76)) == "\u{1b}[57414u")
    }
}
