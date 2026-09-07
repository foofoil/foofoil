import Foundation
import UniformTypeIdentifiers

nonisolated public enum HistoryContentKind: Int, Codable, Sendable {
    case note = 0
    case text = 1
    case markdown = 2
    case csv = 3
    case image = 4
    case web = 5
    case pdf = 6
    case video = 7
    case audio = 8
    case extensionContent = 9

    public var symbolName: String {
        switch self {
        case .web: return "globe"
        case .image: return "photo"
        case .pdf: return "text.document"
        case .video: return "play.rectangle"
        case .audio: return "music.note"
        case .markdown: return "arrow.down.document"
        case .csv: return "tablecells"
        case .extensionContent: return "puzzlepiece.extension"
        case .note, .text: return "note.text"
        }
    }

    public static func infer(from config: WindowConfig) -> Self {
        // 宿主统一音频列表（含经扩展播放的 DSF/DFF/SACD）按列表类型归类，
        // 否则扩展音频会因 imagePath 为空而误判为笔记。
        if config.fileList?.isPresentable == true, config.fileList?.kind == .audio { return .audio }
        if config.extensionID != nil { return .extensionContent }
        if config.webURLString != nil { return .web }
        let name = (config.originalImageName ?? config.textPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "").lowercased()
        if name.hasSuffix(".pdf") { return .pdf }
        if config.imagePath != nil {
            let ext = URL(fileURLWithPath: name).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                if type.conforms(to: .movie) { return .video }
                if type.conforms(to: .audio) { return .audio }
            }
            return .image
        }
        if name.hasSuffix(".md") || name.hasSuffix(".markdown") { return .markdown }
        if name.hasSuffix(".csv") { return .csv }
        if config.textPath != nil { return .text }
        return .note
    }
}
