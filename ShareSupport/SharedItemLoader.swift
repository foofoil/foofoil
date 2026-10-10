import AppKit
import UniformTypeIdentifiers

/// 两个目标共用附件解码规则，保持类型优先级与可测试的传输行为一致。
nonisolated enum SharedItemLoader {
    static func load(_ provider: NSItemProvider) async throws -> URL {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try await loadItem(provider, type: UTType.fileURL.identifier)
            guard let url = decodeURL(item), url.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
            return url
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try await loadItem(provider, type: UTType.url.identifier)
            let url = decodeURL(item)
            guard let url else { throw CocoaError(.fileReadCorruptFile) }
            if url.isFileURL { return url }
            guard let link = SharedContentLink.website(url).url else { throw CocoaError(.fileReadUnsupportedScheme) }
            return link
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let item = try await loadItem(provider, type: UTType.plainText.identifier)
            let text = (item as? String) ?? (item as? NSAttributedString)?.string
                ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            guard let text, let link = SharedContentLink.text(text).url else { throw CocoaError(.fileReadCorruptFile) }
            return link
        }
        guard let type = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .data) || type.conforms(to: .directory)
        }) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                do {
                    let ext = url.pathExtension.isEmpty ? UTType(type)?.preferredFilenameExtension : url.pathExtension
                    let proposedName = name.map { value in
                        URL(fileURLWithPath: value).pathExtension.isEmpty && ext != nil ? value + "." + ext! : value
                    }
                    continuation.resume(returning: try ShareStaging.copy(url, named: proposedName))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// item-provider 可以把 NSURL 序列化成 URL 字符串的 UTF-8 数据。
    private static func decodeURL(_ item: NSSecureCoding) -> URL? {
        if let url = item as? URL { return url }
        let value = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return value.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))) }
    }

    private static func loadItem(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
