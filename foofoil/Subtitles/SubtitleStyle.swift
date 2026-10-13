import AppKit
import SwiftUI
import Combine

struct SubtitleStyle: Codable, Equatable {
    var font = ""
    /// 按 1080 高度画面标定，随实际视频显示区域等比例缩放。
    var size = 44.0
    var color = "#FFFFFF"
    var background = "#00000000"
    var shadow = "#000000"
    var bottom = 6.0
    var delay = 0.0
    var theme = "Subtitle White Shadow"
    static let themes: [(String, SubtitleStyle)] = [
        ("Subtitle White Shadow", .init()),
        ("Subtitle Warm Yellow", .init(color: "#FFE6A3", shadow: "#38220BE6", theme: "Subtitle Warm Yellow")),
        ("Subtitle Spotlight", .init(size: 52, color: "#FFFFFF", background: "#101820E6", shadow: "#00000000", theme: "Subtitle Spotlight")),
        ("Subtitle Black Background", .init(color: "#F2F4F8", background: "#121722B3", shadow: "#05080FE6", theme: "Subtitle Black Background")),
        ("Subtitle Light Background", .init(color: "#28303E", background: "#F5F0E8E6", shadow: "#00000000", theme: "Subtitle Light Background")),
        ("Subtitle Mist", .init(color: "#BFF5EA", background: "#092D354D", shadow: "#031A25", theme: "Subtitle Mist"))
    ]
    static let descriptions: [String: String] = [
        "Subtitle White Shadow": "Subtitle Elegant Description",
        "Subtitle Warm Yellow": "Subtitle Warm Description",
        "Subtitle Spotlight": "Subtitle Clear Description",
        "Subtitle Black Background": "Subtitle Balanced Description",
        "Subtitle Light Background": "Subtitle Light Description",
        "Subtitle Mist": "Subtitle Cool Description"
    ]
}
struct SavedSubtitleTheme: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var style: SubtitleStyle
}
@MainActor final class SubtitleStyleStore: ObservableObject {
    static let shared = SubtitleStyleStore()
    @Published var style: SubtitleStyle { didSet { if let data = try? JSONEncoder().encode(style) { defaults.set(data, forKey: "video.subtitle.style") } } }
    @Published private(set) var customThemes: [SavedSubtitleTheme] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customThemes = defaults.data(forKey: "video.subtitle.themes").flatMap { try? JSONDecoder().decode([SavedSubtitleTheme].self, from: $0) } ?? []
        style = defaults.data(forKey: "video.subtitle.style").flatMap { try? JSONDecoder().decode(SubtitleStyle.self, from: $0) } ?? .init() }
    func applyTheme(_ style: SubtitleStyle) {
        var value = style; value.bottom = self.style.bottom; value.delay = self.style.delay
        self.style = value
    }
    /// 主题保存完整设置；预设切换保留位置与延迟，自建主题恢复保存的配置。
    @discardableResult func saveTheme(name: String, replacing id: String? = nil) -> SavedSubtitleTheme {
        let index = customThemes.firstIndex { $0.id == id }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = SavedSubtitleTheme(id: index.map { customThemes[$0].id } ?? UUID().uuidString,
                                      name: trimmed.isEmpty ? NSLocalizedString("Custom Theme", comment: "") : trimmed, style: style)
        if let index { customThemes[index] = value } else { customThemes.append(value) }
        persistThemes()
        selectTheme(value)
        return value
    }
    func selectTheme(_ theme: SavedSubtitleTheme) {
        var value = theme.style; value.theme = theme.id; style = value
    }
    func deleteTheme(id: String) {
        customThemes.removeAll { $0.id == id }
        if style.theme == id { style.theme = "Custom" }
        persistThemes()
    }
    private func persistThemes() {
        if let data = try? JSONEncoder().encode(customThemes) { defaults.set(data, forKey: "video.subtitle.themes") }
    }
    static func color(_ hex: String) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let n = UInt64(value, radix: 16) else { return .white }
        let alpha = value.count == 8 ? Double(n & 255) / 255 : 1
        let rgb = value.count == 8 ? n >> 8 : n
        return Color(.sRGB, red: Double((rgb >> 16) & 255)/255, green: Double((rgb >> 8) & 255)/255, blue: Double(rgb & 255)/255, opacity: alpha)
    }
    static func hex(_ color: Color) -> String {
        let n = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X%02X", Int(n.redComponent*255), Int(n.greenComponent*255), Int(n.blueComponent*255), Int(n.alphaComponent*255))
    }
}
public struct SubtitleAssociation: Codable, Equatable, Sendable {
    public var files: [SubtitleFileReference] = []
    public var embeddedID: String?
    public var selectedPath: String?
    public init() {}
}
public struct SubtitleFileReference: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data?
    public init(path: String, bookmark: Data?) { self.path = path; self.bookmark = bookmark }
}
