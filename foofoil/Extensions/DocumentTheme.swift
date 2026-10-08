//
//  DocumentTheme.swift
//  foofoil
//
//  Created by tolg on 2026/9/28.
//

import AppKit
import Combine
import SwiftUI

/// 文档主题：同时定义亮色与暗色外观下的背景色和文字前景色。
/// 专为长文阅读与日常查看设计，保障良好的对比度与阅读舒适感。
public struct DocumentTheme: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let isCustom: Bool

    public let lightBackgroundHex: String
    public let lightTextHex: String

    public let darkBackgroundHex: String
    public let darkTextHex: String

    public init(
        id: String,
        name: String,
        isCustom: Bool = false,
        lightBackgroundHex: String,
        lightTextHex: String,
        darkBackgroundHex: String,
        darkTextHex: String
    ) {
        self.id = id
        self.name = name
        self.isCustom = isCustom
        self.lightBackgroundHex = lightBackgroundHex
        self.lightTextHex = lightTextHex
        self.darkBackgroundHex = darkBackgroundHex
        self.darkTextHex = darkTextHex
    }

    /// 根据外观判定返回背景色（十六进制）
    public func backgroundHex(isDark: Bool) -> String {
        isDark ? darkBackgroundHex : lightBackgroundHex
    }

    /// 根据外观判定返回文字前景色（十六进制）
    public func textHex(isDark: Bool) -> String {
        isDark ? darkTextHex : lightTextHex
    }

    /// 根据外观返回 SwiftUI 背景色
    public func backgroundColor(isDark: Bool) -> Color {
        if id == "none" { return .clear }
        return Color(hex: backgroundHex(isDark: isDark)) ?? (isDark ? Color(nsColor: .windowBackgroundColor) : Color.white)
    }

    /// 根据外观返回 SwiftUI 文字前景色
    public func textColor(isDark: Bool) -> Color {
        if id == "none" { return .primary }
        return Color(hex: textHex(isDark: isDark)) ?? (isDark ? Color.white : Color.black)
    }

    /// 国际化或自定义显示名
    public var displayName: String {
        if isCustom {
            return name
        }
        return NSLocalizedString(name, comment: "")
    }
}

/// 文档主题管理器：提供经过仔细调校的预设主题，并管理用户自定义保存的主题。
@MainActor
public final class DocumentThemeCatalog: ObservableObject {
    public static let shared = DocumentThemeCatalog()

    /// 默认主题标识（素笺）
    public static let defaultThemeId = "minimal"

    /// 获取默认主题（素笺）
    public static var defaultTheme: DocumentTheme {
        shared.theme(for: defaultThemeId) ?? shared.presets[0]
    }

    /// 内置舒适阅读预设主题
    public let presets: [DocumentTheme] = [
        // 素笺：洁净纯简，经典纸感
        DocumentTheme(
            id: "minimal",
            name: "Minimal",
            isCustom: false,
            lightBackgroundHex: "#F8F9FA",
            lightTextHex: "#1F2328",
            darkBackgroundHex: "#1C1D1F",
            darkTextHex: "#E6E6E6"
        ),
        // 书卷：温润米黄，如阅纸书
        DocumentTheme(
            id: "parchment",
            name: "Parchment",
            isCustom: false,
            lightBackgroundHex: "#F5EFE0",
            lightTextHex: "#382E24",
            darkBackgroundHex: "#241E17",
            darkTextHex: "#DCD2C3"
        ),
        // 青竹：苍翠雅致，护眼舒缓
        DocumentTheme(
            id: "bamboo",
            name: "Bamboo",
            isCustom: false,
            lightBackgroundHex: "#EBF1E8",
            lightTextHex: "#203324",
            darkBackgroundHex: "#16221A",
            darkTextHex: "#CFDDCF"
        ),
        // 暮云：暖调霞光，柔和静谧
        DocumentTheme(
            id: "dusk",
            name: "Dusk",
            isCustom: false,
            lightBackgroundHex: "#F6ECE8",
            lightTextHex: "#3E2A2C",
            darkBackgroundHex: "#231A1C",
            darkTextHex: "#E6D3D5"
        ),
        // 远山：青黛冷雾，清爽专注
        DocumentTheme(
            id: "mist",
            name: "Mist",
            isCustom: false,
            lightBackgroundHex: "#EBF0F5",
            lightTextHex: "#202F3E",
            darkBackgroundHex: "#161E26",
            darkTextHex: "#CDD9E4"
        ),
        // 无：透明背景与系统文字颜色，不固化明暗外观。
        DocumentTheme(
            id: "none",
            name: "Document Theme None",
            isCustom: false,
            lightBackgroundHex: "#F0F1F3",
            lightTextHex: "#16171A",
            darkBackgroundHex: "#111214",
            darkTextHex: "#D4D6DC"
        )
    ]

    /// 用户自建的主题
    @Published public private(set) var customThemes: [DocumentTheme] = []

    private init() {
        self.customThemes = SettingsStore.shared.customDocumentThemes
    }

    /// 所有主题（预设在前，自定义在后）
    public var allThemes: [DocumentTheme] {
        presets + customThemes
    }

    /// 按标识查找主题
    public func theme(for id: String?) -> DocumentTheme? {
        guard let id else { return nil }
        return allThemes.first { $0.id == id }
    }

    /// 从当前前景色与背景色创建并保存用户主题，自动利用明度镜像推导对立外观的成对色彩。
    @discardableResult
    public func addCustomTheme(
        name: String,
        currentBackgroundHex: String?,
        currentTextHex: String?,
        isCurrentlyDark: Bool
    ) -> DocumentTheme {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? NSLocalizedString("Custom Theme", comment: "") : trimmedName

        // 当用户尚未自选颜色时，采用系统常规色彩作为基准
        let bgHex = currentBackgroundHex ?? (isCurrentlyDark ? "#1E1E1E" : "#FFFFFF")
        let fgHex = currentTextHex ?? (isCurrentlyDark ? "#E6E6E6" : "#1F2328")

        let lightBg: String
        let lightFg: String
        let darkBg: String
        let darkFg: String

        if isCurrentlyDark {
            darkBg = bgHex
            darkFg = fgHex
            lightBg = DocumentColorAdapter.mirroredHex(darkBg) ?? "#F8F9FA"
            lightFg = DocumentColorAdapter.mirroredHex(darkFg) ?? "#1F2328"
        } else {
            lightBg = bgHex
            lightFg = fgHex
            darkBg = DocumentColorAdapter.mirroredHex(lightBg) ?? "#1C1D1F"
            darkFg = DocumentColorAdapter.mirroredHex(lightFg) ?? "#E6E6E6"
        }

        let newTheme = DocumentTheme(
            id: UUID().uuidString,
            name: resolvedName,
            isCustom: true,
            lightBackgroundHex: lightBg,
            lightTextHex: lightFg,
            darkBackgroundHex: darkBg,
            darkTextHex: darkFg
        )

        customThemes.append(newTheme)
        SettingsStore.shared.customDocumentThemes = customThemes
        return newTheme
    }

    /// 删除指定自定义主题
    public func deleteCustomTheme(id: String) {
        customThemes.removeAll { $0.id == id }
        SettingsStore.shared.customDocumentThemes = customThemes
    }
}
