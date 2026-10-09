import Foundation

nonisolated public struct HistorySearchResult: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let contentKind: HistoryContentKind
    public let thumbnailPath: String?
    public let matchedSnippet: String?
    public let matchedPageNumber: Int?
    public let score: Double
    public var sourcePath: String? = nil
    public var isAppleMusic: Bool = false
    public var symbolName: String { isAppleMusic ? AppleMusicReference.symbolName : contentKind.symbolName }
}

nonisolated struct HistorySearchCandidate: Sendable {
    let id: UUID
    let title: String
    let contentKind: HistoryContentKind
    let thumbnailPath: String?
    let originalText: String
    let normalizedText: String
    let pageNumber: Int?
    let lastOpenedAt: Date
    var sourceFingerprint: String? = nil
    var isAppleMusic: Bool = false
}
