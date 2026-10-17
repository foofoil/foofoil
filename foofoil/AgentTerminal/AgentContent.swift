import AppKit
import ImageIO

nonisolated struct AgentFailure: Error {
    let code: String
    init(_ code: String) { self.code = code }
}

nonisolated enum AgentContentKind: String, Sendable { case text, markdown, image, svg }

nonisolated struct AgentPreparedContent: @unchecked Sendable {
    let url: URL
    let kind: AgentContentKind
    let text: String?
    let image: NSImage?
    let warnings: [String]
    var svgData: Data? = nil
}

/// 有界文件读取和解码共用串行后台队列；提交阶段不会重新读取正文。
nonisolated enum AgentContent {
    static let io = DispatchQueue(label: "com.markonce.foofoil.agent.io", qos: .userInitiated)
    // 原文件可能来自阻塞的存储；响应队列必须独立，超时仍能及时返回。
    static let transport = DispatchQueue(label: "com.markonce.foofoil.agent.transport", qos: .userInitiated)

    static func prepare(_ url: URL) throws -> AgentPreparedContent {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AgentFailure("UNSUPPORTED_CONTENT") }
        guard let size = values.fileSize, size <= AgentLimits.fileBytes else { throw AgentFailure("CONTENT_TOO_LARGE") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, AgentLimits.fileBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= AgentLimits.fileBytes else { throw AgentFailure("CONTENT_TOO_LARGE") }
        }
        let ext = url.pathExtension.lowercased()
        if !["html", "htm", "xhtml", "webarchive"].contains(ext),
           AppState.textFilenameExtensions.contains(ext) || CodeLanguage.languageID(forFileName: url.lastPathComponent) != nil {
            guard data.count <= AgentLimits.textBytes else { throw AgentFailure("CONTENT_TOO_LARGE") }
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw AgentFailure("CONTENT_INVALID") }
            let markdown = ext == "md" || ext == "markdown"
            return AgentPreparedContent(url: url, kind: markdown ? .markdown : .text, text: text, image: nil,
                                        warnings: markdown && (text.contains("![") || text.lowercased().contains("<img")) ? ["MARKDOWN_RESOURCES_BLOCKED"] : [])
        }
        if ext == "svg" {
            guard data.count <= AgentLimits.textBytes,
                  let xml = String(data: data, encoding: .utf8),
                  !xml.lowercased().contains("<!doctype"), !xml.lowercased().contains("<!entity") else { throw AgentFailure("CONTENT_INVALID") }
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            let validator = AgentSVGValidator()
            parser.delegate = validator
            guard parser.parse(), validator.isSVG else { throw AgentFailure("CONTENT_INVALID") }
            let size = validator.size
            guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
                  size.width <= Double(AgentLimits.imageDimension), size.height <= Double(AgentLimits.imageDimension),
                  size.width * size.height <= Double(AgentLimits.imagePixels) else { throw AgentFailure("CONTENT_TOO_LARGE") }
            // SVG 只交给既有 WebKit 图片隔离器，不让 NSImage 的原生 SVG 解码阶段接触引用资源。
            let image = NSImage(size: size)
            return AgentPreparedContent(url: url, kind: .svg, text: nil, image: image, warnings: [], svgData: data)
        }
        guard ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"].contains(ext) else { throw AgentFailure("UNSUPPORTED_CONTENT") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { throw AgentFailure("CONTENT_INVALID") }
        guard width <= Double(AgentLimits.imageDimension), height <= Double(AgentLimits.imageDimension),
              width * height <= Double(AgentLimits.imagePixels) else { throw AgentFailure("CONTENT_TOO_LARGE") }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw AgentFailure("CONTENT_INVALID") }
        return AgentPreparedContent(url: url, kind: .image, text: nil,
                                    image: NSImage(cgImage: cg, size: NSSize(width: width, height: height)), warnings: [])
    }
}

nonisolated private final class AgentSVGValidator: NSObject, XMLParserDelegate {
    var isSVG = false
    var size = NSSize(width: 800, height: 600)
    private var sawRoot = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard !sawRoot else { return }
        sawRoot = true
        isSVG = elementName == "svg"
        if let box = attributeDict["viewBox"] {
            let values = box.split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) }
            if values.count == 4 { size = NSSize(width: values[2], height: values[3]) }
        }
        func length(_ value: String?) -> Double? {
            guard let value, !value.contains("%") else { return nil }
            return Double(value.prefix { $0.isNumber || ".+-eE".contains($0) })
        }
        if let width = length(attributeDict["width"]) { size.width = width }
        if let height = length(attributeDict["height"]) { size.height = height }
    }
}

extension AppState {
    /// 身份和归属只存在于本次运行；不进入 WindowConfig。人工替换后安全策略随正文保留到下一次替换。
    func relinquishAgentControl(keepingPresentation: Bool = false) {
        agentOwnership = nil
        if keepingPresentation { return }
        agentReadOnly = false
        agentKind = nil
        agentSVGData = nil
    }

    func commitAgentContent(_ prepared: AgentPreparedContent, title: String?, initial: Bool) {
        isBatchUpdating = true
        let sameKind = agentKind == prepared.kind
        agentReadOnly = true
        agentKind = prepared.kind
        agentSVGData = prepared.svgData
        if initial { showBorder = prepared.text != nil }
        saveTask?.cancel()
        if !sameKind {
            imageScale = 1
            textFontSize = Self.defaultTextFontSize
            documentZoom = 1
            markdownScrollRequest = nil
        }
        originalImageName = prepared.url.lastPathComponent
        if let title { customTitle = title }
        sourceFingerprint = Self.localSourceFingerprint(for: prepared.url)
        // 沿用当前内容身份更新历史，不逐次建立历史版本。
        if prepared.text != nil {
            imageURL = nil
            textURL = prepared.url
            isMarkdownPreview = prepared.kind == .markdown
            text = prepared.text ?? ""
        } else {
            textURL = nil
            text = ""
            isMarkdownPreview = false
            imageURL = prepared.url
            if let image = prepared.image { loadedImageCache = (prepared.url, image) }
        }
        retainFileAccess(to: prepared.url)
        if initial { createdAt = Date(); applyDefaultDocumentThemeIfNeeded() }
        agentContentRevision &+= 1
        isBatchUpdating = false
        saveState()
    }
}
