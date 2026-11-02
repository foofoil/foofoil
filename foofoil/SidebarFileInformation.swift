import AppKit
import AVFoundation
import UniformTypeIdentifiers

extension FoilInformation {
    /// 针对指定文件读取信息，不依赖当前预览，也不包含窗口或历史访问数据。
    @MainActor static func fileDetails(url: URL, displayName: String, archivePath: String? = nil, archiveSize: Int64? = nil) async -> Details {
        let kind: HistoryContentKind
        switch FileListGrouper.classify(url: url) {
        case .listable(.image): kind = .image
        case .listable(.audio), .cueSheets: kind = .audio
        case .listable(.video): kind = .video
        case .other:
            switch url.pathExtension.lowercased() {
            case "pdf": kind = .pdf
            case "md", "markdown": kind = .markdown
            case "csv": kind = .csv
            case "epub": kind = .ebook
            case "html", "htm", "webarchive", "xhtml": kind = .web
            default:
                let ext = url.pathExtension.lowercased()
                let type = UTType(filenameExtension: ext)
                if ArchiveReader.recognizes(url) { kind = .archive }
                else if AppState.textFilenameExtensions.contains(ext) || CodeLanguage.languageID(forFileName: url.lastPathComponent) != nil || type?.conforms(to: .plainText) == true || type?.conforms(to: .sourceCode) == true { kind = .text }
                else { kind = .quickLook }
            }
        }
        let source = archivePath == nil ? url : nil
        var rows = [Row(key: "Foil Info Title", value: displayName),
                    Row(key: "Foil Info Type", value: NSLocalizedString("Foil Info Type \(kind.rawValue)", comment: "")),
                    Row(key: "Foil Info File Path", value: archivePath ?? url.path)]
        let metadata = await fileRows(source: source, contentURL: url, kind: kind)
        rows.append(contentsOf: metadata.rows)
        if let archiveSize {
            rows.append(Row(key: "Foil Info File Size", value: ByteCountFormatter.string(fromByteCount: archiveSize, countStyle: .file)))
        }
        if kind.storesIndexedText {
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000 else { return nil }
                return try? AppState.readTextContent(from: url)
            }.value
            if let text {
                rows.append(Row(key: "Foil Info Characters", value: text.count.formatted()))
                rows.append(Row(key: "Foil Info Lines", value: text.isEmpty ? "0" : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }.formatted()))
            }
        }
        if kind == .audio || kind == .video {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if kind == .audio {
                let config = WindowConfig(id: UUID(), imagePath: url.path, originalImageName: displayName, contentKind: .audio)
                let audio = await details(config: config, state: nil, windowSize: nil)
                let keys: Set<String> = ["Foil Info Track Title", "Foil Info Artist", "Foil Info Album", "Foil Info Album Artist", "Foil Info Composer", "Foil Info Genre", "Foil Info Year", "Foil Info Track Number", "Foil Info Audio Codec", "Foil Info Sample Rate", "Foil Info Bit Depth", "Foil Info Bit Rate", "Foil Info Channels"]
                rows.append(contentsOf: audio.rows.filter { keys.contains($0.key) })
            }
            if let duration = try? await AVURLAsset.media(url: url).load(.duration), duration.seconds.isFinite {
                rows.append(Row(key: "Foil Info Duration", value: Duration.seconds(duration.seconds).formatted(.time(pattern: .hourMinuteSecond))))
            }
        }
        return Details(rows: rows, source: source, available: archivePath == nil && metadata.available)
    }

}
