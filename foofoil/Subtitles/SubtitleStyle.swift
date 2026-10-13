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
        ("Subtitle Black Background", .init(background: "#000000B3", theme: "Subtitle Black Background")),
        ("Subtitle Warm Yellow", .init(color: "#FFE082", theme: "Subtitle Warm Yellow")),
        ("Subtitle Light Background", .init(color: "#202020", background: "#FFFFFFCC", shadow: "#00000000", theme: "Subtitle Light Background"))
    ]
}
@MainActor final class SubtitleStyleStore: ObservableObject {
    static let shared = SubtitleStyleStore()
    @Published var style: SubtitleStyle { didSet { if let data = try? JSONEncoder().encode(style) { UserDefaults.standard.set(data, forKey: "video.subtitle.style") } } }
    init() { style = UserDefaults.standard.data(forKey: "video.subtitle.style").flatMap { try? JSONDecoder().decode(SubtitleStyle.self, from: $0) } ?? .init() }
    func applyTheme(_ style: SubtitleStyle) {
        var value = style; value.bottom = self.style.bottom; value.delay = self.style.delay
        self.style = value
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
    public var isHidden = false
    public init() {}
}
public struct SubtitleFileReference: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data?
    public init(path: String, bookmark: Data?) { self.path = path; self.bookmark = bookmark }
}
