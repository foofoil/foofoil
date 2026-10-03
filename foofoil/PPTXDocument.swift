import Foundation

nonisolated struct PPTXSlide: Sendable, Equatable {
    let id: String
    let title: String?
}

/// 单窗口独立的后台文档会话；临时预览随会话释放，源文件与历史记录保持原始 URL。
actor PPTXDocument {
    private let archive: PPTXArchive
    private let presentation: Data
    private let directory: URL
    private var previews: [Int: URL] = [:]
    private var cachedBytes: UInt64 = 0
    private var lastPreviewIndex: Int?
    nonisolated let slides: [PPTXSlide]
    nonisolated let slideSize: NSSize

    init(url: URL) throws {
        let archive = try PPTXArchive(url: url)
        let presentation = try archive.data(for: "ppt/presentation.xml")
        let relationships = try Self.parseXML(archive.data(for: "ppt/_rels/presentation.xml.rels"))
        let document = try Self.parseXML(presentation)
        guard document.rootElement()?.localName == "presentation" else { throw PPTXError.unsupportedContent }
        guard let sizeNode = try document.nodes(forXPath: "/*/*[local-name()='sldSz']").first as? XMLElement,
              let width = sizeNode.attribute(forName: "cx")?.stringValue.flatMap(Double.init),
              let height = sizeNode.attribute(forName: "cy")?.stringValue.flatMap(Double.init),
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 1_000_000_000, height <= 1_000_000_000 else { throw PPTXError.invalidArchive }
        // Office 使用 EMU；换算为点后可复用窗口尺寸与等比缩放逻辑。
        self.slideSize = NSSize(width: width / 12_700, height: height / 12_700)
        let ids = try document.nodes(forXPath: "/*/*[local-name()='sldIdLst']/*[local-name()='sldId']")
        guard !ids.isEmpty, ids.count <= 2_000 else { throw PPTXError.limitExceeded }
        var targets: [String: String] = [:]
        for node in try relationships.nodes(forXPath: "/*/*[local-name()='Relationship']") {
            guard let element = node as? XMLElement,
                  element.attribute(forName: "Type")?.stringValue?.hasSuffix("/slide") == true,
                  element.attribute(forName: "TargetMode")?.stringValue != "External",
                  let id = element.attribute(forName: "Id")?.stringValue,
                  let target = element.attribute(forName: "Target")?.stringValue else { continue }
            targets[id] = try Self.slidePath(target)
        }
        var slides: [PPTXSlide] = []
        var totalXMLBytes = 0
        var seen = Set<String>()
        for node in ids {
            try Task.checkCancellation()
            guard let element = node as? XMLElement,
                  let id = element.attributes?.first(where: { $0.localName == "id" && $0.uri != nil })?.stringValue,
                  seen.insert(id).inserted, let path = targets[id] else { throw PPTXError.invalidArchive }
            let data = try archive.data(for: path)
            totalXMLBytes += data.count
            guard totalXMLBytes <= 64 << 20 else { throw PPTXError.limitExceeded }
            slides.append(PPTXSlide(id: id, title: try Self.slideTitle(data)))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-pptx-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.archive = archive
        self.presentation = presentation
        self.directory = directory
        self.slides = slides
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func preview(at index: Int) throws -> URL {
        try Task.checkCancellation()
        guard slides.indices.contains(index) else { throw PPTXError.invalidArchive }
        if let cached = previews[index] {
            lastPreviewIndex = index
            return cached
        }
        let xml = try Self.singleSlidePresentation(presentation, at: index)
        let destination = directory.appendingPathComponent("slide-\(index + 1).pptx")
        do {
            try archive.writePresentation(xml, to: destination)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let size = UInt64((try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        // 缓存预算之外仍保留正在展示的上一页，防止预览服务异步读盘时文件被删除。
        if cachedBytes + size > 256 << 20 {
            let previous = lastPreviewIndex.flatMap { previews[$0] }
            for url in previews.values where url != previous { try? FileManager.default.removeItem(at: url) }
            previews = lastPreviewIndex.flatMap { previousIndex in
                previous.map { [previousIndex: $0] }
            } ?? [:]
            cachedBytes = previous.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(UInt64.init) ?? 0
        }
        previews[index] = destination
        cachedBytes += size
        lastPreviewIndex = index
        return destination
    }

    /// OPC 关系允许相对路径；先在包内规范化，再交给 ZIP 路径校验，绝不映射到外部文件。
    static func slidePath(_ target: String) throws -> String {
        guard let target = target.removingPercentEncoding,
              !target.contains("\\"), !target.contains("\0"), !target.contains(":") else { throw PPTXError.invalidArchive }
        var parts = target.hasPrefix("/") ? [String]() : ["ppt"]
        for component in target.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !parts.isEmpty else { throw PPTXError.invalidArchive }
                parts.removeLast()
            } else {
                parts.append(String(component))
            }
        }
        return try PPTXArchive.validatedPath(parts.joined(separator: "/"))
    }

    static func parseXML(_ data: Data) throws -> XMLDocument {
        guard data.count <= 8 << 20,
              let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw PPTXError.invalidArchive }
        return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }

    static func slideTitle(_ data: Data) throws -> String? {
        let document = try parseXML(data)
        let shapes = try document.nodes(forXPath: "//*[local-name()='sp']")
        for case let shape as XMLElement in shapes {
            guard let properties = children(shape, named: "nvSpPr").first,
                  let nonVisual = children(properties, named: "nvPr").first,
                  let placeholder = children(nonVisual, named: "ph").first,
                  let type = placeholder.attribute(forName: "type")?.stringValue,
                  type == "title" || type == "ctrTitle",
                  let body = children(shape, named: "txBody").first else { continue }
            let title = children(body, named: "p").map { paragraph in
                children(paragraph, named: "r").flatMap { children($0, named: "t") }
                    .compactMap(\.stringValue).joined()
            }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return String(title.prefix(256)) }
        }
        return nil
    }

    private static func children(_ element: XMLElement, named name: String) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }

    static func singleSlidePresentation(_ data: Data, at index: Int) throws -> Data {
        let document = try parseXML(data)
        let nodes = try document.nodes(forXPath: "/*/*[local-name()='sldIdLst']/*[local-name()='sldId']")
        guard nodes.indices.contains(index) else { throw PPTXError.invalidArchive }
        for (offset, node) in nodes.enumerated() where offset != index { node.detach() }
        // 自定义放映与章节可能引用被移除页；单页预览不携带这些放映范围。
        for node in try document.nodes(forXPath: "/*/*[local-name()='custShowLst' or local-name()='showPr' or local-name()='extLst']") {
            node.detach()
        }
        return document.xmlData
    }
}
