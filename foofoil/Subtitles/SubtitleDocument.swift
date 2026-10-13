import Foundation
import CoreFoundation

struct SubtitleCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}
struct SubtitleDocument: Sendable {
    let cues: [SubtitleCue]
    private let maximumEnds: [Double]
    nonisolated init(cues: [SubtitleCue]) {
        self.cues = cues
        var end = 0.0
        maximumEnds = cues.map { end = max(end, $0.end); return end }
    }
    func text(at time: Double) -> String {
        // 先按起点二分，再按前缀最大终点回溯；重叠字幕不会被漏掉，也无需逐帧扫全片。
        var lower = 0, upper = cues.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cues[middle].start <= time { lower = middle + 1 } else { upper = middle }
        }
        var index = lower - 1
        var texts: [String] = []
        while index >= 0, maximumEnds[index] > time {
            if cues[index].end > time { texts.append(cues[index].text) }
            index -= 1
        }
        return texts.reversed().joined(separator: "\n")
    }
    static let extensions = ["srt", "ass", "ssa", "vtt"]
    nonisolated static func parse(_ data: Data, extension ext: String) throws -> SubtitleDocument {
        guard data.count <= 16 * 1024 * 1024 else { throw SubtitleError.tooLarge }
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) else { throw SubtitleError.invalidEncoding }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        var result: [SubtitleCue] = []
        if ["ass", "ssa"].contains(ext.lowercased()) {
            var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
            var inEvents = false
            for line in text.components(separatedBy: "\n") {
                if line.hasPrefix("[") { inEvents = line.lowercased().hasPrefix("[events]") }
                if inEvents && line.lowercased().hasPrefix("format:") {
                    fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                }
                guard line.lowercased().hasPrefix("dialogue:"), let startIndex = fields.firstIndex(of: "start"), let endIndex = fields.firstIndex(of: "end"), let textIndex = fields.firstIndex(of: "text") else { continue }
                let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
                guard values.count == fields.count, let start = timestamp(values[startIndex]), let end = timestamp(values[endIndex]), end > start else { continue }
                let body = clean(values[textIndex], ass: true)
                if !body.isEmpty { result.append(.init(start: start, end: end, text: body)) }
            }
        } else {
            let lines = text.components(separatedBy: "\n")
            var index = 0
            while index < lines.count {
                let line = lines[index]; index += 1
                guard line.contains("-->"), !line.hasPrefix("NOTE") else { continue }
                let values = line.components(separatedBy: "-->")
                guard values.count == 2, let start = timestamp(values[0]), let end = timestamp(values[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]), end > start else { continue }
                var body: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { body.append(lines[index]); index += 1 }
                let value = clean(body.joined(separator: "\n"), ass: false)
                if !value.isEmpty { result.append(.init(start: start, end: end, text: value)) }
            }
        }
        guard !result.isEmpty else { throw SubtitleError.empty }
        return .init(cues: result.sorted { $0.start < $1.start })
    }
    nonisolated static func timestamp(_ raw: String) -> Double? {
        let rawParts = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        let parts = rawParts.compactMap { Double($0) }
        guard parts.count == rawParts.count else { return nil }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
    nonisolated static func clean(_ text: String, ass: Bool) -> String {
        var result = text
        if ass {
            // ASS 绘图指令不作为文字显示；排版样式由宿主全局样式取代。
            if text.range(of: #"\{[^}]*\\p[1-9]"#, options: .regularExpression) != nil { return "" }
            result = result.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
        } else {
            result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
enum SubtitleError: LocalizedError {
    case tooLarge, invalidEncoding, empty
    var errorDescription: String? {
        let key = switch self { case .tooLarge: "Subtitle File Too Large"; case .invalidEncoding: "Subtitle Encoding Unsupported"; case .empty: "Subtitle File Has No Cues" }
        return NSLocalizedString(key, comment: "")
    }
}
